import AppKit
import SwiftUI
import Combine
import ScreenCaptureKit
import AVFoundation

/// Scripted demo for the README GIF: `RELAY_DEMO=1 RELAY_DEMO_OUT=/path/demo.mov .build/release/Relay`.
///
/// Everything shown is mock data (fake accounts, agents and cards). Demo mode keeps its support
/// folder in a temp directory, starts no hook server, installs no hooks, runs no `claude` commands,
/// posts no notifications and samples no processes. It records only its own windows, so nothing
/// else on the screen ends up in the video.
enum Demo {
    static let isOn = ProcessInfo.processInfo.environment["RELAY_DEMO"] == "1"

    private static var outputURL: URL {
        let path = ProcessInfo.processInfo.environment["RELAY_DEMO_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("relay-demo.mov").path
        return URL(fileURLWithPath: path)
    }

    /// Settings a previous dev build may have saved must not change the recording.
    static func prepareDefaults() {
        UserDefaults.standard.setVolatileDomain([
            "pillVisible": true, "pillVertical": 0.5, "pillScreen": "main",
            "openCardWhenAsked": true, "nextStepsEnabled": false,
        ], forName: UserDefaults.argumentDomain)
    }

    private static var backdrop: NSWindow?
    private static var recorder: AnyObject?
    private static let state = DemoState()

    static func run(store: Store, ui: UIState, overlay: OverlayController, voice: VoiceController) {
        seed(store)
        overlay.positionPill()
        guard let screen = NSScreen.screens.first else { NSApp.terminate(nil); return }

        // The stage: a fixed rectangle at the right edge, around the pill.
        let vf = screen.visibleFrame
        let size = NSSize(width: 1040, height: 800)
        var y = overlay.pillFrame.midY - size.height / 2
        y = min(max(y, vf.minY), vf.maxY - size.height)
        let stage = NSRect(x: screen.frame.maxX - size.width, y: y, width: size.width, height: size.height)

        let win = NSWindow(contentRect: stage, styleMask: [.borderless], backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        win.isOpaque = true
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.contentView = NSHostingView(rootView: DemoBackdrop(state: state))
        win.orderFrontRegardless()
        backdrop = win

        guard #available(macOS 15.0, *) else {
            print("Demo recording needs macOS 15 or later")
            NSApp.terminate(nil)
            return
        }
        let rec = DemoRecorder()
        recorder = rec
        // Let the windows reach the window server before asking ScreenCaptureKit for them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            rec.start(stage: stage, screen: screen, url: outputURL) { ok in
                guard ok else { NSApp.terminate(nil); return }
                script(store: store, ui: ui, overlay: overlay, voice: voice) {
                    rec.stop { NSApp.terminate(nil) }
                }
            }
        }
    }

    // MARK: Mock data

    private static let home = "/Users/ada/code"

    private static func seed(_ store: Store) {
        var lab = Workspace(id: "lab", name: "Lab", configDir: nil, colorHex: Workspace.palette[1])
        lab.email = "ada@example.com"
        lab.plan = "Max"
        lab.loggedIn = true
        var acme = Workspace(id: "acme", name: "Acme", configDir: "/Users/ada/.claude-workspaces/acme",
                             colorHex: Workspace.palette[0])
        acme.email = "ada@acme.example"
        acme.plan = "Team"
        acme.loggedIn = true
        store.workspaces = [lab, acme]
        store.workspaceFilter = nil

        let now = Date()
        func session(_ id: String, ws: String, folder: String, title: String, status: AgentStatus,
                     prompt: String, term: TerminalLocation, minutesAgo: Double) -> AgentSession {
            var s = AgentSession(id: id, workspaceId: ws, cwd: "\(home)/\(folder)", pid: nil, terminal: term,
                                 handle: "claude-\(id.dropFirst())")
            s.title = title
            s.status = status
            s.lastPrompt = prompt
            s.startedAt = now.addingTimeInterval(-minutesAgo * 60)
            s.updatedAt = now.addingTimeInterval(-Double(Int(minutesAgo) % 3) * 20)
            return s
        }
        let iterm = TerminalLocation(tty: "/dev/ttys004", termProgram: "iTerm.app")
        let tmux = TerminalLocation(tty: "/dev/ttys007", termProgram: "tmux", tmux: "/tmp/tmux-501/default", tmuxPane: "%3")
        let ghostty = TerminalLocation(tty: "/dev/ttys009", termProgram: "ghostty")
        let app = TerminalLocation(entrypoint: "claude-desktop")

        let list = [
            session("s1", ws: "acme", folder: "orbital-api", title: "Rate-limit the launch endpoint", status: .working,
                    prompt: "add a rate limiter to /v1/launch, keep p99 under 5 ms", term: iterm, minutesAgo: 41),
            session("s2", ws: "lab", folder: "quantum-todo", title: "Port the solver to SIMD", status: .working,
                    prompt: "vectorize the constraint solver with std::simd and run the full bench suite", term: tmux, minutesAgo: 33),
            session("s3", ws: "lab", folder: "pixel-forge", title: "Fix shader hot-reload", status: .working,
                    prompt: "shaders stop reloading after the first edit, find out why", term: ghostty, minutesAgo: 18),
            session("s4", ws: "lab", folder: "dotfiles", title: "Make zsh start faster", status: .working,
                    prompt: "my shell takes forever to open, profile it and fix it", term: app, minutesAgo: 12),
            session("s5", ws: "acme", folder: "ledger-db", title: "Migrate users to Postgres 17", status: .working,
                    prompt: "write the migration for the users table and dry-run it on the staging dump", term: iterm, minutesAgo: 7),
        ]
        var sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        sessions["s2"]?.backgroundTasks = 2
        store.sessions = sessions
        HeatMonitor.shared.injectDemo([
            "s2": SessionHeat(cpu: 312, level: .hot),
            "s5": SessionHeat(cpu: 118, level: .warm),
        ])
    }

    private static func questionItem() -> InboxItem {
        var item = InboxItem(sessionId: "s1", workspaceId: "acme", kind: .question, title: "Algorithm",
                             body: "Which rate-limiting algorithm should /v1/launch use?")
        item.isLive = true
        item.toolName = "AskUserQuestion"
        item.questions = [AgentQuestion(
            question: "Which rate-limiting algorithm should /v1/launch use?", header: "Algorithm",
            options: [
                QuestionOption(label: "Token bucket (Recommended)", description: "Absorbs bursts, O(1) per request"),
                QuestionOption(label: "Sliding window log", description: "Exact, but O(n) memory per client"),
                QuestionOption(label: "Fixed window", description: "Simplest; lets 2× bursts through at the edges"),
            ],
            multiSelect: false)]
        item.prompt = "add a rate limiter to /v1/launch, keep p99 under 5 ms"
        item.activity = "Explored · Read launch.rs · Ran · cargo bench"
        item.said = "Two designs fit the 5 ms budget. One question before I wire it in."
        return item
    }

    private static func permissionItem() -> InboxItem {
        var item = InboxItem(sessionId: "s3", workspaceId: "lab", kind: .permission,
                             title: "Rebuild and start the shader watcher",
                             body: "$ cargo build --release && ./target/release/forge --watch shaders/")
        item.isLive = true
        item.toolName = "Bash"
        item.toolInputJSON = Store.jsonString([
            "command": "cargo build --release && ./target/release/forge --watch shaders/",
            "description": "Rebuild and start the shader watcher",
        ])
        item.permissionSuggestionsJSON = Store.jsonString([[
            "type": "addRules", "behavior": "allow", "destination": "projectSettings",
            "rules": [["toolName": "Bash", "ruleContent": "cargo build:*"]],
        ]])
        item.prompt = "shaders stop reloading after the first edit, find out why"
        item.activity = "Explored · Read watcher.rs · Edited · watcher.rs"
        item.said = "The watcher dies after the first rebuild. Restarting it on a fresh build."
        return item
    }

    private static func finishedItem() -> InboxItem {
        let reply = "Shell startup is down from 412 ms to 38 ms. Tests green."
        var item = InboxItem(sessionId: "s4", workspaceId: "lab", kind: .finished,
                             title: "Make zsh start faster", body: reply)
        item.prompt = "my shell takes forever to open, profile it and fix it"
        item.activity = "Explored · Read .zshrc · Ran · hyperfine"
        item.nextSteps = ["Looks good, commit it", "Do the same for my bash config"]
        item.nextStepsState = .ready
        return item
    }

    // MARK: Script

    private static func script(store: Store, ui: UIState, overlay: OverlayController, voice: VoiceController,
                               done: @escaping () -> Void) {
        func at(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func press(_ key: String, _ label: String) {
            state.keycap = (key, label)
            at(0.9) { state.keycap = nil }
        }
        func setStatus(_ id: String, _ status: AgentStatus, message: String? = nil) {
            guard var s = store.sessions[id] else { return }
            s.status = status
            if let message { s.lastMessage = message }
            s.updatedAt = Date()
            store.sessions[id] = s
        }
        func type(_ text: String, from t: Double) {
            for i in 1...text.count { at(t + Double(i) * 0.06) { ui.replyText = String(text.prefix(i)) } }
        }

        let q = questionItem(), f = finishedItem()
        var p = permissionItem()
        p.createdAt = q.createdAt.addingTimeInterval(-1)   // the question stays "1 of 2"
        at(0.8) { overlay.setHover(true) }
        at(2.4) { overlay.setHover(false) }
        // A question: "Agent needs you" slides out of the pill, then the card opens on it.
        at(3.4) {
            setStatus("s1", .waiting)
            state.append(.tool, "⏺ AskUserQuestion")
            state.append(.dim, "  ⎿  Waiting for your answer…")
            store.demoInsert(q)
        }
        at(5.6) {
            setStatus("s3", .waiting)
            store.demoInsert(p)
        }
        at(5.9) { overlay.openCard(focus: true) }
        at(7.4) { press("1", "pick option"); CardLogic.choose(0, item: q, store: store, ui: ui) }
        at(9.55) {
            state.lines.removeLast()
            state.append(.dim, "  ⎿  Token bucket")
            state.append(.tool, "⏺ Write(src/middleware/token_bucket.rs)")
            state.append(.dim, "  ⎿  Wrote 96 lines")
            state.append(.think, "✻ Wiring it into the router…")
        }
        at(10.6) { press("2", "allow + remember"); CardLogic.choose(1, item: p, store: store, ui: ui) }
        at(11.4) {
            setStatus("s4", .done, message: f.body)
            store.demoInsert(f)
        }
        // A reply to the finished turn: the undo bar shows your words.
        at(13.4) { press("space", "reply") }
        type("commit it", from: 13.6)
        at(14.6) {
            press("⏎", "send")
            ui.replyText = ""
            ui.schedule(itemId: f.id, label: "Message sent", barText: "commit it") { store.dismiss(f) }
        }
        at(17.2) { overlay.closeCard() }
        // Talk: the bar fills as you speak, then says who got it.
        at(17.8) { press("⌥⌥", "talk") }
        at(18.0) { voice.demoTalk("Make the orders page faster", to: "s5") }
        // Every agent: the list opens, and agents finish one by one.
        at(22.2) { overlay.toggleSide(.agents) }
        at(23.4) { setStatus("s3", .done) }
        at(24.0) { setStatus("s1", .done) }
        at(24.6) { HeatMonitor.shared.injectDemo(["s5": SessionHeat(cpu: 118, level: .warm)]); setStatus("s2", .done) }
        at(26.4) { overlay.closeSide() }
        // Nothing left: the empty inbox.
        at(27.0) { overlay.openCard(focus: false) }
        at(29.4) { overlay.closeCard() }
        at(30.0, done)
    }
}

