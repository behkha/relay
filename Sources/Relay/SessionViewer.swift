import AppKit
import SwiftUI
import Combine

// MARK: - Transcript model

struct TranscriptEntry: Identifiable, Hashable {
    enum Kind: Hashable { case user, assistant, tool, notice }

    var id: String
    var kind: Kind
    var text: String
    var toolName: String?
    var toolDetail: String?
    var result: String?
    var isError = false
    var date: Date?
}

/// Live, incremental reader of a Claude Code transcript (JSONL). Only new bytes are parsed on each tick.
final class TranscriptReader: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published private(set) var title: String?
    private var titleRank = 0
    @Published private(set) var truncated = false
    @Published private(set) var missing = false

    private let path: String?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var toolIndex: [String: Int] = [:]   // tool_use_id -> entries index
    private var timer: Timer?
    private let queue = DispatchQueue(label: "relay.transcript")
    private static let initialWindow: UInt64 = 3 * 1024 * 1024
    private static let maxEntries = 600

    init(path: String?) {
        self.path = path
    }

    struct Summary {
        var title: String?
        var prompt: String?
        var activity: String?
        /// The agent's last words this turn (the lead-in to a question it asks).
        var said: String?
        /// Background tasks still running.
        var backgroundTasks = 0
    }

    /// Session title, the last instruction and what the agent did since (call off the main thread).
    /// `since`: when the agent's current process started; background tasks from before then died with the old one.
    static func summary(path: String?, since: Date? = nil) -> Summary {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return Summary() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > initialWindow ? size - initialWindow : 0
        try? handle.seek(toOffset: start)
        var lines = handle.readDataToEndOfFile().split(separator: 0x0A)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        let parsed = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        var state = BuildState(entries: [], toolIndex: [:])
        apply(parsed, to: &state)
        let entries = state.entries
        let lastUser = entries.lastIndex { $0.kind == .user }
        let prompt = lastUser.map { entries[$0].text }
        let tools = entries[(lastUser.map { $0 + 1 } ?? 0)...].filter { $0.kind == .tool }
        // Older than a day is a task whose end Relay never saw.
        let cutoff = max(since ?? .distantPast, Date().addingTimeInterval(-24 * 3600))
        let running = state.background.values.filter { $0 >= cutoff }.count
        let said = entries[(lastUser.map { $0 + 1 } ?? 0)...].last { $0.kind == .assistant }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Summary(title: state.title, prompt: prompt, activity: activityLine(Array(tools)),
                       said: said?.isEmpty == false ? said : nil, backgroundTasks: running)
    }

    /// One-line summary of a turn's tool calls, grouped by kind in the order they first happened:
    /// "Explored · Read cart.js, cart.test.js · Ran npm, git · Edited cart.js".
    static func activityLine(_ tools: [TranscriptEntry]) -> String? {
        guard !tools.isEmpty else { return nil }
        var order: [String] = []
        var objects: [String: [String]] = [:]
        var explored = false
        func add(_ verb: String, _ object: String?) {
            if objects[verb] == nil { order.append(verb); objects[verb] = [] }
            if let object, !object.isEmpty, !(objects[verb]!.contains(object)) { objects[verb]!.append(object) }
        }
        for t in tools {
            let name = t.toolName ?? ""
            let detail = t.toolDetail ?? ""
            let file = (detail as NSString).lastPathComponent
            switch name {
            case "Read": explored = true; add("Read", file)
            case "Grep", "Glob", "LS": explored = true; add("Searched", nil)
            case "Bash":
                let cmd = detail.hasPrefix("$ ") ? String(detail.dropFirst(2)) : detail
                add("Ran", String((cmd.split(separator: " ").first.map(String.init) ?? cmd).prefix(20)))
            case "Edit", "MultiEdit": add("Edited", file)
            case "Write": add("Wrote", file)
            case "WebFetch", "WebSearch": add("Browsed", nil)
            case "Task", "Agent": add("Ran an agent", nil)
            case "TodoWrite": add("Planned", nil)
            case "AskUserQuestion": continue
            default: add(t.text, nil)
            }
        }
        var parts = order.map { verb -> String in
            let objs = objects[verb] ?? []
            guard !objs.isEmpty else { return verb }
            let shown = objs.prefix(3).joined(separator: ", ")
            return verb + " " + shown + (objs.count > 3 ? " +\(objs.count - 3)" : "")
        }
        if explored { parts.insert("Explored", at: 0) }
        return parts.joined(separator: " · ")
    }

    /// Synchronous one-shot read (call off the main thread).
    func loadOnce() -> [TranscriptEntry] {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > Self.initialWindow ? size - Self.initialWindow : 0
        try? handle.seek(toOffset: start)
        var lines = handle.readDataToEndOfFile().split(separator: 0x0A)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        let parsed = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        return Self.build(parsed)
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let path else { missing = true; return }
        queue.async { [weak self] in
            guard let self else { return }
            guard let handle = FileHandle(forReadingAtPath: path) else {
                DispatchQueue.main.async { self.missing = true }
                return
            }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size < self.offset {   // file was rewritten: start over
                self.offset = 0
                self.partial = Data()
                DispatchQueue.main.async { self.entries = []; self.toolIndex = [:]; self.title = nil; self.titleRank = 0 }
            }
            var cut = false
            if self.offset == 0 && size > Self.initialWindow {
                self.offset = size - Self.initialWindow
                cut = true
            }
            guard size > self.offset else {
                DispatchQueue.main.async { self.missing = false }
                return
            }
            try? handle.seek(toOffset: self.offset)
            var data = self.partial
            // Advance by what was actually read: Claude may append between the size check and the read.
            let chunk = handle.readDataToEndOfFile()
            data.append(chunk)
            self.offset += UInt64(chunk.count)
            // Keep an unfinished last line for the next tick.
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            self.partial = Data(lines.removeLast())
            if cut, !lines.isEmpty { lines.removeFirst() }   // first line may start mid-record
            let parsed = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
            DispatchQueue.main.async {
                self.missing = false
                if cut { self.truncated = true }
                self.ingest(parsed)
            }
        }
    }

    private func ingest(_ records: [[String: Any]]) {
        guard !records.isEmpty else { return }
        var state = BuildState(entries: entries, toolIndex: toolIndex, title: title, titleRank: titleRank)
        Self.apply(records, to: &state)
        title = state.title
        titleRank = state.titleRank
        var list = state.entries
        toolIndex = state.toolIndex
        if list.count > Self.maxEntries {
            let drop = list.count - Self.maxEntries
            list.removeFirst(drop)
            toolIndex = toolIndex.compactMapValues { $0 >= drop ? $0 - drop : nil }
            truncated = true
        }
        entries = list
    }

    struct BuildState {
        var entries: [TranscriptEntry]
        var toolIndex: [String: Int]
        var title: String?
        /// Which source `title` came from, so a weaker one never replaces a stronger one:
        /// 1 = Claude Code's AI title, 2 = the agent's name, 3 = a name the user gave the session.
        var titleRank = 0
        /// Background tasks (shell commands, agents, workflows) started and not finished yet: id → start time.
        var background: [String: Date] = [:]
        /// Agents that ran in the background; messaging one again restarts it.
        var asyncAgents: Set<String> = []

        mutating func setTitle(_ t: Any?, rank: Int) {
            guard let t = (t as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                  rank >= titleRank else { return }
            title = t
            titleRank = rank
        }
    }

    /// Follows background work: a backgrounded Bash command, an async agent or a workflow starts a task,
    /// and Claude Code's `<task-notification>` (or a TaskStop call) ends it.
    private static func trackBackground(_ rec: [String: Any], type: String, date: Date?, in state: inout BuildState) {
        func finish(_ text: String) {
            guard text.hasPrefix("<task-notification>"),
                  let open = text.range(of: "<task-id>"),
                  let close = text.range(of: "</task-id>", range: open.upperBound..<text.endIndex) else { return }
            state.background.removeValue(forKey: String(text[open.upperBound..<close.lowerBound]))
        }
        switch type {
        case "queue-operation":
            if rec["operation"] as? String == "enqueue", let c = rec["content"] as? String { finish(c) }
        case "user":
            if let r = rec["toolUseResult"] as? [String: Any] {
                let launched = r["status"] as? String == "async_launched"
                if let id = r["backgroundTaskId"] as? String {
                    state.background[id] = date ?? Date()
                } else if launched, let id = r["agentId"] as? String {
                    state.background[id] = date ?? Date()
                    state.asyncAgents.insert(id)
                } else if launched, let id = r["taskId"] as? String {
                    state.background[id] = date ?? Date()
                }
            }
            guard let msg = rec["message"] as? [String: Any] else { return }
            if let c = msg["content"] as? String {
                finish(c)
            } else if let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks where b["type"] as? String == "text" { finish(b["text"] as? String ?? "") }
            }
        case "assistant":
            guard let blocks = (rec["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            for b in blocks where b["type"] as? String == "tool_use" {
                let input = b["input"] as? [String: Any] ?? [:]
                switch b["name"] as? String {
                case "TaskStop", "KillShell", "KillBash":
                    if let id = (input["task_id"] ?? input["shell_id"]) as? String { state.background.removeValue(forKey: id) }
                case "SendMessage":
                    if let to = input["to"] as? String, state.asyncAgents.contains(to) { state.background[to] = date ?? Date() }
                default: break
                }
            }
        default: break
        }
    }

    static func build(_ records: [[String: Any]]) -> [TranscriptEntry] {
        var state = BuildState(entries: [], toolIndex: [:])
        apply(records, to: &state)
        return state.entries
    }

    private static func apply(_ records: [[String: Any]], to state: inout BuildState) {
        for rec in records {
            let type = rec["type"] as? String ?? ""
            switch type {
            case "custom-title": state.setTitle(rec["customTitle"], rank: 3); continue
            case "agent-name": state.setTitle(rec["agentName"], rank: 2); continue
            case "ai-title": state.setTitle(rec["aiTitle"], rank: 1); continue
            default: break
            }
            if rec["isSidechain"] as? Bool == true { continue }
            let date = (rec["timestamp"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            trackBackground(rec, type: type, date: date, in: &state)
            guard type == "user" || type == "assistant" else { continue }
            let uuid = rec["uuid"] as? String ?? UUID().uuidString
            let meta = rec["isMeta"] as? Bool == true
            guard let msg = rec["message"] as? [String: Any] else { continue }

            if let s = msg["content"] as? String {
                if meta { continue }
                if let e = userEntry(s, id: uuid, date: date) { state.entries.append(e) }
                continue
            }
            guard let blocks = msg["content"] as? [[String: Any]] else { continue }
            for (i, b) in blocks.enumerated() {
                let bid = "\(uuid)-\(i)"
                switch b["type"] as? String {
                case "text":
                    let text = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !meta else { continue }
                    if type == "assistant" {
                        state.entries.append(TranscriptEntry(id: bid, kind: .assistant, text: text, date: date))
                    } else if let e = userEntry(text, id: bid, date: date) {
                        state.entries.append(e)
                    }
                case "tool_use":
                    let name = b["name"] as? String ?? "Tool"
                    let input = b["input"] as? [String: Any] ?? [:]
                    let (title, detail) = describeTool(name, input)
                    state.entries.append(TranscriptEntry(id: bid, kind: .tool, text: title, toolName: name,
                                                         toolDetail: detail, date: date))
                    if let tid = b["id"] as? String { state.toolIndex[tid] = state.entries.count - 1 }
                case "tool_result":
                    guard let tid = b["tool_use_id"] as? String, let idx = state.toolIndex[tid],
                          idx < state.entries.count else { continue }
                    state.entries[idx].result = resultText(b["content"])
                    state.entries[idx].isError = b["is_error"] as? Bool ?? false
                default:
                    continue   // thinking, images, etc.
                }
            }
        }
    }

    static let relayMarker = "Message from the user (sent from Relay):"

    private static func userEntry(_ raw: String, id: String, date: Date?) -> TranscriptEntry? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        // A message Relay delivered through the Wait hook arrives wrapped in a system reminder.
        if let r = s.range(of: relayMarker) {
            var body = String(s[r.upperBound...])
            if let end = body.range(of: "</system-reminder>") { body = String(body[..<end.lowerBound]) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : TranscriptEntry(id: id, kind: .user, text: body, toolName: "relay", date: date)
        }
        if s.hasPrefix("<task-notification>") { return nil }
        if s.hasPrefix("[Request interrupted") {
            return TranscriptEntry(id: id, kind: .notice, text: "Interrupted", date: date)
        }
        // Slash commands are stored as XML-ish tags.
        if s.contains("<command-name>") {
            let name = between(s, "<command-name>", "</command-name>") ?? ""
            let args = between(s, "<command-args>", "</command-args>") ?? ""
            return TranscriptEntry(id: id, kind: .user, text: (name + " " + args).trimmingCharacters(in: .whitespaces), date: date)
        }
        if s.hasPrefix("<local-command-stdout>") || s.hasPrefix("<local-command-caveat>") || s.hasPrefix("<system-reminder>") {
            return nil
        }
        if s.count > 6000 { s = String(s.prefix(6000)) + "…" }
        return TranscriptEntry(id: id, kind: .user, text: s, date: date)
    }

    private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound])
    }

    private static func resultText(_ content: Any?) -> String {
        var text = ""
        if let s = content as? String { text = s }
        else if let arr = content as? [[String: Any]] {
            text = arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : ($0["type"] as? String == "image" ? "[image]" : nil) }
                .joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 4000 ? String(text.prefix(4000)) + "\n…" : text
    }

    static func describeTool(_ name: String, _ input: [String: Any]) -> (String, String?) {
        func str(_ k: String) -> String { input[k] as? String ?? "" }
        let file = (str("file_path") as NSString).lastPathComponent
        switch name {
        case "Bash": return (str("description").isEmpty ? "Ran a command" : str("description"), "$ " + str("command"))
        case "Read": return ("Read \(file)", str("file_path"))
        case "Write": return ("Wrote \(file)", str("file_path"))
        case "Edit", "MultiEdit": return ("Edited \(file)", str("file_path"))
        case "Grep": return ("Searched for \(str("pattern"))", str("path").isEmpty ? nil : str("path"))
        case "Glob": return ("Found files \(str("pattern"))", nil)
        case "WebFetch": return ("Fetched a page", str("url"))
        case "WebSearch": return ("Searched the web", str("query"))
        case "Task", "Agent": return ("Started an agent: \(str("description"))", str("prompt").isEmpty ? nil : String(str("prompt").prefix(300)))
        case "TodoWrite": return ("Updated the plan", nil)
        case "AskUserQuestion":
            let qs = (input["questions"] as? [[String: Any]] ?? []).compactMap { $0["question"] as? String }
            return ("Asked you", qs.joined(separator: "\n"))
        case "ExitPlanMode": return ("Proposed a plan", str("plan").isEmpty ? nil : str("plan"))
        default:
            let pretty = Store.jsonString(input, pretty: true)
            let label = name.hasPrefix("mcp__") ? name.split(separator: "_").filter { !$0.isEmpty }.dropFirst().joined(separator: " · ") : name
            return ("Used \(label)", pretty.isEmpty ? nil : String(pretty.prefix(800)))
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
}

/// Polls the text currently on screen in the agent's terminal (herdr, tmux, Terminal, iTerm).
final class TerminalSnapshot: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var unavailable: String?
    private let loc: TerminalLocation
    private var timer: Timer?
    private var busy = false

    init(loc: TerminalLocation) { self.loc = loc }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard !busy else { return }
        busy = true
        let loc = self.loc
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.read(loc)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let t): self.text = t; self.unavailable = nil
                case .failure(let e): self.unavailable = e.message
                }
            }
        }
    }

    struct Failure: Error { var message: String }

    static func read(_ loc: TerminalLocation) -> Result<String, Failure> {
        if let pane = loc.herdrPane, !pane.isEmpty, let herdr = Proc.which("herdr") {
            var env: [String: String] = [:]
            if let sock = loc.herdrSocket, !sock.isEmpty { env["HERDR_SOCKET_PATH"] = sock }
            let r = Proc.run(herdr, ["pane", "read", pane, "--source", "recent", "--lines", "400"], env: env, timeout: 8)
            if r.status == 0 { return .success(clean(r.stdout)) }
        }
        if let pane = loc.tmuxPane, !pane.isEmpty, let tmux = Proc.which("tmux") {
            var base: [String] = []
            if let t = loc.tmux, let sock = t.split(separator: ",").first, !sock.isEmpty { base = ["-S", String(sock)] }
            let r = Proc.run(tmux, base + ["capture-pane", "-p", "-J", "-t", pane, "-S", "-400"], timeout: 8)
            if r.status == 0 { return .success(clean(r.stdout)) }
        }
        if loc.isAppHosted {
            return .failure(Failure(message: "This agent runs inside an app, so there's no terminal to show. The conversation tab has everything."))
        }
        if let tty = loc.tty, !tty.isEmpty, tty != "??" {
            let dev = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            if loc.termProgram == "iTerm.app" {
                let r = AppleScript.run("""
                on run argv
                  tell application "iTerm2"
                    repeat with w in windows
                      repeat with t in tabs of w
                        repeat with s in sessions of t
                          if tty of s is (item 1 of argv) then return contents of s
                        end repeat
                      end repeat
                    end repeat
                  end tell
                  return ""
                end run
                """, args: [dev])
                if r.status == 0, !r.stdout.isEmpty { return .success(clean(r.stdout)) }
            } else {
                let r = AppleScript.run("""
                on run argv
                  tell application "Terminal"
                    repeat with w in windows
                      repeat with t in tabs of w
                        if tty of t is (item 1 of argv) then return contents of t
                      end repeat
                    end repeat
                  end tell
                  return ""
                end run
                """, args: [dev])
                if r.status == 0, !r.stdout.isEmpty { return .success(clean(lastLines(r.stdout, 400))) }
            }
        }
        return .failure(Failure(message: "Relay can read herdr, tmux, Terminal and iTerm tabs. For this terminal, use the conversation tab or open the terminal."))
    }

    private static func lastLines(_ s: String, _ n: Int) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).joined(separator: "\n")
    }

    /// Drops trailing blank lines and padding.
    private static func clean(_ s: String) -> String {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Window

/// Floating, resizable panel that shows one agent's session next to the pill.
final class SessionViewerController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var sessionId: String?
    private let store: Store
    private var keyMonitor: Any?

    init(store: Store) { self.store = store }

    var isOpen: Bool { panel?.isVisible ?? false }

    func show(sessionId: String, near anchor: NSRect?) {
        guard let s = store.sessions[sessionId] else { return }
        if self.sessionId == sessionId, let panel, panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        close()
        self.sessionId = sessionId
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.minSize = NSSize(width: 380, height: 360)
        p.delegate = self
        p.contentView = NSHostingView(rootView: SessionView(
            store: store, sessionId: sessionId,
            transcript: TranscriptReader(path: s.transcriptPath),
            snapshot: TerminalSnapshot(loc: s.terminal),
            onClose: { [weak self] in self?.close() }))

        // Sit beside the pill / card, toward the middle of the screen, vertically centered on it.
        // At the notch: left of the island or card, just under the menu bar.
        let center = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) ?? NSScreen.main
                ?? NSScreen.screens.first else { self.sessionId = nil; return }
        let vf = screen.visibleFrame
        let size = NSSize(width: 520, height: min(680, vf.height - 40))
        let dock = Appearance.shared.dock
        var x: CGFloat
        if dock == .left {
            x = min((anchor?.maxX ?? vf.minX) + 10, vf.maxX - size.width - 10)
        } else {
            x = (anchor?.minX ?? vf.maxX) - 10 - size.width
            if dock == .notch, x < vf.minX + 10, let a = anchor { x = a.maxX + 10 }   // no room on the left
            x = max(vf.minX + 10, x)
        }
        var y = dock == .notch ? vf.maxY - 10 - size.height : (anchor?.midY ?? vf.midY) - size.height / 2
        y = min(max(y, vf.minY + 10), vf.maxY - size.height - 10)
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let panel = self.panel, panel.isKeyWindow, e.keyCode == 53 else { return e }
            if panel.firstResponder is NSTextView { panel.makeFirstResponder(nil); return nil }
            self.close()
            return nil
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView = nil   // stops the readers' timers via onDisappear
        panel = nil
        sessionId = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.contentView = nil
        panel = nil
        sessionId = nil
    }
}

