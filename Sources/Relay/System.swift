import Foundation
import AppKit

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Demo mode and self-tests never touch the real support folder (workspaces, sessions, hooks).
        let dir = Demo.isOn || SelfTest.isRunning
            ? FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(SelfTest.isRunning ? "selftest" : "demo")-\(getpid())", isDirectory: true)
            : base.appendingPathComponent("Relay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var serverConfig: URL { support.appendingPathComponent("server.json") }
    static var workspaces: URL { support.appendingPathComponent("workspaces.json") }
    static var sessions: URL { support.appendingPathComponent("sessions.json") }
    static var hookScript: URL { support.appendingPathComponent("bin/relay-hook") }
    static var screenshots: URL {
        let d = support.appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Default parent for new workspace config dirs: ~/.claude-workspaces/<slug>
    static var workspaceRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-workspaces", isDirectory: true)
    }
}

struct ProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum Proc {
    /// Runs a process synchronously with an optional timeout. Never call on the main thread for slow tools.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], env: [String: String]? = nil,
                    stdin: String? = nil, timeout: TimeInterval = 30, cwd: URL? = nil) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Proc.searchPath
        if let env { for (k, v) in env { environment[k] = v } }
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = inPipe
        final class Box { let lock = NSLock(); var out = Data(); var err = Data() }
        let box = Box()
        let group = DispatchGroup()
        group.enter(); group.enter()
        DispatchQueue.global().async {
            let d = out.fileHandleForReading.readDataToEndOfFile()
            box.lock.lock(); box.out = d; box.lock.unlock(); group.leave()
        }
        DispatchQueue.global().async {
            let d = err.fileHandleForReading.readDataToEndOfFile()
            box.lock.lock(); box.err = d; box.lock.unlock(); group.leave()
        }
        do { try p.run() } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            group.wait()
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        // Our copies of the write ends must close, or a reader never sees EOF.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        let deadline = DispatchTime.now() + timeout
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            guard p.isRunning else { return }
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(pid, SIGKILL) } }
        }
        p.waitUntilExit()
        // A grandchild may still hold the pipes open; don't wait on it forever.
        _ = group.wait(timeout: .now() + 3)
        return ProcessResult(status: p.terminationStatus,
                             stdout: box.lock.withLock { String(decoding: box.out, as: UTF8.self) },
                             stderr: box.lock.withLock { String(decoding: box.err, as: UTF8.self) })
    }

    /// GUI apps get a minimal PATH; include the usual install locations for CLIs.
    static let searchPath: String = {
        let home = NSHomeDirectory()
        let extra = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                     "\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (extra + current).filter { seen.insert($0).inserted }.joined(separator: ":")
    }()

    private static var whichCache: [String: String] = [:]
    private static let whichLock = NSLock()

    static func which(_ tool: String) -> String? {
        whichLock.lock()
        if let hit = whichCache[tool] { whichLock.unlock(); return hit }
        whichLock.unlock()
        let found = lookup(tool)
        if let found { whichLock.lock(); whichCache[tool] = found; whichLock.unlock() }
        return found
    }

    private static func lookup(_ tool: String) -> String? {
        for dir in searchPath.split(separator: ":") {
            let path = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Fall back to the user's login shell, which knows nvm/asdf shims.
        let r = run("/bin/zsh", ["-lic", "command -v \(tool)"], timeout: 8)
        let line = r.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if line.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: line) { return line }
        return nil
    }
}

enum ClaudeCLI {
    static var path: String? = Proc.which("claude")

    /// Relay's small `claude -p` helpers read agent output, which must never be able to do anything:
    /// no tools, no MCP servers, none of your hooks/plugins/CLAUDE.md (--safe-mode), nothing saved.
    /// (--tools and --mcp-config take several values, so each is followed by another flag.)
    static let helperFlags = ["--safe-mode",
                              "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                              "--tools", "", "--permission-mode", "dontAsk",
                              "--model", "haiku", "--no-session-persistence"]

    /// One helper at a time, so a burst of finished agents can't start a dozen processes.
    static let helperQueue = DispatchQueue(label: "relay.helper", qos: .utility)

    /// Runs a one-shot prompt on a workspace's account (call on `helperQueue`).
    /// The prompt goes in on stdin (not visible in `ps`), from an empty scratch folder.
    static func ask(_ prompt: String, workspace ws: Workspace, timeout: TimeInterval) -> ProcessResult? {
        guard let claude = path else { return nil }
        var env: [String: String] = ["RELAY_DISABLE": "1"]
        if let dir = ws.configDir { env["CLAUDE_CONFIG_DIR"] = dir }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("relay-helper-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let args = ["-p"] + helperFlags
        if ws.configDir == nil {
            return Proc.run("/usr/bin/env", ["-u", "CLAUDE_CONFIG_DIR", claude] + args, env: env,
                            stdin: prompt, timeout: timeout, cwd: scratch)
        }
        return Proc.run(claude, args, env: env, stdin: prompt, timeout: timeout, cwd: scratch)
    }

    struct AuthStatus {
        var loggedIn: Bool
        var email: String?
        var plan: String?
    }

    /// `claude auth status --json` for a workspace (run off the main thread).
    static func authStatus(for ws: Workspace) -> AuthStatus? {
        guard let claude = path else { return nil }
        var env: [String: String] = [:]
        var args = ["auth", "status", "--json"]
        let exe: String
        if let dir = ws.configDir {
            env["CLAUDE_CONFIG_DIR"] = dir
            exe = claude
        } else {
            // Make sure an inherited CLAUDE_CONFIG_DIR does not leak into the default workspace.
            exe = "/usr/bin/env"
            args = ["-u", "CLAUDE_CONFIG_DIR", claude] + args
        }
        let r = Proc.run(exe, args, env: env, timeout: 20)
        guard let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return AuthStatus(loggedIn: obj["loggedIn"] as? Bool ?? false,
                          email: obj["email"] as? String,
                          plan: obj["subscriptionType"] as? String)
    }
}

enum AppleScript {
    /// Runs AppleScript source with arguments passed via `on run argv` (no string escaping needed).
    @discardableResult
    static func run(_ source: String, args: [String] = []) -> ProcessResult {
        Proc.run("/usr/bin/osascript", ["-e", source] + args, timeout: 15)
    }
}
