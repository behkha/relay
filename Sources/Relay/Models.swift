import Foundation
import SwiftUI

/// A Claude Code account. Each workspace is a separate CLAUDE_CONFIG_DIR,
/// so each one keeps its own login (Gmail), settings, history and hooks.
struct Workspace: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// nil means Claude Code's default location (~/.claude, ~/.claude.json).
    var configDir: String?
    var colorHex: String
    /// Optional shell command name, e.g. "claude-work", installed into ~/.zshrc.
    var shellCommand: String?
    /// The Claude desktop app profile (--user-data-dir) signed in to this account, if any.
    var desktopProfile: String?
    /// Your own shell alias that opens that profile (shown for reference; Relay doesn't write it).
    var desktopAlias: String?
    var createdAt: Date = Date()

    // Cached account info from `claude auth status --json`.
    var email: String?
    var plan: String?
    var loggedIn: Bool?

    var isDefault: Bool { configDir == nil }

    /// "rezaei" for ~/Library/Application Support/Claude/rezaei.
    var desktopProfileName: String? { desktopProfile.map { ($0 as NSString).lastPathComponent } }

    var resolvedConfigDir: String {
        configDir ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }

    var settingsPath: String {
        (resolvedConfigDir as NSString).appendingPathComponent("settings.json")
    }

    var color: Color { Color(hex: colorHex) }

    /// Shell prefix that selects this workspace's account.
    var envPrefix: String {
        if let configDir { return "CLAUDE_CONFIG_DIR=\(Shell.quote(configDir))" }
        return "env -u CLAUDE_CONFIG_DIR"
    }

    static let palette = ["#E8A85A", "#5B8DEF", "#4CC38A", "#C77DFF", "#F06A6A", "#3FC1C9", "#F2C94C", "#9AA5B1"]
}

enum AgentStatus: String, Codable {
    case ready, working, waiting, idle, done, ended

    var color: Color {
        switch self {
        case .ready: return Color.white.opacity(0.45)
        case .working: return Theme.blue
        case .waiting: return Theme.amber
        case .idle: return Theme.amber
        case .done: return Theme.green
        case .ended: return Color.gray
        }
    }

    var label: String {
        switch self {
        case .ready: return "ready"
        case .working: return "working"
        case .waiting: return "asking"
        case .idle: return "waiting for you"
        case .done: return "done"
        case .ended: return "ended"
        }
    }
}

/// Where a session's terminal lives, so Relay can type into it or bring it forward.
struct TerminalLocation: Codable, Hashable {
    var tty: String?
    var termProgram: String?
    var bundleId: String?
    var herdrPane: String?
    var herdrSocket: String?
    var tmux: String?
    var tmuxPane: String?
    var itermSession: String?
    /// CLAUDE_CODE_ENTRYPOINT: "cli" for terminal sessions; "claude-desktop", "claude-vscode", "sdk-…" otherwise.
    var entrypoint: String?

    /// True when the agent runs inside an app (Claude desktop, an IDE extension) rather than a terminal.
    /// Those inherit misleading TERM_PROGRAM values, so Relay must not type into a terminal for them.
    var isAppHosted: Bool {
        if herdrPane?.isEmpty == false || tmuxPane?.isEmpty == false { return false }
        if let e = entrypoint, !e.isEmpty, e != "cli" { return true }
        return tty == nil || tty == "??"
    }

    var kindLabel: String {
        if herdrPane?.isEmpty == false { return "herdr" }
        if isAppHosted {
            switch entrypoint ?? "" {
            case "claude-desktop": return "Claude app"
            case "claude-vscode": return "VS Code"
            default: return "app"
            }
        }
        if tmuxPane?.isEmpty == false { return "tmux" }
        switch termProgram ?? "" {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case "ghostty": return "Ghostty"
        case "WarpTerminal": return "Warp"
        case "vscode": return "VS Code"
        case "": return "terminal"
        default: return termProgram ?? "terminal"
        }
    }
}

