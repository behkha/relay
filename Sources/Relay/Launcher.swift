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
