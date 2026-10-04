import Foundation

/// Installs Relay's hook entries into a workspace's settings.json, leaving every other setting
/// (and every other hook) untouched. Relay's entries are recognised by the hook script path.
enum HookInstaller {
    struct Spec {
        var name: String            // Claude Code hook event
        var arg: String             // event name passed to relay-hook
        var matcher: String?
        var timeout: Int?
        var extra: [String: Any] = [:]
    }

    static let events: [Spec] = [
        Spec(name: "SessionStart", arg: "SessionStart", matcher: nil, timeout: 10),
        Spec(name: "SessionEnd", arg: "SessionEnd", matcher: nil, timeout: 10),
        Spec(name: "UserPromptSubmit", arg: "UserPromptSubmit", matcher: nil, timeout: 10),
        Spec(name: "PreToolUse", arg: "PreToolUse", matcher: "*", timeout: 10),
        Spec(name: "PostToolUse", arg: "PostToolUse", matcher: "*", timeout: 10),
        Spec(name: "PermissionRequest", arg: "PermissionRequest", matcher: "*", timeout: 86400),
        Spec(name: "Notification", arg: "Notification", matcher: nil, timeout: 10),
        Spec(name: "Stop", arg: "Stop", matcher: nil, timeout: 10),
        // Runs in the background after every turn and wakes the agent when you message it from Relay.
        // `async` is set too so a build that doesn't know asyncRewake still never blocks on it.
        Spec(name: "Stop", arg: "Wait", matcher: nil, timeout: 86400,
             extra: ["async": true, "asyncRewake": true,
                     "rewakeMessage": "Message from the user (sent from Relay):",
                     "rewakeSummary": "Message from Relay"]),
    ]

    /// Relay's own entries are the ones that run its hook script (matched by full path).
    static var marker: String { Paths.hookScript.path }

    enum InstallError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "\(path) is not valid JSON, so Relay left it alone. Fix it and try again."
            }
        }
    }

    /// Copies the hook script from the app bundle to Application Support.
    static func installScript() throws {
        guard let src = Bundle.main.url(forResource: "relay-hook", withExtension: "sh") else {
            throw NSError(domain: "Relay", code: 1, userInfo: [NSLocalizedDescriptionKey: "relay-hook.sh missing from app bundle"])
        }
        let dest = Paths.hookScript
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: src)
        if (try? Data(contentsOf: dest)) != data {
            try data.write(to: dest, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    static func command(for ws: Workspace, event: String) -> String {
        "\(Shell.quote(Paths.hookScript.path)) \(Shell.quote(ws.id)) \(event)"
    }

    static func isInstalled(_ ws: Workspace) -> Bool {
        guard let root = try? readSettings(ws.settingsPath),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in
            guard let groups = hooks[ev.name] as? [[String: Any]] else { return false }
            return groups.contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains { hook in
                    (hook["command"] as? String) == command(for: ws, event: ev.arg)
                        && ev.extra.allSatisfy { k, v in (hook[k] as? NSObject)?.isEqual(v) ?? false }
                }
            }
        }
    }

    static func install(_ ws: Workspace) throws {
        try installScript()
        try FileManager.default.createDirectory(atPath: ws.resolvedConfigDir, withIntermediateDirectories: true)
        if isInstalled(ws) { return }   // nothing to change: leave the file exactly as it is
        var root = try readSettings(ws.settingsPath) ?? [:]
        if root["hooks"] != nil && !(root["hooks"] is [String: Any]) {
            throw InstallError.unreadable(ws.settingsPath + " (\"hooks\" isn't an object)")
        }
        backupOnce(ws.settingsPath)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        hooks = stripRelay(hooks)
        for ev in events {
            if hooks[ev.name] != nil && !(hooks[ev.name] is [[String: Any]]) { continue }   // not ours to rewrite
            var groups = hooks[ev.name] as? [[String: Any]] ?? []
            var hook: [String: Any] = ["type": "command", "command": command(for: ws, event: ev.arg)]
            if let t = ev.timeout { hook["timeout"] = t }
            for (k, v) in ev.extra { hook[k] = v }
            var group: [String: Any] = ["hooks": [hook]]
            if let m = ev.matcher { group["matcher"] = m }
            groups.append(group)
            hooks[ev.name] = groups
        }
        root["hooks"] = hooks
        try writeSettings(root, to: ws.settingsPath)
    }

    static func uninstall(_ ws: Workspace) throws {
        guard var root = try readSettings(ws.settingsPath) else { return }
        guard let hooks = root["hooks"] as? [String: Any] else { return }
        let cleaned = stripRelay(hooks)
        if cleaned.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = cleaned }
        try writeSettings(root, to: ws.settingsPath)
    }

    /// Removes Relay's hook commands; drops groups and events that become empty.
    private static func stripRelay(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            var kept: [[String: Any]] = []
            for var group in groups {
                if let list = group["hooks"] as? [[String: Any]] {
                    let filtered = list.filter { !(($0["command"] as? String)?.contains(marker) ?? false) }
                    if filtered.isEmpty { continue }
                    group["hooks"] = filtered
                }
                kept.append(group)
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    /// nil when the file does not exist; throws when it exists but is not a JSON object.
    private static func readSettings(_ path: String) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.unreadable(path)
        }
        return obj
    }

    private static func writeSettings(_ root: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Resolve symlinks so a linked settings.json (e.g. from a dotfiles repo) stays linked,
        // and keep the file's permissions.
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try data.write(to: url, options: .atomic)
        if let perms { try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
    }

    private static func backupOnce(_ path: String) {
        let backup = path + ".relay-backup"
        let fm = FileManager.default
        guard fm.fileExists(atPath: path), !fm.fileExists(atPath: backup) else { return }
        try? fm.copyItem(atPath: path, toPath: backup)
    }
}