// MARK: - View

struct SessionView: View {
    @ObservedObject var store: Store
    let sessionId: String
    @StateObject var transcript: TranscriptReader
    @StateObject var snapshot: TerminalSnapshot
    var onClose: () -> Void
    @ViewState private var tab = 0
    @ViewState private var draft = ""

    init(store: Store, sessionId: String, transcript: TranscriptReader, snapshot: TerminalSnapshot, onClose: @escaping () -> Void) {
        self.store = store
        self.sessionId = sessionId
        _transcript = StateObject(wrappedValue: transcript)
        _snapshot = StateObject(wrappedValue: snapshot)
        self.onClose = onClose
    }

    private var session: AgentSession? { store.sessions[sessionId] }
    private var pending: InboxItem? { store.items.first { $0.sessionId == sessionId && $0.isActionable } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if let pending { pendingBanner(pending) }
            Group {
                if tab == 0 { conversation } else { terminal }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.3)
            composer
        }
        .background(ZStack { VisualEffect(material: .hudWindow); Color.black.opacity(Appearance.shared.tint) })
        .preferredColorScheme(.dark)
        .onAppear { transcript.start(); if tab == 1 { snapshot.start() } }
        .onDisappear { transcript.stop(); snapshot.stop() }
        .onChange(of: tab) { t in if t == 1 { snapshot.start() } else { snapshot.stop() } }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentAvatar(color: store.workspace(session?.workspaceId ?? "")?.color ?? .gray, status: session?.shownStatus ?? .ended)
                VStack(alignment: .leading, spacing: 1) {
                    Text(transcript.title ?? "@\(session?.handle ?? "agent")")
                        .font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text("@\(session?.handle ?? "")  ·  \(session?.shortPath ?? "")  ·  \(session?.shownStatus.label ?? "ended")")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let ws = store.workspace(session?.workspaceId ?? "") { WorkspaceChip(workspace: ws) }
            }
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    Text("Conversation").tag(0)
                    Text("Terminal").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                Button { store.focusTerminal(sessionId: sessionId) } label: {
                    Label(session?.terminal.isAppHosted == true ? "Open app" : "Open terminal", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 10)
    }

