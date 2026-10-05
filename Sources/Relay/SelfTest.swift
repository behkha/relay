import Foundation

/// Checks run by `Relay --self-test` (scripts/selftest.sh). Package.swift has no test target and XCTest
/// isn't guaranteed with only the Command Line Tools, so the app carries its own small harness.
/// It runs before NSApplication, listeners, hooks or UI exist, and only ever touches temp files.
enum SelfTest {
    /// Set first thing in `runAll`, before anything reads `Paths.support`, so the checks get a temp folder.
    private(set) static var isRunning = false
    private static var passed = 0
    private static var failures: [String] = []

    /// Runs every suite and prints a summary. True when all checks passed.
    static func runAll() -> Bool {
        isRunning = true
        // Never run (or clean up) anywhere but the temp sandbox.
        let sandbox = Paths.support
        guard sandbox.lastPathComponent.hasPrefix("relay-selftest-") else {
            print("FAIL sandbox: support folder is \(sandbox.path), not a temp folder")
            return false
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }
        harness()
        remoteAPI()
        print("\(passed) passed, \(failures.count) failed")
        if !failures.isEmpty { print("Failed: " + failures.joined(separator: ", ")) }
        return failures.isEmpty
    }

    /// Records one check and prints `PASS name` or `FAIL name`. A thrown error counts as a failure.
    static func check(_ name: String, _ condition: @autoclosure () throws -> Bool) {
        do {
            if try condition() {
                passed += 1
                print("PASS \(name)")
            } else {
                failures.append(name)
                print("FAIL \(name)")
            }
        } catch {
            failures.append(name)
            print("FAIL \(name) (\(error))")
        }
    }

    // MARK: - Harness

    private static func harness() {
        check("harness: a true check passes", 1 + 1 == 2)
    }

    // MARK: - Remote API

    private static func remoteAPI() {
        let lan: Set<Capability> = [.read, .answer]
        func allowed(_ method: String, _ path: String, _ caps: Set<Capability>) -> Bool {
            RemoteAPI.capability(method, path).map(caps.contains) ?? false
        }
        check("api: LAN door reads state, sessions and the page",
              allowed("GET", "/api/state", lan) && allowed("GET", "/api/session", lan) && allowed("GET", "/", lan))
        check("api: LAN door answers", allowed("POST", "/api/answer", lan))
        check("api: answering needs the answer capability", !allowed("POST", "/api/answer", [.read]))
        check("api: unknown routes don't exist", RemoteAPI.capability("GET", "/api/nope") == nil
              && RemoteAPI.capability("DELETE", "/api/state") == nil)
        check("api: heat level names", RemoteAPI.heatName(.none) == "none" && RemoteAPI.heatName(.warm) == "warm"
              && RemoteAPI.heatName(.hot) == "hot")

        // The LAN snapshot keeps every field it had and only gains new ones.
        let ws = Workspace(id: "w1", name: "Personal", configDir: nil, colorHex: "#E8A85A")
        var s = AgentSession(id: "s1", workspaceId: "w1", cwd: "/tmp/proj", pid: nil, terminal: TerminalLocation(),
                             status: .working, handle: "claude-1")
        s.lastPrompt = "fix it"
        s.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var perm = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .permission, title: "Run a command", body: "$ ls")
        perm.isLive = true
        perm.toolName = "Bash"
        let snap = RemoteAPI.snapshot(workspaces: [ws], sessions: [s], items: [perm], filter: nil,
                                      heat: ["s1": SessionHeat(cpu: 312.4, level: .hot)], caps: lan)
        let sess = (snap["sessions"] as? [[String: Any]])?.first ?? [:]
        let item = (snap["items"] as? [[String: Any]])?.first ?? [:]
        let oldSessionKeys = ["id", "handle", "path", "status", "statusLabel", "workspaceId", "lastPrompt", "lastMessage"]
        let oldItemKeys = ["id", "sessionId", "workspaceId", "kind", "title", "body", "createdAt", "toolName", "live", "options", "questions"]
        check("api: snapshot keeps the original top-level fields",
              ["workspaces", "sessions", "items", "filter"].allSatisfy { snap[$0] != nil })
        check("api: snapshot keeps the original session and item fields",
              oldSessionKeys.allSatisfy { sess[$0] != nil } && oldItemKeys.allSatisfy { item[$0] != nil }
              && sess["handle"] as? String == "claude-1" && item["options"] as? [String] == ["Yes", "No"])
        check("api: snapshot adds caps, heat and last activity",
              snap["caps"] as? [String] == ["read", "answer"] && sess["cpu"] as? Int == 312
              && sess["heat"] as? String == "hot" && sess["updatedAt"] as? Double == 1_700_000_000_000)
        check("api: snapshot is valid JSON", JSONSerialization.isValidJSONObject(snap))
    }
}
