import Foundation
import UserNotifications
import AppKit

/// System notifications for new inbox items (shown when the card is not already in front of you).
enum Notifier {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
    }
    static var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }

    /// Removes banners for items that were answered or cleared.
    static func withdraw(_ ids: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(item: InboxItem, session: AgentSession?, workspace: Workspace?) {
        if soundEnabled {
            NSSound(named: item.isActionable ? "Tink" : "Pop")?.play()
        }
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        let handle = session?.handle ?? "agent"
        let verb: String
        switch item.kind {
        case .question, .permission: verb = "asks"
        case .waiting: verb = "is waiting"
        case .finished: verb = "finished"
        }
        content.title = "\(handle) \(verb)"
        if let ws = workspace { content.subtitle = ws.name + (ws.email.map { " · \($0)" } ?? "") }
        content.body = item.kind == .question ? item.body : item.title
        content.userInfo = ["itemId": item.id]
        let req = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

/// Optional shell commands (e.g. `claude-work`) that start Claude Code with a workspace's account.
enum ShellCommands {
    static let begin = "# >>> Relay workspaces >>>"
    static let end = "# <<< Relay workspaces <<<"

    static func isValidName(_ name: String) -> Bool {
        guard name != "claude", name.count <= 40 else { return false }
        return name.range(of: "^[A-Za-z][A-Za-z0-9_-]*$", options: .regularExpression) != nil
    }

    static var rcFiles: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var files = [home.appendingPathComponent(".zshrc")]
        let bashrc = home.appendingPathComponent(".bashrc")
        if FileManager.default.fileExists(atPath: bashrc.path) { files.append(bashrc) }
        return files
    }

    enum RCError: LocalizedError {
        case unreadable(String)
        case brokenBlock(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let f): return "Couldn't read \(f) as text, so Relay left it untouched."
            case .brokenBlock(let f): return "\(f) has a Relay start marker without its end marker. Fix it by hand; Relay left it untouched."
            }
        }
    }

    /// Rewrites Relay's block in the shell rc files to match the workspaces.
    /// A file is only ever changed between Relay's own markers; anything unexpected aborts without writing.
    static func sync(_ workspaces: [Workspace]) throws {
        var lines: [String] = []
        for ws in workspaces {
            guard let name = ws.shellCommand, isValidName(name) else { continue }
            if let dir = ws.configDir {
                lines.append("\(name)() { CLAUDE_CONFIG_DIR=\(Shell.quote(dir)) command claude \"$@\"; }")
            } else {
                lines.append("\(name)() { env -u CLAUDE_CONFIG_DIR claude \"$@\"; }")
            }
        }
        let fm = FileManager.default
        // Plan every file first; write only if all of them can be handled, so nothing is half-done.
        var writes: [(target: URL, text: String, exists: Bool)] = []
        for file in rcFiles {
            let target = file.resolvingSymlinksInPath()
            let exists = fm.fileExists(atPath: target.path)
            var text = ""
            if exists {
                guard let data = try? Data(contentsOf: target), let s = String(data: data, encoding: .utf8) else {
                    throw RCError.unreadable(file.lastPathComponent)
                }
                text = s
            }
            let original = text
            if let r1 = text.range(of: begin) {
                guard let r2 = text.range(of: end, range: r1.upperBound..<text.endIndex) else {
                    throw RCError.brokenBlock(file.lastPathComponent)
                }
                var lower = r1.lowerBound
                if lower > text.startIndex, text[text.index(before: lower)] == "\n" { lower = text.index(before: lower) }
                var upper = r2.upperBound
                if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
                text.removeSubrange(lower..<upper)
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            }
            if !lines.isEmpty {
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                text += "\n\(begin)\n" + lines.joined(separator: "\n") + "\n\(end)\n"
            }
            guard text != original else { continue }
            if !exists && lines.isEmpty { continue }
            writes.append((target, text, exists))
        }
        for w in writes {
            // One-time backup of the user's file before Relay first edits it.
            let backup = w.target.path + ".relay-backup"
            if w.exists && !fm.fileExists(atPath: backup) { try? fm.copyItem(atPath: w.target.path, toPath: backup) }
            let attrs = try? fm.attributesOfItem(atPath: w.target.path)
            try w.text.write(to: w.target, atomically: true, encoding: .utf8)
            if let perms = attrs?[.posixPermissions] { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: w.target.path) }
        }
    }
}
