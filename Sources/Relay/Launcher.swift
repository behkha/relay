import Foundation
import AppKit

/// Opens a terminal window running a command (new Claude session, account login).
enum Launcher {
    enum App: String, CaseIterable, Identifiable {
        case terminal = "Terminal"
        case iterm = "iTerm"
        var id: String { rawValue }
        var bundleId: String { self == .terminal ? "com.apple.Terminal" : "com.googlecode.iterm2" }
        var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil }
    }

    static var preferred: App {
        get { App(rawValue: UserDefaults.standard.string(forKey: "terminalApp") ?? "") ?? .terminal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "terminalApp") }
    }

    static func claudeExecutable() -> String {
        ClaudeCLI.path.map(Shell.quote) ?? "claude"
    }

    /// Starts a new Claude Code session for a workspace in a folder.
    static func newSession(workspace ws: Workspace, folder: String, extraArgs: String = "") {
        let cmd = "cd \(Shell.quote(folder)) && \(ws.envPrefix) \(claudeExecutable())\(extraArgs.isEmpty ? "" : " " + extraArgs)"
        open(command: cmd)
    }

    /// Signs a workspace into a Claude account (optionally pre-filling the Gmail address).
    static func login(workspace ws: Workspace, email: String?) {
        var cmd = "\(ws.envPrefix) \(claudeExecutable()) auth login"
        if let email, !email.isEmpty { cmd += " --email \(Shell.quote(email))" }
        open(command: cmd)
    }

    static func logout(workspace ws: Workspace) {
        open(command: "\(ws.envPrefix) \(claudeExecutable()) auth logout")
    }

    // MARK: Detached tmux (started from the phone)

    /// Permission modes the phone may start an agent in. Never bypassPermissions or
    /// --dangerously-skip-permissions.
    static let phoneModes = ["default", "plan", "acceptEdits"]

    enum LaunchError: Error, Equatable {
        case noTmux
        case failed(String)

        var message: String {
            switch self {
            case .noTmux: return "Starting agents from the phone needs tmux on the Mac (brew install tmux)."
            case .failed(let why): return "tmux couldn't start the agent: \(why)"
            }
        }
    }

    /// Starts Claude Code in a new detached tmux session `relay-<launchId>`. Its hooks report
    /// RELAY_LAUNCH_ID, which turns the phone's "Starting…" row into the real agent. Call off main.
    static func newDetachedTmux(workspace ws: Workspace, folder: String, prompt: String, mode: String) -> Result<String, LaunchError> {
        guard phoneModes.contains(mode) else { return .failure(.failed("unknown permission mode")) }
        guard let tmux = Proc.which("tmux") else { return .failure(.noTmux) }
        let id = Secure.randomBytes(8).hexString
        let script = detachedScript(workspace: ws, folder: folder, prompt: prompt, mode: mode, launchId: id,
                                    claude: claudeExecutable())
        let r = Proc.run(tmux, tmuxArguments(session: "relay-\(id)", script: script), timeout: 15)
        guard r.status == 0 else {
            let why = r.stderr.split(separator: "\n").first.map(String.init) ?? "exit status \(r.status)"
            return .failure(.failed(why))
        }
        return .success(id)
    }

    /// `tmux new-session` running the script with /bin/sh. The command goes in as separate arguments,
    /// which tmux executes directly: no tmux formats (`#(…)` would run a command), no login shell
    /// whose quoting rules differ (fish), and no start directory flag (`-c` is format-expanded too).
    static func tmuxArguments(session: String, script: String) -> [String] {
        ["new-session", "-d", "-s", session, "-x", "120", "-y", "40", "/bin/sh", "-c", script]
    }

    /// The POSIX sh script the pane runs. Every outside string is single-quoted with `Shell.quote`:
    /// the folder (cd'd into here rather than passed to tmux) and the prompt.
    ///
    /// The mode is always passed, even "default", so a `permissions.defaultMode` in some settings file
    /// can't start the agent in another mode. The prompt follows `--` and never starts with "-", so it
    /// can't pass itself off as a flag; a one-word prompt gets a trailing space so Claude Code doesn't
    /// take it for one of its commands (`claude purge`, `claude update`). If claude exits within 30 s
    /// (not signed in, folder gone…), the pane stays open 2 minutes so Relay can show what it said.
    static func detachedScript(workspace ws: Workspace, folder: String, prompt: String, mode: String,
                               launchId: String, claude: String) -> String {
        var command = "\(ws.envPrefix) RELAY_LAUNCH_ID=\(launchId) \(claude) --permission-mode \(Shell.quote(mode))"
        var p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty {
            if !p.contains(where: \.isWhitespace) { p += " " }
            if p.hasPrefix("-") { p = " " + p }
            command += " -- " + Shell.quote(p)
        }
        return [
            "cd \(Shell.quote(folder)) || { echo \"[relay] Couldn't open the folder\"; sleep 120; exit 1; }",
            "t=$(date +%s)",
            command,
            "s=$?",
            "if [ $s -ne 0 ] && [ $(( $(date +%s) - t )) -lt 30 ]; then echo \"[relay] claude exited ($s)\"; sleep 120; fi",
            "exit $s",
        ].joined(separator: "\n")
    }

    /// The last `lines` lines of a tmux pane or session, without trailing blank lines. Call off main.
    static func capturePane(target: String, socket: String? = nil, lines: Int) -> String? {
        guard let tmux = Proc.which("tmux") else { return nil }
        let base = socket.map { ["-S", $0] } ?? []
        let r = Proc.run(tmux, base + ["capture-pane", "-p", "-J", "-t", target, "-S", "-\(lines)"], timeout: 8)
        guard r.status == 0 else { return nil }
        var rows = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows.suffix(lines).joined(separator: "\n")
    }

    static func open(command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let app = preferred.isInstalled ? preferred : .terminal
            switch app {
            case .terminal:
                AppleScript.run("""
                on run argv
                  tell application "Terminal"
                    do script (item 1 of argv)
                    activate
                  end tell
                end run
                """, args: [command])
            case .iterm:
                AppleScript.run("""
                on run argv
                  tell application "iTerm2"
                    set w to (create window with default profile)
                    tell current session of w to write text (item 1 of argv)
                    activate
                  end tell
                end run
                """, args: [command])
            }
        }
    }
}