    private func pendingBanner(_ item: InboxItem) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.amber).frame(width: 7, height: 7)
            Text(item.kind == .question ? "Asking: \(item.body)" : "Needs permission: \(item.title)")
                .font(.system(size: 12)).lineLimit(1)
            Spacer()
            Button("Answer") {
                NotificationCenter.default.post(name: .relayOpenItem, object: item.id)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.amber.opacity(0.1))
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if transcript.truncated {
                        Text("Earlier messages aren't shown.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                            .frame(maxWidth: .infinity)
                    }
                    if transcript.entries.isEmpty {
                        Text(transcript.missing
                             ? "This session's transcript isn't available (transcript saving may be off). The Terminal tab shows what's on screen."
                             : "Nothing in this session yet.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                            .padding(.top, 30)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(transcript.entries) { e in
                        EntryView(entry: e).id(e.id)
                    }
                    ForEach(Array((store.outbox[sessionId] ?? []).enumerated()), id: \.offset) { _, text in
                        QueuedBubble(text: text) { store.cancelQueued(sessionId) }
                    }
                    if session?.status == .working {
                        HStack(spacing: 6) {
                            StatusRing(status: .working, workspaceColor: nil).scaleEffect(0.7)
                            Text("Working…").font(.system(size: 12)).foregroundStyle(Theme.amber.opacity(0.9))
                        }
                        .id("working")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: transcript.entries.last?.id) { _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.outbox[sessionId]?.count ?? 0) { _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: Terminal

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    if let msg = snapshot.unavailable, snapshot.text.isEmpty {
                        Text(msg).font(.system(size: 12)).foregroundStyle(Theme.textDim).padding(.top, 30)
                    } else {
                        Text(snapshot.text.isEmpty ? "Reading the terminal…" : snapshot.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(height: 1).id("tbottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color.black.opacity(0.35))
            .onChange(of: snapshot.text) { _ in proxy.scrollTo("tbottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("tbottom", anchor: .bottom) }
        }
    }

    // MARK: Composer

    private var deliveryHint: String {
        guard let s = session else { return "" }
        if !s.terminal.isAppHosted { return "Typed into its \(s.terminal.kindLabel) tab" }
        if store.canWake(sessionId) { return "Wakes the agent in the Claude app right away" }
        return s.status == .working ? "Delivered when it finishes this turn" : "Delivered after its next turn"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let toast = store.toast {
                Text(toast).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 14).transition(.opacity)
            }
            composerField
            Text(deliveryHint).font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 14).padding(.bottom, 8)
        }
    }

    private var composerField: some View {
        HStack(spacing: 8) {
            TextField("Message @\(session?.handle ?? "agent")…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...5)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane.fill").font(.system(size: 13))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.textFaint : .white)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || session == nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .padding(.horizontal, 10).padding(.top, 8)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        store.sendText(text, toSession: sessionId)
    }
}

private struct EntryView: View {
    let entry: TranscriptEntry
    @ViewState private var expanded = false

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(entry.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.blue.opacity(0.28)))
                    if entry.toolName == "relay" {
                        Text("via Relay").font(.system(size: 9.5)).foregroundStyle(Theme.textFaint)
                    }
                }
            }
        case .assistant:
            MarkdownView(text: entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .notice:
            Text(entry.text).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Circle().fill(entry.result == nil ? Theme.blue : (entry.isError ? Color.red : Theme.green))
                            .frame(width: 6, height: 6)
                        Text(entry.text).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if entry.toolDetail != nil || entry.result != nil {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textFaint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let d = entry.toolDetail, !d.isEmpty, expanded || entry.toolName == "Bash" {
                    Text(d).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textDim)
                        .lineLimit(expanded ? nil : 2)
                        .textSelection(.enabled)
                }
                if expanded, let r = entry.result, !r.isEmpty {
                    Text(r).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(entry.isError ? Color.red.opacity(0.85) : Color.white.opacity(0.7))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35)))
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.row))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.rowBorder, lineWidth: 1))
        }
    }
}

extension Notification.Name {
    static let relayOpenItem = Notification.Name("relayOpenItem")
    static let relayViewSession = Notification.Name("relayViewSession")
}

private struct QueuedBubble: View {
    let text: String
    var onCancel: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 3) {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 11).stroke(Theme.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                HStack(spacing: 6) {
                    Text("Queued").font(.system(size: 9.5)).foregroundStyle(Theme.amber)
                    Button("Cancel", action: onCancel).buttonStyle(.plain).font(.system(size: 9.5)).foregroundStyle(Theme.textFaint)
                }
            }
        }
    }
}