struct AgentSession: Codable, Identifiable, Hashable {
    var id: String               // Claude Code session_id
    var workspaceId: String
    var cwd: String
    var pid: Int32?
    /// The process start time seen with `pid`, so a reused pid is never mistaken for this agent.
    var pidStart: Double?
    var terminal: TerminalLocation
    var status: AgentStatus = .working
    var lastPrompt: String?
    var lastMessage: String?
    var transcriptPath: String?
    var startedAt: Date = Date()
    var updatedAt: Date = Date()
    /// Short sequential handle like "claude-7".
    var handle: String
    /// Claude Code's AI-generated session title, when it has one.
    var title: String?
    /// Background tasks (shell commands, agents, workflows) the agent left running after its turn.
    var backgroundTasks: Int?

    /// The status to show: an agent whose turn ended but whose background tasks still run is still working.
    var shownStatus: AgentStatus {
        if (backgroundTasks ?? 0) > 0, status == .done || status == .ready || status == .idle { return .working }
        return status
    }

    /// What the UI calls this agent: its session title, else its project folder.
    var displayName: String { (title?.isEmpty == false ? title! : folderName) }

    var folderName: String { (cwd as NSString).lastPathComponent }

    /// The last instruction on one line; a background task's report reads as its summary.
    var promptPreview: String? {
        guard var p = lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        if p.hasPrefix("<task-notification>") {
            guard let a = p.range(of: "<summary>"), let b = p.range(of: "</summary>", range: a.upperBound..<p.endIndex) else {
                return "Background task finished"
            }
            p = String(p[a.upperBound..<b.lowerBound])
        }
        let line = p.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    /// True when the last instruction was a background task reporting back rather than you.
    var promptIsTaskReport: Bool { lastPrompt?.hasPrefix("<task-notification>") == true }

    /// "~/one/web" style path for display.
    var shortPath: String {
        let home = NSHomeDirectory()
        var p = cwd
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count > 2 { return "…/" + parts.suffix(2).joined(separator: "/") }
        return p
    }
}

struct QuestionOption: Codable, Hashable {
    var label: String
    var description: String?
}

struct AgentQuestion: Codable, Hashable {
    var question: String
    var header: String?
    var options: [QuestionOption]
    var multiSelect: Bool
}

enum NextStepsState: String, Codable { case none, loading, ready, failed }

enum InboxKind: String, Codable {
    case question      // AskUserQuestion
    case permission    // tool permission prompt
    case waiting       // idle, waiting for the next instruction
    case finished      // turn finished
}

struct InboxItem: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var sessionId: String
    var workspaceId: String
    var kind: InboxKind
    var title: String
    var body: String
    var createdAt: Date = Date()

    // Permission details
    var toolName: String?
    var toolInputJSON: String?
    var permissionSuggestionsJSON: String?

    // AskUserQuestion details
    var questions: [AgentQuestion] = []

    /// True while a PermissionRequest hook is blocked waiting for our decision.
    var isLive: Bool = false

    // Context read from the transcript when the item arrives.
    var prompt: String?             // the instruction this turn started from
    var activity: String?           // "Explored · Read cart.js · Ran tests"
    var nextSteps: [String] = []
    var nextStepsState: NextStepsState = .none

    var isActionable: Bool { kind == .question || kind == .permission }
}

enum Theme {
    static let blue = Color(hex: "#4C8DFF")
    static let amber = Color(hex: "#E8B04A")
    static let green = Color(hex: "#3DBE7A")
    static let claude = Color(hex: "#D97757")
    static let card = Color(hex: "#1B1B1D")
    static let cardBorder = Color.white.opacity(0.08)
    static let row = Color.white.opacity(0.05)
    static let rowBorder = Color.white.opacity(0.07)
    static let textDim = Color.white.opacity(0.55)
    static let textFaint = Color.white.opacity(0.38)
    static let selectedFill = Color(hex: "#1F3A2C")
    static let selectedBorder = Color(hex: "#3DBE7A").opacity(0.55)
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
        } else {
            r = 0.6; g = 0.6; b = 0.6
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

enum Shell {
    /// Single-quotes a string for POSIX shells.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// SwiftUI's `@State` is a macro in this SDK and its plugin only ships with full Xcode.
/// Using the property wrapper through an alias builds with the Command Line Tools alone.
typealias ViewState<Value> = SwiftUI.State<Value>