// MARK: - Backdrop

final class DemoState: ObservableObject {
    enum Style { case prompt, tool, dim, think, plain }
    struct Line: Identifiable { let id = UUID(); let style: Style; let text: String }

    @Published var lines: [Line] = [
        Line(style: .plain, text: "✻ Welcome to Claude Code"),
        Line(style: .plain, text: ""),
        Line(style: .prompt, text: "> add a rate limiter to /v1/launch, keep p99 under 5 ms"),
        Line(style: .plain, text: ""),
        Line(style: .tool, text: "⏺ Read(src/routes/launch.rs)"),
        Line(style: .dim, text: "  ⎿  Read 182 lines"),
        Line(style: .tool, text: "⏺ Search(pattern: \"middleware\", path: \"src/\")"),
        Line(style: .dim, text: "  ⎿  Found 6 files"),
        Line(style: .tool, text: "⏺ Bash(cargo bench --bench launch)"),
        Line(style: .dim, text: "  ⎿  launch/p99  time: [3.91 ms 4.02 ms 4.17 ms]"),
    ]
    @Published var keycap: (String, String)?

    func append(_ style: Style, _ text: String) {
        lines.append(Line(style: style, text: text))
    }
}

private struct DemoBackdrop: View {
    @ObservedObject var state: DemoState

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: "#F4F5F3"), Color(hex: "#E4E6E2")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.white.opacity(0.8), .clear],
                           center: UnitPoint(x: 0.3, y: 0.25), startRadius: 10, endRadius: 560)
            Canvas { ctx, size in
                // A faint dot grid, like graph paper.
                let step: CGFloat = 24
                var y: CGFloat = step / 2
                while y < size.height {
                    var x: CGFloat = step / 2
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)),
                                 with: .color(.black.opacity(0.07)))
                        x += step
                    }
                    y += step
                }
            }
            terminal
                .frame(width: 540, height: 560)
                .offset(x: 34, y: 70)
            if let cap = state.keycap {
                let key = cap.0, label = cap.1
                HStack(spacing: 10) {
                    Text(key)
                        .font(.system(size: key.count > 1 ? 17 : 22, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .fixedSize()
                        .padding(.horizontal, key.count > 1 ? 10 : 0)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.3), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 3)
                    Text(label)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.75))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .offset(x: 34, y: 660)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.keycap?.0)
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach(["#FF5F57", "#FEBC2E", "#28C840"], id: \.self) { c in
                        Circle().fill(Color(hex: c)).frame(width: 12, height: 12)
                    }
                    Spacer()
                }
                Text("ada@acme: ~/code/orbital-api — claude")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(Color.white.opacity(0.04))
            VStack(alignment: .leading, spacing: 5) {
                ForEach(state.lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(color(line.style))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#0B0D12").opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }

    private func color(_ s: DemoState.Style) -> Color {
        switch s {
        case .prompt: return Color(hex: "#9AA5B1")
        case .tool: return .white.opacity(0.9)
        case .dim: return .white.opacity(0.45)
        case .think: return Theme.claude
        case .plain: return Theme.claude.opacity(0.9)
        }
    }
}

// MARK: - Recording

/// Records only this app's windows inside the stage rectangle.
@available(macOS 15.0, *)
private final class DemoRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var finished: (() -> Void)?
    private var started: ((Bool) -> Void)?

    func start(stage: NSRect, screen: NSScreen, url: URL, started: @escaping (Bool) -> Void) {
        self.started = started
        try? FileManager.default.removeItem(at: url)
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first,
                      let me = content.applications.first(where: { $0.processID == getpid() }) else {
                    print("Demo: couldn't find this app or the display in ScreenCaptureKit")
                    started(false); return
                }
                let filter = SCContentFilter(display: display, including: [me], exceptingWindows: [])
                let cfg = SCStreamConfiguration()
                // ScreenCaptureKit's source rect is in display points with a top-left origin.
                let f = screen.frame
                cfg.sourceRect = CGRect(x: stage.minX - f.minX, y: f.maxY - stage.maxY,
                                        width: stage.width, height: stage.height)
                let scale = screen.backingScaleFactor
                cfg.width = Int(stage.width * scale)
                cfg.height = Int(stage.height * scale)
                cfg.showsCursor = false
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
                let rc = SCRecordingOutputConfiguration()
                rc.outputURL = url
                rc.outputFileType = .mov
                rc.videoCodecType = .h264
                try stream.addRecordingOutput(SCRecordingOutput(configuration: rc, delegate: self))
                try await stream.startCapture()
                self.stream = stream
            } catch {
                print("Demo: recording failed to start: \(error.localizedDescription)")
                started(false)
            }
        }
    }

    func stop(_ done: @escaping () -> Void) {
        finished = done
        Task { @MainActor in
            try? await stream?.stopCapture()
            // Fallback in case the finish callback never comes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.finish() }
        }
    }

    private func finish() {
        let f = finished
        finished = nil
        f?()
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async {
            let s = self.started
            self.started = nil
            s?(true)
        }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        print("Demo: recording failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
            if let s = self.started { self.started = nil; s(false) } else { self.finish() }
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { self.finish() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Demo: stream stopped: \(error.localizedDescription)")
    }
}
