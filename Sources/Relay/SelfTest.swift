import Foundation
import AppKit
import CryptoKit
import IOKit.pwr_mgt

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
        inbox()
        artifacts()
        remoteAPI()
        devices()
        tailscale()
        tailnetDoor()
        connectionLimits()
        webPush()
        pushDispatch()
        remoteStart()
        keepAwake()
        geometry()
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

    // MARK: - Geometry

    /// Where the pill's pieces go on screen: the session viewer, the notch island's hit area,
    /// and the room the edge pill leaves for its hover labels.
    private static func geometry() {
        // The session viewer stays on screen, beside its anchor where there's room.
        let vf = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let size = NSSize(width: 520, height: 680)
        func onScreen(_ o: NSPoint, in vf: NSRect) -> Bool {
            o.x >= vf.minX + 10 && o.x + size.width <= vf.maxX - 10 && o.y >= vf.minY + 10 && o.y + size.height <= vf.maxY - 10
        }
        let island = NSRect(x: 627, y: 912, width: 258, height: 32)
        let atNotch = SessionViewerController.origin(size: size, anchor: island, visible: vf, dock: .notch)
        check("viewer: at the notch it sits left of the island", atNotch.x == island.minX - 10 - size.width && onScreen(atNotch, in: vf))
        let small = NSRect(x: 0, y: 0, width: 900, height: 944)
        let wide = NSRect(x: 150, y: 600, width: 610, height: 300)   // a card wider than the room either side
        let squeezed = SessionViewerController.origin(size: size, anchor: wide, visible: small, dock: .notch)
        check("viewer: no room left or right of the anchor, it overlaps it rather than leave the screen",
              onScreen(squeezed, in: small) && squeezed.x == small.maxX - 10 - size.width)
        let rightPill = NSRect(x: 1468, y: 300, width: 44, height: 380)
        let onRight = SessionViewerController.origin(size: size, anchor: rightPill, visible: vf, dock: .right)
        check("viewer: on the right edge it sits left of the pill", onRight.x == rightPill.minX - 10 - size.width && onScreen(onRight, in: vf))
        let leftPill = NSRect(x: 0, y: 300, width: 44, height: 380)
        let onLeft = SessionViewerController.origin(size: size, anchor: leftPill, visible: vf, dock: .left)
        check("viewer: on the left edge it sits right of the pill", onLeft.x == leftPill.maxX + 10 && onScreen(onLeft, in: vf))
        var everywhere = true
        for dock in PillDock.allCases {
            for ax in stride(from: CGFloat(-100), through: 1600, by: 50) {
                for w in [CGFloat(44), 258, 380, 640] {
                    let o = SessionViewerController.origin(size: size, anchor: NSRect(x: ax, y: 500, width: w, height: 300), visible: vf, dock: dock)
                    if !onScreen(o, in: vf) { everywhere = false }
                }
            }
            if !onScreen(SessionViewerController.origin(size: size, anchor: nil, visible: vf, dock: dock), in: vf) { everywhere = false }
        }
        check("viewer: on screen wherever the anchor is, for every dock", everywhere)
        let narrow = NSRect(x: 100, y: 0, width: 400, height: 944)
        check("viewer: on a screen narrower than it, its left edge stays on screen",
              SessionViewerController.origin(size: size, anchor: island, visible: narrow, dock: .notch).x == narrow.minX + 10)

        // The collapsed island takes the pointer over its body only: the notch and the two wings.
        let geo = NotchGeometry()
        geo.notchWidth = 185
        geo.height = 32
        let top: CGFloat = 982, mid: CGFloat = 756
        let shape = geo.shape(.collapsed, textScale: 1, midX: mid, top: top)
        let hit = geo.hitRect(.collapsed, textScale: 1, midX: mid, top: top)
        check("island: collapsed, the hit area leaves out the flares",
              hit.width == shape.width - 2 * NotchGeometry.ear && hit.midX == mid && hit.maxY == top && shape.contains(hit))
        check("island: collapsed, the hit area is the notch and two wings, no wider than 80 beyond the notch",
              hit.width == geo.notchWidth + 2 * geo.wing && hit.width - geo.notchWidth <= 80)
        let fourAbreast: CGFloat = 4 * 5.5 + 3 * 2.5, mascot = min(geo.collapsedHeight - 12, 22)
        check("island: a wing still fits the mascot and four dots abreast", geo.wing >= fourAbreast + 4 && geo.wing >= mascot + 8)
        let dash = geo.hitRect(.dashboard, textScale: 1.25, midX: mid, top: top)
        check("island: open, the hit area takes in the whole dashboard",
              dash.contains(geo.shape(.dashboard, textScale: 1.25, midX: mid, top: top)))
        geo.attachedWidth = geo.minBarWidth + 100
        check("island: with a panel hanging, the hit area is the bar as wide as the panel",
              geo.hitRect(.attached, textScale: 1, midX: mid, top: top).width == geo.attachedWidth + 2 * NotchGeometry.ear)

        // On an edge, the hover labels fit beside the buttons inside the pill's window.
        let labels = ["Inbox · ⌃⌥Space", PillView.inboxTip(waiting: 999),
                      PillView.agentsTip(hot: nil, working: 10, waiting: 10, running: 20),
                      PillView.agentsTip(hot: nil, working: 0, waiting: 0, running: 10),
                      "Workspaces & settings", "Talk to an agent · ⌥⌥", "Listening · ⌥⌥ sends",
                      "Talk with a screenshot", "Settings"]
        var fits = true, whole = true
        for k in [0.8, 1.0, 1.3] as [CGFloat] {
            for ts in [0.9, 1.0, 1.25] {
                let window = OverlayController.expandedWidth(pillScale: k, textScale: ts)
                for label in labels {
                    let text = HoverTip.textWidth(label, textScale: ts)
                    let measured = (label as NSString).size(withAttributes: [.font: HoverTip.font(textScale: ts)]).width
                    // Not cut short: as wide as SwiftUI draws it (whole points, rounded up) and more.
                    if text < ceil(measured) + 1 || text >= HoverTip.maxTextWidth * CGFloat(ts) { whole = false }
                    // The label's far end: 7 of padding, the button's 1 inset, the gap, then the label.
                    if (8 + HoverTip.gap) * k + text + 2 * HoverTip.padding > window - 2 { fits = false }
                }
            }
        }
        check("pill: every fixed hover label shows whole, at every text size", whole)
        check("pill: every hover label fits inside the open pill's window, at every pill and text size", fits)
        let hot = PillView.agentsTip(hot: "🔥 a-very-long-agent-name-from-a-deep-folder · 312% CPU", working: 12, waiting: 9, running: 30)
        check("pill: a label too long for the room is cut short to fit",
              HoverTip.textWidth(hot, textScale: 1.25) == HoverTip.maxTextWidth * 1.25)
        check("pill: the open pill's window is never narrower than before", OverlayController.expandedWidth(pillScale: 0.8, textScale: 0.9) >= 200)
    }

    // MARK: - Inbox

    private static func inbox() {
        var ask = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .question, title: "Rounding", body: "Which?")
        ask.toolName = "AskUserQuestion"
        ask.isLive = true
        ask.questions = [AgentQuestion(question: "Which?", header: "Rounding", options: [], multiSelect: false)]
        var bash = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .permission, title: "Run", body: "$ ls")
        bash.toolName = "Bash"
        bash.isLive = true
        bash.toolInputJSON = Store.jsonString(["command": "ls"])
        var bash2 = bash
        bash2.id = "bash2"
        bash2.toolInputJSON = Store.jsonString(["command": "pwd"])
        var fallback = bash
        fallback.id = "fallback"
        fallback.isLive = false
        let done = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .finished, title: "Done", body: "ok")
        let elicit = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .waiting, title: Store.needsInputTitle, body: "Pick")
        let idle = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .waiting, title: "Waiting for you", body: "")

        func answered(_ items: [InboxItem], _ tool: String?, _ input: [String: Any]?, session: String = "s1") -> Set<String> {
            Store.answeredElsewhere(items: items, sessionId: session, tool: tool, input: input)
        }
        let answeredInput: [String: Any] = ["questions": [["question": "Which?"]], "answers": ["Which?": "Half-even"]]
        check("inbox: a question answered in the terminal closes its card",
              answered([ask, done], "AskUserQuestion", answeredInput) == [ask.id])
        check("inbox: another tool finishing leaves the question open", answered([ask], "Read", ["file_path": "/x"]).isEmpty)
        check("inbox: another agent's tool leaves it open", answered([ask], "AskUserQuestion", answeredInput, session: "s2").isEmpty)
        check("inbox: parallel prompts for one tool are told apart by input",
              answered([bash, bash2], "Bash", ["command": "pwd"]) == ["bash2"])
        check("inbox: fallback cards are left to their own clean-up", answered([fallback], "Bash", ["command": "ls"]).isEmpty)
        check("inbox: no tool name, nothing closes", answered([ask], nil, nil).isEmpty)

        func moved(_ items: [InboxItem], _ tool: String?, session: String = "s1", subagent: Bool = false) -> Set<String> {
            Store.questionsMovedPast(items: items, sessionId: session, tool: tool, fromSubagent: subagent)
        }
        check("inbox: the agent starting another tool closes its open question", moved([ask, bash, done], "Read") == [ask.id])
        check("inbox: a second question doesn't close the first", moved([ask], "AskUserQuestion").isEmpty)
        check("inbox: a subagent's tool leaves the question open", moved([ask], "Read", subagent: true).isEmpty)
        check("inbox: another agent's tool leaves it open", moved([ask], "Read", session: "s2").isEmpty)
        check("inbox: permission prompts aren't closed by other tools", moved([bash], "Read").isEmpty)

        check("inbox: Asking holds questions, prompts and MCP input requests",
              [ask, bash, elicit].allSatisfy(InboxFilter.asking.matches) && ![done, idle].contains(where: InboxFilter.asking.matches))
        check("inbox: Done holds finished and idle agents",
              [done, idle].allSatisfy(InboxFilter.done.matches) && ![ask, bash, elicit].contains(where: InboxFilter.done.matches))
        check("inbox: All holds everything", [ask, bash, elicit, done, idle].allSatisfy(InboxFilter.all.matches))
    }

    // MARK: - Artifacts

    private static func artifacts() {
        func line(_ obj: [String: Any]) -> String { Store.jsonString(obj) }
        let publish = line(["type": "assistant", "timestamp": "2026-10-05T10:00:00.000Z", "message": ["content": [
            ["type": "tool_use", "id": "toolu_A", "name": "Artifact",
             "input": ["file_path": "/tmp/x/options.html", "description": "Three layouts"]]]]])
        let published = line(["type": "user", "timestamp": "2026-10-05T10:00:05.000Z",
                              "toolUseResult": ["url": "https://claude.ai/artifact/abc", "path": "/tmp/x/options.html", "title": "Layout options"],
                              "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_A", "content": "Published"]]]])
        let read = line(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "toolu_R", "name": "Artifact", "input": ["action": "read", "url": "https://claude.ai/artifact/abc"]]]]])
        let readDone = line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_R", "content": "<html>"]]]])
        let send = line(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "toolu_S", "name": "SendUserFile", "input": ["files": ["/tmp/x/report.md", "/tmp/x/chart.png"]]]]]])
        let sent = line(["type": "user", "timestamp": "2026-10-05T10:01:00Z",
                         "toolUseResult": ["caption": "The report", "attachments": [["path": "/tmp/x/report.md"], ["path": "/tmp/x/chart.png"]]],
                         "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_S", "content": "2 files delivered"]]]])
        let failed = line(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "toolu_F", "name": "SendUserFile", "input": ["files": ["/tmp/x/missing.txt"]]]]]])
        let failedDone = line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_F", "is_error": true, "content": "no such file"]]]])
        let evil = line(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "toolu_E", "name": "Artifact", "input": ["file_path": "/tmp/x/e.html"]]]]])
        let evilDone = line(["type": "user", "toolUseResult": ["url": "https://evil.example/artifact/x", "path": "/tmp/x/e.html"],
                             "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_E", "content": "Published"]]]])

        var pending: [String: (name: String, input: [String: Any])] = [:]
        var refs: [ArtifactRef] = []
        let all = [publish, published, read, readDone, send, sent, failed, failedDone, evil, evilDone].joined(separator: "\n") + "\n"
        ArtifactIndex.scan(Data(all.utf8), pending: &pending, refs: &refs)
        let page = refs.first { $0.path == "/tmp/x/options.html" }
        check("artifacts: a published page is found with its title, link and caption",
              page?.title == "Layout options" && page?.url == "https://claude.ai/artifact/abc" && page?.caption == "Three layouts"
              && page?.kind == .html && page?.createdAt == ArtifactIndex.parseDate("2026-10-05T10:00:05.000Z"))
        check("artifacts: files sent to you are found, one entry each",
              refs.filter { $0.path == "/tmp/x/report.md" || $0.path == "/tmp/x/chart.png" }.count == 2
              && refs.first { $0.path == "/tmp/x/report.md" }?.kind == .markdown && refs.first { $0.path == "/tmp/x/chart.png" }?.kind == .image)
        check("artifacts: reads and failed sends aren't artifacts", !refs.contains { $0.path.contains("missing") } && refs.count == 4)
        check("artifacts: only claude.ai artifact links are passed on", refs.first { $0.path == "/tmp/x/e.html" }?.url == nil)
        check("artifacts: newest first", refs.first?.path == "/tmp/x/e.html")
        check("artifacts: nothing left waiting for a result", pending.isEmpty)

        // A republish of the same file keeps one entry, moved to the top, still with its link.
        let republish = line(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "toolu_B", "name": "Artifact", "input": ["file_path": "/tmp/x/options.html"]]]]])
        let republished = line(["type": "user", "toolUseResult": ["path": "/tmp/x/options.html"],
                                "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_B", "content": "Updated"]]]])
        ArtifactIndex.scan(Data((republish + "\n" + republished + "\n").utf8), pending: &pending, refs: &refs)
        check("artifacts: a republished page stays one entry and keeps its link",
              refs.count == 4 && refs.first?.path == "/tmp/x/options.html" && refs.first?.url == "https://claude.ai/artifact/abc")

        // Incremental reads: a half-written last line waits for the next read.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-selftest-art-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        try? Data((publish + "\n" + published.prefix(40)).utf8).write(to: transcript)
        let index = ArtifactIndex()
        let first = index.current(transcript.path)
        if let h = FileHandle(forWritingAtPath: transcript.path) {
            h.seekToEndOfFile(); h.write(Data((published.dropFirst(40) + "\n").utf8)); try? h.close()
        }
        let second = index.current(transcript.path)
        check("artifacts: a half-written line is read once it's complete", first.isEmpty && second.first?.title == "Layout options")

        // Tickets.
        let tickets = ArtifactTickets()
        var clock = Date(timeIntervalSince1970: 1_759_660_000)
        tickets.now = { clock }
        let file = dir.appendingPathComponent("page.html")
        try? Data("<h1>hi</h1>".utf8).write(to: file)
        let t = tickets.issue(path: file.path)
        check("tickets: 32 random bytes, URL-safe", t.count == 43 && t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
              && tickets.issue(path: file.path) != t)
        check("tickets: a ticket opens its file, with or without a name after it",
              tickets.path(for: "/view/\(t)") == file.path && tickets.path(for: "/view/\(t)/page.html") == file.path)
        check("tickets: unknown or malformed tickets open nothing",
              tickets.path(for: "/view/nope") == nil && tickets.path(for: "/view/") == nil && tickets.path(for: "/api/\(t)") == nil)
        let served = tickets.response(for: "/view/\(t)/page.html")
        check("tickets: a page is served sandboxed, frameable only by Relay's page",
              served.status == 200 && served.contentType.hasPrefix("text/html")
              && served.extraHeaders["Content-Security-Policy"]?.hasPrefix("sandbox allow-scripts") == true
              && served.extraHeaders["Content-Security-Policy"]?.contains("allow-same-origin") == false
              && served.extraHeaders["Content-Security-Policy"]?.contains("frame-ancestors 'self'") == true
              && served.extraHeaders["X-Content-Type-Options"] == "nosniff" && served.extraHeaders["Referrer-Policy"] == "no-referrer")
        check("tickets: images and PDFs aren't sandboxed; SVG is",
              ArtifactTickets.headers(for: "/a.png")["Content-Security-Policy"] == "frame-ancestors 'self'"
              && ArtifactTickets.headers(for: "/a.pdf")["Content-Security-Policy"] == "frame-ancestors 'self'"
              && ArtifactTickets.headers(for: "/a.svg")["Content-Security-Policy"]?.hasPrefix("sandbox") == true)
        check("tickets: other text is served as plain text, unknown files as downloads",
              ArtifactTickets.contentType("/a.js") == "text/plain; charset=utf-8" && ArtifactTickets.contentType("/a.md") == "text/plain; charset=utf-8"
              && ArtifactTickets.contentType("/a.zip") == "application/octet-stream"
              && ArtifactTickets.headers(for: "/a.zip")["Content-Disposition"]?.hasPrefix("attachment") == true)
        clock = clock.addingTimeInterval(ArtifactTickets.ttl + 1)
        check("tickets: expire after 10 minutes", tickets.path(for: "/view/\(t)") == nil && tickets.response(for: "/view/\(t)").status == 404)
        let gone = tickets.issue(path: dir.appendingPathComponent("deleted.html").path)
        check("tickets: a deleted file is a 404", tickets.response(for: "/view/\(gone)").status == 404)

        // The phone's view of them.
        var s = AgentSession(id: "s1", workspaceId: "w1", cwd: "/tmp", pid: nil, terminal: TerminalLocation(), status: .waiting, handle: "claude-1")
        let now = Date(timeIntervalSince1970: 1_759_660_000)
        s.turnStartedAt = now.addingTimeInterval(-60)
        let fresh = ArtifactRef(id: "a", path: "/tmp/x/a.html", title: "A", url: "https://claude.ai/artifact/a", caption: nil, createdAt: now.addingTimeInterval(-10))
        let older = ArtifactRef(id: "b", path: "/tmp/x/b.md", title: "B", url: nil, caption: "notes", createdAt: now.addingTimeInterval(-600))
        let snap = RemoteAPI.snapshot(workspaces: [], sessions: [s], items: [], filter: nil, heat: [:], caps: [.read, .answer],
                                      artifacts: { _ in [fresh, older] }, now: now)
        let arts = ((snap["sessions"] as? [[String: Any]])?.first?["artifacts"] as? [[String: Any]]) ?? []
        check("artifacts: the snapshot lists them without paths, marking this turn's",
              arts.count == 2 && arts[0]["inTurn"] as? Bool == true && arts[1]["inTurn"] as? Bool == false
              && arts[0]["url"] as? String == "https://claude.ai/artifact/a" && arts[1]["kind"] as? String == "markdown"
              && !arts.contains { $0["path"] != nil } && JSONSerialization.isValidJSONObject(snap))
        check("artifacts: opening one needs only read access", RemoteAPI.capability("POST", "/api/artifact/open") == .read)
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
        check("api: snapshot marks which items ask you something", item["asking"] as? Bool == true)
        check("api: snapshot is valid JSON", JSONSerialization.isValidJSONObject(snap))
    }

    // MARK: - Devices

    /// A request signed the way the phone page signs it.
    private static func signedRequest(_ method: String, _ target: String, body: String = "", ts: Date,
                                      key: P256.Signing.PrivateKey, device: String,
                                      login: String? = "ada@example.com") -> HTTPRequest {
        let tsText = String(Int64(ts.timeIntervalSince1970 * 1000))
        let bodyData = Data(body.utf8)
        let message = DeviceStore.signedMessage(method: method, target: target, ts: tsText, body: bodyData)
        let sig = (try? key.signature(for: Data(message.utf8)).rawRepresentation) ?? Data()
        var headers = ["x-relay-device": device, "x-relay-ts": tsText, "x-relay-sig": sig.base64URLEncodedString()]
        if let login { headers["tailscale-user-login"] = login }
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        return HTTPRequest(method: method, path: path, query: [:], headers: headers, body: bodyData,
                           remoteHost: "127.0.0.1", target: target)
    }

    /// n − s on P-256: the other valid signature for the same message (ECDSA malleability).
    private static func malleated(_ raw: Data) -> Data {
        let n: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                          0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51]
        let s = [UInt8](raw.suffix(32))
        var out = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for i in stride(from: 31, through: 0, by: -1) {
            var d = Int(n[i]) - Int(s[i]) - borrow
            borrow = d < 0 ? 1 : 0
            if d < 0 { d += 256 }
            out[i] = UInt8(d)
        }
        return raw.prefix(32) + Data(out)
    }

    private static func devices() {
        let now = Date(timeIntervalSince1970: 1_759_660_000)
        let file = Paths.support.appendingPathComponent("devices-test.json")
        let store = DeviceStore(file: file)
        let key = P256.Signing.PrivateKey()
        let pub = key.publicKey.x963Representation.base64URLEncodedString()
        guard let phone = store.addDevice(name: "Ada's iPhone\u{7}", publicKey: pub, login: "ada@example.com", now: now) else {
            check("devices: pairing stores the device", false); return
        }
        check("devices: pairing stores the device", store.active.count == 1 && store.ownerLogin == "ada@example.com"
              && phone.name == "Ada's iPhone" && phone.id.count == 22)

        func outcome(_ r: HTTPRequest, at t: Date = now) -> Result<Device, DeviceStore.Rejection> { store.check(r, now: t) }
        func rejected(_ r: HTTPRequest, _ why: DeviceStore.Rejection, at t: Date = now) -> Bool {
            if case .failure(let e) = outcome(r, at: t) { return e == why }
            return false
        }

        let ok = signedRequest("GET", "/api/state", ts: now, key: key, device: phone.id)
        check("devices: a valid signature is accepted", (try? outcome(ok).get())?.id == phone.id)
        check("devices: the same request again is a replay", rejected(ok, .replayed))

        var tampered = signedRequest("POST", "/api/answer", body: #"{"action":"dismiss"}"#, ts: now, key: key, device: phone.id)
        tampered.body = Data(#"{"action":"dismisx"}"#.utf8)
        check("devices: a tampered body is rejected", rejected(tampered, .badSignature))
        var moved = signedRequest("GET", "/api/session?id=a", ts: now, key: key, device: phone.id)
        moved.target = "/api/session?id=b"
        check("devices: a tampered path or query is rejected", rejected(moved, .badSignature))
        var otherMethod = signedRequest("GET", "/api/kill", ts: now, key: key, device: phone.id)
        otherMethod.method = "POST"
        check("devices: a tampered method is rejected", rejected(otherMethod, .badSignature))

        for (offset, accepted) in [(-61.0, false), (61, false), (-60, true), (59, true)] {
            let r = signedRequest("GET", "/api/state?n=\(offset)", ts: now.addingTimeInterval(offset), key: key, device: phone.id)
            let result = outcome(r)
            let pass: Bool
            if accepted { pass = (try? result.get()) != nil } else { pass = rejected(r, .staleTimestamp) }
            check("devices: timestamp \(offset > 0 ? "+" : "")\(Int(offset)) s is \(accepted ? "accepted" : "rejected")", pass)
        }
        let ahead = signedRequest("GET", "/api/state?edge=1", ts: now.addingTimeInterval(60), key: key, device: phone.id)
        _ = outcome(ahead)
        check("devices: a request stamped a minute ahead can't be replayed two minutes later",
              rejected(ahead, .replayed, at: now.addingTimeInterval(120)))
        var badTs = signedRequest("GET", "/api/state", ts: now, key: key, device: phone.id)
        badTs.headers["x-relay-ts"] = "-1759660000000"
        check("devices: a malformed timestamp is rejected", rejected(badTs, .badTimestamp))

        // A captured request can't be replayed by rewriting its signature (s → n − s).
        let fresh = signedRequest("GET", "/api/state?m=1", ts: now, key: key, device: phone.id)
        _ = outcome(fresh)
        var twin = fresh
        let raw = Data(base64URL: fresh.headers["x-relay-sig"] ?? "") ?? Data()
        twin.headers["x-relay-sig"] = malleated(raw).base64URLEncodedString()
        // CryptoKit accepts the rewritten signature, so it's the replay cache that has to catch it.
        check("devices: a malleated signature can't replay a request", rejected(twin, .replayed))

        var short = signedRequest("GET", "/api/state?s=1", ts: now, key: key, device: phone.id)
        short.headers["x-relay-sig"] = Data(repeating: 1, count: 63).base64URLEncodedString()
        check("devices: a signature of the wrong length is rejected", rejected(short, .badSignature))
        let impostor = signedRequest("GET", "/api/state?i=1", ts: now, key: P256.Signing.PrivateKey(), device: phone.id)
        check("devices: another key's signature is rejected", rejected(impostor, .badSignature))

        check("devices: a request without the Tailscale login is rejected",
              rejected(signedRequest("GET", "/api/state?l=1", ts: now, key: key, device: phone.id, login: nil), .noLogin))
        check("devices: a request from another Tailscale login is rejected",
              rejected(signedRequest("GET", "/api/state?l=2", ts: now, key: key, device: phone.id, login: "eve@example.com"), .wrongLogin))
        check("devices: an unknown device is rejected",
              rejected(signedRequest("GET", "/api/state?u=1", ts: now, key: key, device: "nope"), .unknownDevice))

        // Hard-coded vector from WebCrypto (non-extractable ECDSA P-256 key, raw r‖s signature).
        let webStore = DeviceStore(file: Paths.support.appendingPathComponent("devices-webcrypto.json"))
        let webKey = "BOx3iKYdRY4nUAZpsN98DXEemL2Fj7D6FSCuW3R77a6zPDuwe23xyjlOm8NQuWkC82fsTnTC0sdH5hgpa3Ovqsg"
        if let web = webStore.addDevice(name: "WebCrypto", publicKey: webKey, login: "ada@example.com", now: now) {
            let body = #"{"action":"dismiss","itemId":"A1B2"}"#
            check("devices: WebCrypto body hash matches",
                  DeviceStore.signedMessage(method: "POST", target: "/api/answer", ts: "1759660000000", body: Data(body.utf8))
                    .hasSuffix("1f46c23ac6ff02d9a0a8e06242728766eae3fbfcf7a955e25b902e584d498c1f"))
            let req = HTTPRequest(method: "POST", path: "/api/answer", query: [:], headers: [
                "x-relay-device": web.id, "x-relay-ts": "1759660000000",
                "x-relay-sig": "IyR2tqnhMyposEeKnEhIwSj6RvIqwk6j_H92gXD3Iy8xofAY_OxhmHzdWUOaZqXZomJd9MfTxQm5VatGPsJ26g",
                "tailscale-user-login": "ada@example.com",
            ], body: Data(body.utf8), remoteHost: "127.0.0.1", target: "/api/answer")
            check("devices: a WebCrypto signature verifies", webStore.verify(req, now: now)?.id == web.id)
        } else {
            check("devices: the WebCrypto public key parses", false)
        }
        check("devices: invalid public keys are refused",
              DeviceStore.parseKey(Data([0x04] + [UInt8](repeating: 7, count: 64)).base64URLEncodedString()) == nil
              && DeviceStore.parseKey(key.publicKey.compressedRepresentation.base64URLEncodedString()) == nil
              && DeviceStore.parseKey("not base64!") == nil)

        // Owner and revocation.
        check("devices: a second pairing from another login is refused",
              store.pairingProblem(publicKey: pub, login: "eve@example.com") == .otherOwner
              && store.addDevice(name: "Eve", publicKey: pub, login: "eve@example.com", now: now) == nil)
        store.revoke(phone.id)
        check("devices: a revoked device is rejected",
              rejected(signedRequest("GET", "/api/state?r=1", ts: now, key: key, device: phone.id), .unknownDevice))
        check("devices: revoking the last device forgets the owner", store.ownerLogin == nil
              && store.pairingProblem(publicKey: pub, login: "eve@example.com") == nil)

        // The file: 0600, and it reads back the same.
        let mode = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.intValue
        check("devices: devices.json is mode 0600", mode == 0o600)
        let reloaded = DeviceStore(file: file)
        check("devices: devices.json reads back", reloaded.devices == store.devices && reloaded.active.isEmpty)

        // Pairing codes: single use, five minutes.
        let codes = DeviceStore(file: Paths.support.appendingPathComponent("devices-codes.json"))
        let code = codes.newPairingCode(now: now)
        check("devices: a pairing code is 32 random bytes", Data(base64URL: code)?.count == 32)
        check("devices: a wrong pairing code is refused", !codes.consumePairingCode(code + "x", now: now))
        check("devices: the pairing code works once", codes.consumePairingCode(code, now: now.addingTimeInterval(299)))
        check("devices: a used pairing code is refused", !codes.consumePairingCode(code, now: now.addingTimeInterval(1)))
        let late = codes.newPairingCode(now: now)
        check("devices: an expired pairing code is refused", !codes.consumePairingCode(late, now: now.addingTimeInterval(301)))
        let replaced = codes.newPairingCode(now: now)
        _ = codes.newPairingCode(now: now)
        check("devices: a new pairing code replaces the old one", !codes.consumePairingCode(replaced, now: now))

        // More than 20 failures a minute starts a 60 s cool-down.
        let cool = DeviceStore(file: Paths.support.appendingPathComponent("devices-cool.json"))
        for i in 0..<20 { cool.recordFailure(now.addingTimeInterval(Double(i))) }
        check("devices: 20 failures a minute don't cool down", !cool.isCoolingDown(now.addingTimeInterval(20)))
        cool.recordFailure(now.addingTimeInterval(21))
        let coolCode = cool.newPairingCode(now: now.addingTimeInterval(21))
        check("devices: the 21st failure cools down", cool.isCoolingDown(now.addingTimeInterval(22)))
        check("devices: no pairing during the cool-down", !cool.consumePairingCode(coolCode, now: now.addingTimeInterval(22)))
        check("devices: the cool-down ends after 60 s", !cool.isCoolingDown(now.addingTimeInterval(82)))
        let shared = DeviceStore(file: Paths.support.appendingPathComponent("devices-logins.json"))
        for i in 0..<30 { shared.recordFailure(now.addingTimeInterval(Double(i)), login: "eve@example.com") }
        let owners = shared.newPairingCode(now: now.addingTimeInterval(30))
        check("devices: one login's failures don't stop another's pairing",
              shared.isCoolingDown(now.addingTimeInterval(31), login: "eve@example.com")
              && !shared.isCoolingDown(now.addingTimeInterval(31), login: "ada@example.com")
              && shared.consumePairingCode(owners, login: "ada@example.com", now: now.addingTimeInterval(31)))
        let slow = DeviceStore(file: Paths.support.appendingPathComponent("devices-slow.json"))
        for i in 0..<21 { slow.recordFailure(now.addingTimeInterval(Double(i) * 4)) }
        check("devices: 21 failures spread over 80 s don't cool down", !slow.isCoolingDown(now.addingTimeInterval(81)))
        let flood = DeviceStore(file: Paths.support.appendingPathComponent("devices-flood.json"))
        let started = Date()
        for i in 0..<200_000 { flood.recordFailure(now.addingTimeInterval(Double(i) / 1000)) }
        check("devices: a flood of failures costs constant work each", Date().timeIntervalSince(started) < 2
              && flood.isCoolingDown(now.addingTimeInterval(200)))
    }

    // MARK: - Tailscale

    private static func tailscale() {
        func status(_ json: String) -> Tailscale.Status? { Tailscale.parseStatus(Data(json.utf8)) }
        func serve(_ json: String) -> Tailscale.ServeStatus? { Tailscale.parseServeStatus(Data(json.utf8)) }
        func port(_ json: String, previous: UInt16? = nil) -> Result<(port: UInt16, existing: Bool), Tailscale.Failure>? {
            serve(json).map { Tailscale.choosePort($0, previous: previous) }
        }
        func picks(_ json: String, _ expected: UInt16, existing: Bool, previous: UInt16? = nil) -> Bool {
            if case .success(let c)? = port(json, previous: previous) { return c.port == expected && c.existing == existing }
            return false
        }

        let running = """
        {"Version":"1.88.1","TUN":false,"BackendState":"Running","HaveNodeKey":true,"AuthURL":"",
         "TailscaleIPs":["100.101.102.103"],
         "Self":{"ID":"n1","HostName":"Ada's MacBook Pro","DNSName":"adas-macbook-pro.tail1234.ts.net.","Online":true},
         "Health":[],"MagicDNSSuffix":"tail1234.ts.net",
         "CurrentTailnet":{"Name":"ada@example.com","MagicDNSSuffix":"tail1234.ts.net","MagicDNSEnabled":true},
         "CertDomains":["adas-macbook-pro.tail1234.ts.net"],"Peer":{},"User":{}}
        """
        let r = status(running)
        check("tailscale: parses a running status", r?.backendState == "Running" && r?.dnsName == "adas-macbook-pro.tail1234.ts.net"
              && r?.magicDNS == true && r?.certDomains == ["adas-macbook-pro.tail1234.ts.net"])
        check("tailscale: a running status with MagicDNS is usable", r.map(Tailscale.problem(with:)) == .some(nil))
        let stopped = status(#"{"BackendState":"Stopped","Self":{"DNSName":"mac.tail1234.ts.net."},"CertDomains":null,"MagicDNSSuffix":"tail1234.ts.net"}"#)
        check("tailscale: a stopped Tailscale is reported", stopped.flatMap(Tailscale.problem(with:)) == .notRunning("Stopped")
              && stopped?.certDomains == [])
        check("tailscale: a signed-out Tailscale asks to sign in",
              status(#"{"BackendState":"NeedsLogin","Self":null}"#).flatMap(Tailscale.problem(with:)) == .needsLogin)
        check("tailscale: MagicDNS off is reported", status(#"""
            {"BackendState":"Running","Self":{"DNSName":"mac.tail1234.ts.net."},"CurrentTailnet":{"MagicDNSEnabled":false}}
            """#).flatMap(Tailscale.problem(with:)) == .magicDNSOff)
        check("tailscale: no name is reported", status(#"""
            {"BackendState":"Running","Self":{"DNSName":""},"CurrentTailnet":{"MagicDNSEnabled":true}}
            """#).flatMap(Tailscale.problem(with:)) == .noName)
        check("tailscale: garbage isn't a status", status("tailscale: not running") == nil && serve("<html>") == nil)

        let ours = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47902"}}}}}"#
        let foreign443 = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}"#
        check("tailscale: nothing served means 443 is free", picks("{}\n", 443, existing: false) && picks("null\n", 443, existing: false)
              && picks("", 443, existing: false))
        check("tailscale: 443 already Relay's is kept", picks(ours, 443, existing: true) && serve(ours)?.relayPorts == [443])
        check("tailscale: 443 serving something else falls back to 8443",
              picks(foreign443, 8443, existing: false) && serve(foreign443)?.use(443) == .other)
        let both = #"""
            {"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},
             "Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}},
                    "mac.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47902"}}}}}
            """#
        check("tailscale: Relay's existing 8443 entry is kept", picks(both, 8443, existing: true))
        let taken = #"""
            {"TCP":{"443":{"HTTPS":true},"8443":{"TCPForward":"127.0.0.1:22"}},
             "Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Text":"hello"}}}}}
            """#
        if case .failure(let f)? = port(taken) { check("tailscale: 443 and 8443 both taken is refused", f == .portsTaken) }
        else { check("tailscale: 443 and 8443 both taken is refused", false) }
        check("tailscale: a TCP forward on 443 counts as taken",
              serve(#"{"TCP":{"443":{"TCPForward":"127.0.0.1:47902"}}}"#)?.use(443) == .other)
        check("tailscale: a foreground serve on 443 counts as taken", picks(#"""
            {"Foreground":{"abc123":{"TCP":{"443":{"HTTPS":true}},
             "Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47902"}}}}}}}
            """#, 8443, existing: false))
        let sharedPort = #"""
            {"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{
             "/":{"Proxy":"http://127.0.0.1:47902"},"/grafana":{"Proxy":"http://127.0.0.1:3000"}}}}}
            """#
        check("tailscale: Relay next to other mounts counts as shared and isn't used", serve(sharedPort)?.use(443) == .shared
              && picks(sharedPort, 8443, existing: false) && serve(sharedPort)?.relayHandlerPorts == [443])
        check("tailscale: the last port used is preferred while free", picks("{}", 8443, existing: false, previous: 8443)
              && picks("{}", 443, existing: false, previous: 9000))
        check("tailscale: Funnel on a port is noticed", serve(#"""
            {"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47902"}}}},
             "AllowFunnel":{"mac.tail1234.ts.net:443":true}}
            """#)?.funnel == [443])
        check("tailscale: Relay's proxy target is recognised", Tailscale.isRelayTarget("http://127.0.0.1:47902")
              && Tailscale.isRelayTarget("http://localhost:47902/") && !Tailscale.isRelayTarget("https://127.0.0.1:47902")
              && !Tailscale.isRelayTarget("http://127.0.0.1:4790") && !Tailscale.isRelayTarget("http://10.0.0.2:47902")
              && !Tailscale.isRelayTarget("http://127.0.0.1:47902/api"))
        let notEnabled = "\nServe is not enabled on your tailnet.\nTo enable, visit:\n\n         https://login.tailscale.com/f/serve?node=nAbC123\n\n"
        check("tailscale: the enable-HTTPS link is found in CLI output",
              Tailscale.enableLink(in: notEnabled)?.absoluteString == "https://login.tailscale.com/f/serve?node=nAbC123"
              && Tailscale.enableLink(in: "error: no such host") == nil)
        check("tailscale: URLs omit the default port",
              Tailscale.url(name: "mac.tail1234.ts.net", port: 443)?.absoluteString == "https://mac.tail1234.ts.net"
              && Tailscale.url(name: "mac.tail1234.ts.net", port: 8443)?.absoluteString == "https://mac.tail1234.ts.net:8443")
        check("tailscale: failures explain themselves", Tailscale.Failure.httpsDisabled(nil).link == Tailscale.adminDNS
              && Tailscale.Failure.notInstalled.link != nil && !Tailscale.Failure.portsTaken.message.isEmpty)

        fakeTailscale(running: running, ours: ours, foreign443: foreign443, shared: sharedPort)
    }

    /// Drives enable() and disable() against a stand-in `tailscale` script that logs every call.
    private static func fakeTailscale(running: String, ours: String, foreign443: String, shared: String) {
        let dir = Paths.support.appendingPathComponent("fake-tailscale", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cli = dir.appendingPathComponent("tailscale").path
        let script = """
        #!/bin/bash
        D="$(cd "$(dirname "$0")" && pwd)"
        echo "$*" >> "$D/calls.log"
        case "$1 $2" in
          "status --json") cat "$D/status.json"; exit 0 ;;
          "serve status") cat "$D/serve.json" 2>/dev/null || echo "{}"; exit 0 ;;
        esac
        if [ "$1" = serve ] && [ "$2" = --bg ]; then
          [ -f "$D/enable.txt" ] && { cat "$D/enable.txt"; exit 0; }
          cp "$D/after.json" "$D/serve.json"; echo "Available within your tailnet"; exit 0
        fi
        if [ "$1" = serve ] && [ "${@: -1}" = off ]; then cp "$D/off.json" "$D/serve.json"; exit 0; fi
        echo "unexpected: $*" >&2; exit 1
        """
        func put(_ name: String, _ text: String) { try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func reset(serve: String, after: String = "{}", off: String = "{}", enableText: String? = nil) {
            for f in ["calls.log", "serve.json", "enable.txt"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
            put("status.json", running); put("serve.json", serve); put("after.json", after); put("off.json", off)
            if let enableText { put("enable.txt", enableText) }
        }
        func calls() -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        put("tailscale", script)
        chmod(cli, 0o755)

        reset(serve: "{}", after: ours)
        var steps: [Tailscale.Step] = []
        let fresh = Tailscale.enable(cli: cli, previousPort: nil) { steps.append($0) }
        check("tailscale: enable serves Relay on 443", (try? fresh.get())?.url.absoluteString == "https://adas-macbook-pro.tail1234.ts.net"
              && calls().contains("serve --bg --https=443 http://127.0.0.1:47902") && steps == Tailscale.Step.allCases)

        reset(serve: ours)
        let again = Tailscale.enable(cli: cli, previousPort: 443)
        check("tailscale: enable keeps an entry Relay already has", (try? again.get())?.port == 443
              && !calls().contains { $0.hasPrefix("serve --bg") })

        let ours8443 = foreign443.replacingOccurrences(of: #"}}}}}"#, with: #"}}},"mac.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47902"}}}}}"#)
            .replacingOccurrences(of: #""443":{"HTTPS":true}"#, with: #""443":{"HTTPS":true},"8443":{"HTTPS":true}"#)
        reset(serve: foreign443, after: ours8443)
        let fallback = Tailscale.enable(cli: cli, previousPort: nil)
        check("tailscale: enable leaves a foreign 443 alone and uses 8443",
              (try? fallback.get())?.url.absoluteString == "https://adas-macbook-pro.tail1234.ts.net:8443"
              && calls().contains("serve --bg --https=8443 http://127.0.0.1:47902")
              && !calls().contains { $0.contains("--https=443") })

        reset(serve: "{}", enableText: "\nServe is not enabled on your tailnet.\nTo enable, visit:\n\n         https://login.tailscale.com/f/serve?node=nTEST\n\n")
        if case .failure(.httpsDisabled(let link)) = Tailscale.enable(cli: cli, previousPort: nil) {
            check("tailscale: HTTPS certificates off links to the page that turns them on",
                  link?.absoluteString == "https://login.tailscale.com/f/serve?node=nTEST")
        } else {
            check("tailscale: HTTPS certificates off links to the page that turns them on", false)
        }

        // Relay's "/" next to another app's mount: Relay takes its handler off that port and moves.
        let grafanaOnly = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/grafana":{"Proxy":"http://127.0.0.1:3000"}}}}}"#
        let grafanaAnd8443 = #"""
            {"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},
             "Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/grafana":{"Proxy":"http://127.0.0.1:3000"}}},
                    "mac.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47902"}}}}}
            """#
        reset(serve: shared, after: grafanaAnd8443, off: grafanaOnly)
        let moved = Tailscale.enable(cli: cli, previousPort: 443)
        check("tailscale: enable moves off a port shared with other web apps",
              (try? moved.get())?.port == 8443 && calls().contains("serve --https=443 --set-path=/ off")
              && calls().contains("serve --bg --https=8443 http://127.0.0.1:47902"))

        reset(serve: ours8443, off: foreign443)
        check("tailscale: disable removes only Relay's entry", Tailscale.disable(cli: cli) == nil
              && calls().filter { $0.hasSuffix(" off") } == ["serve --https=8443 --set-path=/ off"])
        reset(serve: foreign443)
        check("tailscale: disable never touches a foreign entry", Tailscale.disable(cli: cli) == nil
              && !calls().contains { $0.hasSuffix(" off") })

        put("status.json", #"{"BackendState":"Stopped","Self":{"DNSName":"mac.tail1234.ts.net."}}"#)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("calls.log"))
        check("tailscale: enable stops at a stopped Tailscale", Tailscale.enable(cli: cli, previousPort: nil) == .failure(.notRunning("Stopped"))
              && calls() == ["status --json"])
        check("tailscale: enable without the CLI says to install it", Tailscale.enable(cli: nil, previousPort: nil) == .failure(.notInstalled))
    }

    // MARK: - Tailnet door (over real HTTP)

    private struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    /// Sends one request and keeps the main run loop turning meanwhile, since the server hops to it.
    private static func http(_ method: String, _ port: UInt16, _ target: String, headers: [String: String] = [:],
                             body: Data? = nil) -> Reply {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(target)")!)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        var reply: Reply?
        session.dataTask(with: req) { data, response, _ in
            let r = response as? HTTPURLResponse
            var h: [String: String] = [:]
            for (k, v) in r?.allHeaderFields ?? [:] { h[String(describing: k).lowercased()] = String(describing: v) }
            let result = Reply(status: r?.statusCode ?? -1, headers: h, body: data ?? Data())
            DispatchQueue.main.async { reply = result }
        }.resume()
        let deadline = Date().addingTimeInterval(15)
        while reply == nil && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return reply ?? Reply(status: -1, headers: [:], body: Data())
    }

    /// The headers a phone sends for a signed request (as the page builds them).
    private static func signedHeaders(_ method: String, _ target: String, body: Data = Data(), key: P256.Signing.PrivateKey,
                                      device: String, login: String? = "ada@example.com", ts: Date = Date()) -> [String: String] {
        let r = signedRequest(method, target, body: String(decoding: body, as: UTF8.self), ts: ts, key: key, device: device, login: login)
        var h = ["X-Relay-Device": r.headers["x-relay-device"]!, "X-Relay-Ts": r.headers["x-relay-ts"]!,
                 "X-Relay-Sig": r.headers["x-relay-sig"]!]
        if let login { h["Tailscale-User-Login"] = login }
        if !body.isEmpty { h["Content-Type"] = "application/json" }
        return h
    }

    private static func tailnetDoor() {
        let store = Store()
        let devices = DeviceStore(file: Paths.support.appendingPathComponent("devices-door.json"))
        let push = WebPush(watchNetwork: false)
        push.keyFileOverride = Paths.support.appendingPathComponent("vapid-door.json")
        push.devicesOverride = devices
        var pushed: [URLRequest] = []
        push.transport = { req, done in pushed.append(req); DispatchQueue.main.async { done(201, nil) } }
        let api = RemoteAPI(store: store, devices: devices, push: push)
        api.notify = { _ in }
        let door = TailnetServer(api: api, devices: devices)
        var allow = true
        var asked: [(String, String, String)] = []
        door.confirmPairing = { name, login, fingerprint, done in
            asked.append((name, login, fingerprint))
            DispatchQueue.main.async { done(allow) }
            return {}
        }
        door.notify = { _ in }
        door.acceptHost = { _ in true }   // URLSession sends Host: 127.0.0.1; the real rule is checked below
        do { try door.start(port: 0) } catch {
            check("door: listens on an ephemeral loopback port", false); return
        }
        defer { door.stop() }
        let port = door.port
        check("door: listens on an ephemeral loopback port", port > 0)

        let second = TailnetServer(api: api, devices: devices)
        check("door: a busy port is an error, never a fallback", (try? second.start(port: port)) == nil && !second.isRunning)

        // Host: only the *.ts.net name Serve passes on (a page rebinding its own domain can't send it).
        check("door: only *.ts.net Host headers are answered", TailnetServer.isTailnetHost("mac.tail1234.ts.net")
              && TailnetServer.isTailnetHost("MAC.tail1234.TS.NET:8443") && !TailnetServer.isTailnetHost("127.0.0.1:47902")
              && !TailnetServer.isTailnetHost("evil.example") && !TailnetServer.isTailnetHost("ts.net.evil.example")
              && !TailnetServer.isTailnetHost(nil) && !TailnetServer.isTailnetHost("a.ts.net\nx"))
        let strict = TailnetServer(api: api, devices: devices)
        func direct(_ host: String) -> Int? {
            var status: Int?
            let ex = HTTPExchange(queue: DispatchQueue(label: "relay.selftest.host")) { r in DispatchQueue.main.async { status = r.status } }
            strict.handle(HTTPRequest(method: "GET", path: "/", query: [:], headers: ["host": host], body: Data(), remoteHost: "127.0.0.1",
                                      target: "/"), ex)
            spin { status != nil }
            return status
        }
        check("door: a request for another Host is refused", direct("rebound.example:47902") == 421 && direct("mac.tail1234.ts.net") == 200)
        func directPair(_ login: String, code: String) -> (Int?, [String: Any]) {
            var reply: HTTPResponse?
            let ex = HTTPExchange(queue: DispatchQueue(label: "relay.selftest.pair")) { r in DispatchQueue.main.async { reply = r } }
            let body = try! JSONSerialization.data(withJSONObject: ["code": code, "deviceName": "x",
                "publicKey": P256.Signing.PrivateKey().publicKey.x963Representation.base64URLEncodedString()])
            strict.handle(HTTPRequest(method: "POST", path: "/api/pair", query: [:],
                                      headers: ["host": "mac.tail1234.ts.net", "tailscale-user-login": login], body: body,
                                      remoteHost: "127.0.0.1", target: "/api/pair"), ex)
            spin { reply != nil }
            return (reply?.status, (reply?.body).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:])
        }
        check("door: a login with control characters can't pair", directPair("ada@example.com\n\nAllow it", code: "x").0 == 403)
        for _ in 0..<21 { devices.recordFailure(login: "mallory@example.com") }
        let busy = directPair("mallory@example.com", code: devices.newPairingCode())
        check("door: pairing during a cool-down says to wait", busy.0 == 429 && (busy.1["error"] as? String)?.contains("Wait") == true)
        devices.cancelPairingCode()

        let page = http("GET", port, "/")
        check("door: the page is served without a device", page.status == 200
              && page.headers["content-security-policy"]?.contains("frame-ancestors 'none'") == true
              && page.headers["x-frame-options"] == "DENY")
        let csp = TailnetServer.pageCSP(for: "<p>x</p><script>alert(1)</script><script>go()</script>")
        let hash = Data(SHA256.hash(data: Data("alert(1)".utf8))).base64EncodedString()
        check("door: the page's scripts are allowed by hash, never inline at large",
              csp.contains("'sha256-\(hash)'") && csp.components(separatedBy: "'sha256-").count == 3
              && !csp.contains("script-src 'self' 'unsafe-inline'") && !csp.contains("'unsafe-eval'"))
        check("door: API responses allow no scripts", http("GET", port, "/api/state").headers["content-security-policy"]
              == TailnetServer.securityHeaders["Content-Security-Policy"])
        check("door: the API needs a signature", http("GET", port, "/api/state").status == 401
              && http("POST", port, "/api/answer", body: Data("{}".utf8)).status == 401)
        check("door: Funnel traffic is refused", http("GET", port, "/", headers: ["Tailscale-Funnel-Request": "?1"]).status == 403)

        let key = P256.Signing.PrivateKey()
        let pub = key.publicKey.x963Representation.base64URLEncodedString()
        func pairBody(_ code: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["code": code, "publicKey": pub, "deviceName": "Test iPhone"])
        }
        let code = devices.newPairingCode()
        check("door: pairing with a wrong code is refused",
              http("POST", port, "/api/pair", headers: ["Tailscale-User-Login": "ada@example.com"], body: pairBody("nope")).status == 401)
        let noLogin = http("POST", port, "/api/pair", body: pairBody(code))
        check("door: pairing that didn't come through Tailscale Serve is refused",
              noLogin.status == 403 && (noLogin.json["error"] as? String)?.contains("Tailscale") == true && asked.isEmpty)
        let paired = http("POST", port, "/api/pair", headers: ["Tailscale-User-Login": "ada@example.com"], body: pairBody(code))
        let deviceId = paired.json["deviceId"] as? String ?? ""
        check("door: pairing asks on the Mac and returns the device", paired.status == 200 && devices.device(deviceId) != nil
              && asked.count == 1 && asked.first?.1 == "ada@example.com"
              && asked.first?.2 == TailnetServer.fingerprint(pub) && asked.first?.2.count == 9)
        check("door: a pairing code works only once",
              http("POST", port, "/api/pair", headers: ["Tailscale-User-Login": "ada@example.com"], body: pairBody(code)).status == 401)

        let state = http("GET", port, "/api/state", headers: signedHeaders("GET", "/api/state", key: key, device: deviceId))
        check("door: a signed request gets the full API", state.status == 200
              && state.json["caps"] as? [String] == ["read", "answer", "control"])
        check("door: a request updates last seen", devices.device(deviceId)?.lastSeen != nil)
        let replayed = signedHeaders("GET", "/api/session?id=nope", key: key, device: deviceId)
        let first = http("GET", port, "/api/session?id=nope", headers: replayed)
        check("door: the signature covers the query", first.status == 404 && first.json["ok"] as? Bool == false)
        check("door: a replayed request is refused", http("GET", port, "/api/session?id=nope", headers: replayed).status == 401)
        check("door: another Tailscale login is refused", http("GET", port, "/api/state",
              headers: signedHeaders("GET", "/api/state", key: key, device: deviceId, login: "eve@example.com")).status == 401)
        var funnel = signedHeaders("GET", "/api/state", key: key, device: deviceId)
        funnel["Tailscale-Funnel-Request"] = "?1"
        check("door: Funnel traffic is refused even when signed", http("GET", port, "/api/state", headers: funnel).status == 403)

        allow = false
        let denyCode = devices.newPairingCode()
        let other = P256.Signing.PrivateKey().publicKey.x963Representation.base64URLEncodedString()
        let denied = http("POST", port, "/api/pair", headers: ["Tailscale-User-Login": "ada@example.com"],
                          body: try! JSONSerialization.data(withJSONObject: ["code": denyCode, "publicKey": other, "deviceName": "x"]))
        check("door: pairing denied on the Mac stores nothing", denied.status == 403 && devices.active.count == 1)

        // The device's own settings.
        func post(_ path: String, _ object: [String: Any]) -> Reply {
            let body = try! JSONSerialization.data(withJSONObject: object)
            return http("POST", port, path, headers: signedHeaders("POST", path, body: body, key: key, device: deviceId), body: body)
        }
        let browser = P256.KeyAgreement.PrivateKey()
        let keys = ["p256dh": browser.publicKey.x963Representation.base64URLEncodedString(),
                    "auth": Secure.randomBytes(16).base64URLEncodedString()]
        check("door: a push subscription outside the allowlist is refused",
              post("/api/push/subscribe", ["endpoint": "https://evil.test/push", "keys": keys]).status == 400
              && devices.device(deviceId)?.pushSubscription == nil)
        check("door: a push subscription with bad keys is refused",
              post("/api/push/subscribe", ["endpoint": "https://web.push.apple.com/abc", "keys": ["p256dh": "AAAA", "auth": "BBBB"]]).status == 400)
        check("door: a push subscription is stored",
              post("/api/push/subscribe", ["endpoint": "https://web.push.apple.com/abc", "keys": keys]).status == 200
              && devices.device(deviceId)?.pushSubscription?.endpoint == "https://web.push.apple.com/abc")
        let prefs = post("/api/push/prefs", ["finished": false, "hideContent": true])
        let stored = devices.device(deviceId)?.pushPrefs
        check("door: push preferences are stored", prefs.json["ok"] as? Bool == true && stored?.finished == false
              && stored?.hideContent == true && stored?.blocked == true && stored?.fire == true)
        let test = post("/api/push/test", [:])
        let testBody = pushed.last?.httpBody.flatMap { try? WebPush.decrypt($0, receiver: browser, auth: Data(base64URL: keys["auth"]!)!) }
        check("door: a test push reaches the push service, hidden when asked", test.json["ok"] as? Bool == true && pushed.count == 1
              && pushed.first?.url?.host == "web.push.apple.com"
              && testBody.map { String(decoding: $0, as: UTF8.self).contains(PushDispatcher.hiddenBody) } == true)
        let described = http("GET", port, "/api/state", headers: signedHeaders("GET", "/api/state", key: key, device: deviceId))
        let me = described.json["device"] as? [String: Any]
        check("door: state describes the calling device", me?["id"] as? String == deviceId && me?["subscribed"] as? Bool == true
              && (me?["vapidKey"] as? String).flatMap { Data(base64URL: $0) }?.count == 65
              && (me?["prefs"] as? [String: Bool])?["hideContent"] == true)
        check("door: notifications can be turned off", post("/api/push/unsubscribe", [:]).status == 200
              && devices.device(deviceId)?.pushSubscription == nil)
        check("door: a device can unpair itself", post("/api/device/forget", [:]).status == 200 && devices.device(deviceId) == nil)
        check("door: an unpaired device is refused",
              http("GET", port, "/api/state", headers: signedHeaders("GET", "/api/state", key: key, device: deviceId)).status == 401)

        // Starting and stopping agents (the launcher is a stand-in; nothing runs).
        let pair2 = devices.newPairingCode()
        let key2 = P256.Signing.PrivateKey()
        allow = true
        let second2 = http("POST", port, "/api/pair", headers: ["Tailscale-User-Login": "ada@example.com"],
                           body: try! JSONSerialization.data(withJSONObject: ["code": pair2, "deviceName": "iPad",
                               "publicKey": key2.publicKey.x963Representation.base64URLEncodedString()]))
        let dev2 = second2.json["deviceId"] as? String ?? ""
        func signedPost(_ path: String, _ object: [String: Any]) -> Reply {
            let body = try! JSONSerialization.data(withJSONObject: object)
            return http("POST", port, path, headers: signedHeaders("POST", path, body: body, key: key2, device: dev2), body: body)
        }
        func signedGet(_ target: String) -> Reply {
            http("GET", port, target, headers: signedHeaders("GET", target, key: key2, device: dev2))
        }
        let project = Paths.support.appendingPathComponent("projects/acme api", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        store.sessions["live"] = AgentSession(id: "live", workspaceId: "default", cwd: project.path, pid: nil,
                                              terminal: TerminalLocation(), status: .working, handle: "claude-9")
        var launched: [(String, String, String, String)] = []
        api.launch = { ws, folder, prompt, mode in launched.append((ws.id, folder, prompt, mode)); return .success("0123456789abcdef") }
        let folders = signedGet("/api/folders")
        let firstWs = (folders.json["workspaces"] as? [[String: Any]])?.first
        check("control: folders lists where agents run", second2.status == 200 && folders.json["ok"] as? Bool == true
              && (firstWs?["folders"] as? [[String: Any]])?.first?["path"] as? String == project.path
              && folders.json["modes"] as? [String] == ["default", "plan", "acceptEdits"])
        let unknown = signedPost("/api/start", ["workspaceId": "default", "folder": "/tmp", "prompt": "hi", "mode": "plan"])
        check("control: start refuses a folder Relay doesn't know", unknown.json["ok"] as? Bool == false && launched.isEmpty)
        for mode in ["bypassPermissions", "dangerously-skip-permissions", "auto", ""] {
            let r = signedPost("/api/start", ["workspaceId": "default", "folder": project.path, "prompt": "hi", "mode": mode])
            check("control: start refuses mode \"\(mode)\"", r.json["ok"] as? Bool == false && launched.isEmpty)
        }
        let started = signedPost("/api/start", ["workspaceId": "default", "folder": project.path, "prompt": "'; rm -rf ~", "mode": "acceptEdits"])
        check("control: start launches in a known folder", started.json["launchId"] as? String == "0123456789abcdef"
              && launched.count == 1 && launched.first?.1 == project.path && launched.first?.2 == "'; rm -rf ~"
              && launched.first?.3 == "acceptEdits")
        let withLaunch = signedGet("/api/state")
        let rows = withLaunch.json["launches"] as? [[String: Any]] ?? []
        let liveRow = (withLaunch.json["sessions"] as? [[String: Any]])?.first { $0["id"] as? String == "live" }
        check("control: state shows the Starting… row", rows.first?["id"] as? String == "0123456789abcdef"
              && rows.first?["folder"] as? String == "acme api" && rows.first?["sessionId"] as? String == "")
        check("control: state says which agents can be killed or have a terminal", liveRow?["canKill"] as? Bool == false
              && liveRow?["tmux"] as? Bool == false)
        store.claimLaunch("0123456789abcdef", sessionId: "live")
        check("control: the agent's hook claims its row", store.launches.first?.sessionId == "live")
        check("control: an agent Relay can't stop isn't killed", signedPost("/api/kill", ["sessionId": "live"]).json["ok"] as? Bool == false
              && store.sessions["live"] != nil)
        check("control: only tmux agents have a terminal view", signedGet("/api/terminal?id=live").json["ok"] as? Bool == false)
        check("control: a launch row can be dismissed", signedPost("/api/launch/dismiss", ["id": "0123456789abcdef"]).json["ok"] as? Bool == true
              && store.launches.isEmpty)

        // The LAN door has no device, so device routes don't exist there.
        var lanStatus: Int?
        let exchange = HTTPExchange(queue: DispatchQueue(label: "relay.selftest")) { r in DispatchQueue.main.async { lanStatus = r.status } }
        api.handle(HTTPRequest(method: "POST", path: "/api/push/test", query: [:], headers: [:], body: Data(), remoteHost: nil,
                               target: "/api/push/test"), exchange, caps: [.read, .answer])
        spin { lanStatus != nil }
        check("api: device routes don't exist without a device", lanStatus == 404 && pushed.count == 1)
        lanStatus = nil
        let lanStart = HTTPExchange(queue: DispatchQueue(label: "relay.selftest")) { r in DispatchQueue.main.async { lanStatus = r.status } }
        let startBody = try! JSONSerialization.data(withJSONObject: ["workspaceId": "default", "folder": project.path, "mode": "plan"])
        api.handle(HTTPRequest(method: "POST", path: "/api/start", query: [:], headers: [:], body: startBody, remoteHost: nil,
                               target: "/api/start"), lanStart, caps: [.read, .answer])
        spin { lanStatus != nil }
        check("api: the LAN door can't start agents", lanStatus == 404 && launched.count == 1)
    }

    // MARK: - Remote start

    private static func remoteStart() {
        let ws = Workspace(id: "w1", name: "Work", configDir: nil, colorHex: "#E8A85A")
        let known = { (_: String) in ["/Users/ada/code/api"] }
        func problem(_ folder: String = "/Users/ada/code/api", mode: String = "default", prompt: String = "hi",
                     workspace: String = "w1") -> RemoteAPI.StartProblem? {
            RemoteAPI.startProblem(workspaceId: workspace, folder: folder, prompt: prompt, mode: mode, workspaces: [ws], known: known)
        }
        check("start: a known folder and mode are accepted", problem() == nil && problem(mode: "plan") == nil
              && problem(mode: "acceptEdits") == nil)
        check("start: an unknown folder is refused", problem("/Users/ada/code") == .unknownFolder
              && problem("/Users/ada/code/api/") == .unknownFolder && problem("/Users/ada/code/api/../../..") == .unknownFolder)
        check("start: bypassing permissions is refused", problem(mode: "bypassPermissions") == .badMode
              && problem(mode: "--dangerously-skip-permissions") == .badMode && problem(mode: "dontAsk") == .badMode)
        check("start: an unknown workspace is refused", problem(workspace: "w2") == .unknownWorkspace)
        check("start: a prompt with a NUL byte is refused", problem(prompt: "a\u{0}b") == .badPrompt
              && problem(prompt: String(repeating: "x", count: 20_001)) == .badPrompt)

        // tmux gets the command as separate arguments; nothing tmux expands comes from outside.
        let args = Launcher.tmuxArguments(session: "relay-0123456789abcdef", script: "exit 0")
        check("start: tmux runs /bin/sh -c directly with no start directory",
              args.prefix(8) == ["new-session", "-d", "-s", "relay-0123456789abcdef", "-x", "120", "-y", "40"]
              && Array(args.suffix(3)) == ["/bin/sh", "-c", "exit 0"] && !args.dropLast(3).contains("-c"))

        // Run the real script with /bin/sh and a stand-in claude that prints what it got.
        let dir = Paths.support.appendingPathComponent("launch", isDirectory: true)
        let folder = dir.appendingPathComponent("it's #(touch CANARY) $HOME `id`", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stub = dir.appendingPathComponent("claude-stub")
        try? "#!/bin/sh\nprintf 'cwd=%s\\n' \"$PWD\"\nprintf 'launch=%s\\n' \"$RELAY_LAUNCH_ID\"\nprintf 'config=%s\\n' \"${CLAUDE_CONFIG_DIR-unset}\"\nfor a in \"$@\"; do printf 'arg=[%s]\\n' \"$a\"; done\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        func run(_ prompt: String, mode: String = "default", workspace: Workspace = ws) -> [String] {
            let script = Launcher.detachedScript(workspace: workspace, folder: folder.path, prompt: prompt, mode: mode,
                                                 launchId: "0123456789abcdef", claude: Shell.quote(stub.path))
            let tmuxArgs = Launcher.tmuxArguments(session: "relay-0123456789abcdef", script: script)
            guard !tmuxArgs.contains(where: { $0.hasSuffix(";") }) else { return ["tmux would split this command"] }
            return Proc.run("/bin/sh", ["-c", script], timeout: 10).stdout.split(separator: "\n").map(String.init)
        }
        let hostile = "'; rm -rf ~; echo '$(touch CANARY) `touch CANARY` \\'\nsecond line"
        let out = run(hostile, mode: "plan")
        check("start: a hostile prompt arrives as one argument after --",
              out == ["cwd=" + folder.path, "launch=0123456789abcdef", "config=unset", "arg=[--permission-mode]", "arg=[plan]",
                      "arg=[--]", "arg=['; rm -rf ~; echo '$(touch CANARY) `touch CANARY` \\'", "second line]"])
        check("start: nothing in the prompt or folder ran", !FileManager.default.fileExists(atPath: dir.appendingPathComponent("CANARY").path)
              && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("CANARY").path))
        check("start: a prompt can't pass itself off as a flag",
              run("--dangerously-skip-permissions").suffix(2) == ["arg=[--]", "arg=[ --dangerously-skip-permissions ]"]
              && run("--settings=/tmp/x.json please").suffix(1) == ["arg=[ --settings=/tmp/x.json please]"])
        check("start: a one-word prompt isn't taken for a claude command", run("purge").suffix(2) == ["arg=[--]", "arg=[purge ]"])
        check("start: Default is passed explicitly, so settings can't pick another mode",
              run("hi there").prefix(5).suffix(2) == ["arg=[--permission-mode]", "arg=[default]"])
        check("start: no prompt, only the mode", run("  \n ").filter { $0.hasPrefix("arg=") } == ["arg=[--permission-mode]", "arg=[default]"])
        let account = Workspace(id: "w2", name: "Acme", configDir: "/Users/ada/.claude-workspaces/it's", colorHex: "#5B8DEF")
        check("start: the workspace's account is used", run("hi there", workspace: account).contains("config=/Users/ada/.claude-workspaces/it's"))
    }

    // MARK: - Push timing

    private static func pushDispatch() {
        let pd = PushDispatcher()
        var out: [(WebPush.Message, String)] = []
        var later: [(TimeInterval, () -> Void)] = []
        var away = true
        var hot = true
        var clock = Date(timeIntervalSince1970: 1_759_660_000)
        var waiting: [String: InboxItem] = [:]
        let sub = PushSubscription(endpoint: "https://web.push.apple.com/x", p256dh: "", auth: "")
        func device(_ id: String, _ edit: (inout PushPrefs) -> Void = { _ in }, subscribed: Bool = true) -> Device {
            var d = Device(id: id, name: id, publicKey: "", ownerLogin: "ada@example.com", pairedAt: clock)
            edit(&d.pushPrefs)
            d.pushSubscription = subscribed ? sub : nil
            return d
        }
        let everything = device("all")
        let quiet = device("quiet") { $0.blocked = false; $0.hideContent = true }
        let noFire = device("nofire") { $0.fire = false }
        let off = device("off", subscribed: false)
        var session = AgentSession(id: "s1", workspaceId: "w1", cwd: "/tmp/acme-payroll", pid: nil, terminal: TerminalLocation(),
                                   status: .working, handle: "claude-3")
        session.title = "Fix the payroll rounding bug"
        pd.send = { out.append(($0, $1)) }
        pd.devices = { [everything, quiet, noFire, off] }
        pd.isAway = { away }
        pd.schedule = { later.append(($0, $1)) }
        pd.currentItem = { waiting[$0] }
        pd.currentSession = { $0 == "s1" ? session : nil }
        pd.isHot = { _ in hot }
        pd.now = { clock }
        func payload(_ m: WebPush.Message?, hidden: Bool = false) -> [String: String] {
            (m.flatMap { try? JSONSerialization.jsonObject(with: hidden ? $0.hiddenPayload : $0.payload) as? [String: String] }) ?? [:]
        }

        var question = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .question, title: "Rounding",
                                 body: String(repeating: "Should totals round half-even or half-up for every currency? ", count: 4))
        question.questions = [AgentQuestion(question: question.body, header: "Rounding", options: [], multiSelect: false)]
        waiting[question.id] = question
        pd.itemArrived(question)
        check("timing: away from the Mac, a question goes out right away to devices that want it",
              out.map(\.1) == ["all", "nofire"] && later.isEmpty)
        let q = payload(out.first?.0)
        check("timing: payload is {title, body ≤ 120, itemId, sessionId, kind}", q["title"] == "@claude-3 asks"
              && (q["body"]?.count ?? 0) == 120 && q["body"]?.hasSuffix("…") == true && q["itemId"] == question.id
              && q["sessionId"] == "s1" && q["kind"] == "question" && out.first?.0.urgency == .high)
        check("timing: the topic is 32 base64url characters, one per item",
              out.first?.0.topic.count == 32 && out.first?.0.topic == PushDispatcher.topic(question.id)
              && PushDispatcher.topic(question.id) != PushDispatcher.topic("other")
              && out.first?.0.topic.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } == true)

        out = []
        let finished = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .finished, title: "Done", body: "Rounded half-even.")
        waiting[finished.id] = finished
        pd.itemArrived(finished)
        let hiddenOne = out.first { $0.1 == "quiet" }?.0
        check("timing: finished turns go to devices that want them, normal urgency",
              out.map(\.1) == ["all", "quiet", "nofire"] && out.first?.0.urgency == .normal
              && payload(out.first?.0)["title"] == "Fix the payroll rounding bug")
        check("timing: hide content sends only \"An agent needs you\"", payload(hiddenOne)["body"] == PushDispatcher.hiddenBody
              && payload(hiddenOne)["title"] == PushDispatcher.hiddenTitle
              && !(hiddenOne.map { String(decoding: $0.payload, as: UTF8.self).contains("payroll") } ?? true))
        check("timing: every push carries a hidden version for 413", payload(out.first?.0, hidden: true)["body"] == PushDispatcher.hiddenBody)

        out = []
        away = false
        let permission = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .permission, title: "Run the tests", body: "$ npm test")
        waiting[permission.id] = permission
        pd.itemArrived(permission)
        check("timing: at the Mac, a push waits 45 s", out.isEmpty && later.count == 1 && later.first?.0 == 45)
        later.removeFirst().1()
        check("timing: still unanswered after 45 s, it goes out", out.count == 2
              && payload(out.first?.0)["body"] == "Run the tests: $ npm test")
        out = []
        let answered = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .permission, title: "Edit", body: "x")
        waiting[answered.id] = answered
        pd.itemArrived(answered)
        waiting[answered.id] = nil
        later.removeFirst().1()
        check("timing: answered at the desk, nothing goes out", out.isEmpty)

        var elicit = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .waiting, title: Store.needsInputTitle, body: "Pick a file")
        check("timing: an MCP elicitation counts as blocked", PushDispatcher.kind(of: elicit) == .blocked)
        elicit.title = "Waiting for you"
        check("timing: an idle agent counts as finished", PushDispatcher.kind(of: elicit) == .finished)

        // On fire: at most once per agent per 10 minutes, and only while still hot.
        away = true
        out = []
        pd.agentOnFire("s1", cpu: "312% CPU")
        pd.agentOnFire("s1", cpu: "330% CPU")
        check("timing: on fire goes out once to devices that want it", out.map(\.1) == ["all", "quiet"]
              && payload(out.first?.0)["kind"] == "fire" && payload(out.first?.0)["body"]?.hasPrefix("312% CPU") == true)
        clock = clock.addingTimeInterval(9 * 60)
        pd.agentOnFire("s1", cpu: "300% CPU")
        check("timing: not again within 10 minutes", out.count == 2)
        clock = clock.addingTimeInterval(2 * 60)
        hot = false
        away = false
        pd.agentOnFire("s1", cpu: "250% CPU")
        later.removeFirst().1()
        check("timing: an agent that cooled down in the 45 s isn't pushed", out.count == 2 && later.isEmpty)
    }

    // MARK: - Connection limits

    /// A TCP connection that never sends anything.
    private static func idleConnection(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if ok != 0 { close(fd); return -1 }
        return fd
    }

    private static func connectionLimits() {
        let server = HTTPServer(label: "selftest.cap", localOnly: true) { _, ex in ex.respond(.text("ok")) }
        server.maxConnections = 3
        server.requestTimeout = 1.5
        do { try server.start(exactPort: 0) } catch { check("limits: a capped server starts", false); return }
        defer { server.stop() }
        let idle = (0..<3).map { _ in idleConnection(server.port) }
        spin { server.connectionCount == 3 }
        check("limits: idle connections count against the cap", idle.allSatisfy { $0 >= 0 } && server.connectionCount == 3)
        check("limits: past the cap, connections are refused", http("GET", server.port, "/").status == -1)
        let deadline = Date().addingTimeInterval(2.5)
        spin { Date() > deadline }
        check("limits: connections that send nothing are dropped after the deadline", server.connectionCount == 0
              && http("GET", server.port, "/").status == 200)
        idle.forEach { close($0) }
        check("limits: the tailnet door caps connections and waits 10 s for a request",
              TailnetServer.maxConnections == 32 && TailnetServer.requestTimeout == 10)
    }

    // MARK: - Web Push

    /// Turns the main run loop until `done` is true (or 10 s pass).
    private static func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private static func webPush() {
        // RFC 8291 §5 and Appendix A.
        let b = { (s: String) in Data(base64URL: s) ?? Data() }
        let uaPrivate = try? P256.KeyAgreement.PrivateKey(rawRepresentation: b("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"))
        let asPrivate = try? P256.KeyAgreement.PrivateKey(rawRepresentation: b("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
        let auth = b("BTBZMqHH6r4Tts7J_aSIgg")
        let salt = b("DGv6ra1nlYgDCS1FRnbzlw")
        let plaintext = Data("When I grow up, I want to be a watermelon".utf8)
        let published = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
        if let ua = uaPrivate, let sender = asPrivate {
            let uaPublic = ua.publicKey.x963Representation
            check("push: RFC 8291 keys match the example",
                  uaPublic.base64URLEncodedString() == "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
                  && sender.publicKey.x963Representation.base64URLEncodedString() == "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8")
            if let shared = try? sender.sharedSecretFromKeyAgreement(with: ua.publicKey) {
                let keys = WebPush.deriveKeys(shared: shared, auth: auth, uaPublic: uaPublic,
                                              asPublic: sender.publicKey.x963Representation, salt: salt)
                check("push: RFC 8291 intermediate values match (ECDH, IKM, CEK, nonce)",
                      shared.withUnsafeBytes { Data($0) }.base64URLEncodedString() == "kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs"
                      && keys.ikm.base64URLEncodedString() == "S4lYMb_L0FxCeq0WhDx813KgSYqU26kOyzWUdsXYyrg"
                      && keys.cek.base64URLEncodedString() == "oIhVW04MRdy2XN9CiKLxTg"
                      && keys.nonce.base64URLEncodedString() == "4h_95klXJ5E_qnoN")
            }
            let body = try? WebPush.encrypt(plaintext, p256dh: uaPublic, auth: auth, salt: salt, sender: sender)
            check("push: RFC 8291 example encrypts to the published body", body?.base64URLEncodedString() == published)
            check("push: RFC 8291 published body decrypts", (try? WebPush.decrypt(b(published), receiver: ua, auth: auth)) == plaintext)
        } else {
            check("push: RFC 8291 keys load", false)
        }

        let phone = P256.KeyAgreement.PrivateKey()
        let phoneAuth = Secure.randomBytes(16)
        let message = Data(#"{"title":"@claude-3 asks","body":"Run the tests?"}"#.utf8)
        let sealed = try? WebPush.encrypt(message, p256dh: phone.publicKey.x963Representation, auth: phoneAuth)
        check("push: a message round-trips with fresh keys", sealed.flatMap { try? WebPush.decrypt($0, receiver: phone, auth: phoneAuth) } == message)
        check("push: two encryptions of one message differ (fresh salt and key)",
              (try? WebPush.encrypt(message, p256dh: phone.publicKey.x963Representation, auth: phoneAuth)) != sealed)
        check("push: a payload larger than one record is refused",
              (try? WebPush.encrypt(Data(count: 4080), p256dh: phone.publicKey.x963Representation, auth: phoneAuth)) == nil)
        check("push: a tampered body doesn't decrypt", sealed.map { body -> Bool in
            var t = body; t[t.count - 20] ^= 1
            return (try? WebPush.decrypt(t, receiver: phone, auth: phoneAuth)) == nil
        } ?? false)

        // VAPID.
        let push = WebPush(watchNetwork: false)
        push.keyFileOverride = Paths.support.appendingPathComponent("vapid-test.json")
        let vapid = push.vapidKey()
        let mode = ((try? FileManager.default.attributesOfItem(atPath: push.keyFile.path))?[.posixPermissions] as? NSNumber)?.intValue
        check("push: the VAPID key is saved 0600 and reloads", mode == 0o600
              && WebPush.loadKey(push.keyFile)?.rawRepresentation == vapid.rawRepresentation)
        let now = Date(timeIntervalSince1970: 1_759_660_000)
        let jwt = WebPush.jwt(audience: "https://web.push.apple.com", key: vapid, now: now)
        let parts = jwt.split(separator: ".").map(String.init)
        func json(_ s: String) -> [String: Any] { (Data(base64URL: s)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
        if parts.count == 3 {
            let header = json(parts[0]), claims = json(parts[1])
            check("push: the JWT header is ES256", header["alg"] as? String == "ES256" && header["typ"] as? String == "JWT")
            check("push: the JWT claims name the push service, 12 h and an https contact",
                  claims["aud"] as? String == "https://web.push.apple.com"
                  && claims["exp"] as? Int == Int(now.timeIntervalSince1970) + 12 * 3600
                  && (claims["sub"] as? String)?.hasPrefix("https://") == true
                  && (claims["sub"] as? String)?.contains("localhost") == false)
            let sig = Data(base64URL: parts[2]).flatMap { try? P256.Signing.ECDSASignature(rawRepresentation: $0) }
            check("push: the JWT signature verifies", sig.map { vapid.publicKey.isValidSignature($0, for: Data((parts[0] + "." + parts[1]).utf8)) } ?? false)
        } else {
            check("push: the JWT has three parts", false)
        }

        // Endpoint allowlist.
        let good = ["https://web.push.apple.com/QGuQyavXutnMH9IOQkd4R", "https://push.apple.com/x", "https://WEB.Push.Apple.com/x",
                    "https://fcm.googleapis.com/fcm/send/abc:def", "https://updates.push.services.mozilla.com/wpush/v2/gAAA",
                    "https://web.push.apple.com:443/x"]
        let bad = ["https://push.apple.com.evil.test/x", "http://web.push.apple.com/x", "https://evilpush.apple.com/x",
                   "https://web.push.apple.com:8443/x", "https://user:pw@web.push.apple.com/x", "https://fcm.googleapis.com.evil.test/x",
                   "https://127.0.0.1/x", "https://[::1]/x", "ftp://web.push.apple.com/x", "https://web.push.apple.com./x",
                   "https://evil.test#@web.push.apple.com/", "https://evil.test/?.push.apple.com", "web.push.apple.com/x", "",
                   "https://127.0.0.1%00.push.apple.com/x", "https://evil.com%2F.push.apple.com/x", "https://web.push.apple.com%2E/x",
                   "https://web.push.apple.com\\@evil.test/x", "https://.push.apple.com/x", "https://a..push.apple.com/x"]
        check("push: known push services are allowed", good.allSatisfy { WebPush.allowedEndpoint($0) != nil })
        for url in bad { check("push: \(url.isEmpty ? "an empty endpoint" : url) is refused", WebPush.allowedEndpoint(url) == nil) }

        // Delivery rules, through a stand-in transport.
        let devices = DeviceStore(file: Paths.support.appendingPathComponent("devices-push.json"))
        let key = P256.Signing.PrivateKey()
        guard let device = devices.addDevice(name: "Push test", publicKey: key.publicKey.x963Representation.base64URLEncodedString(),
                                             login: "ada@example.com") else { check("push: test device pairs", false); return }
        let subscription = PushSubscription(endpoint: "https://web.push.apple.com/QGuQyavXutnMH9IOQkd4R",
                                            p256dh: phone.publicKey.x963Representation.base64URLEncodedString(),
                                            auth: phoneAuth.base64URLEncodedString())
        devices.setSubscription(subscription, for: device.id)
        push.devicesOverride = devices
        var answers: [Int?] = []
        var sent: [URLRequest] = []
        var delays: [TimeInterval] = []
        push.transport = { req, done in
            sent.append(req)
            let status = answers.isEmpty ? 201 : answers.removeFirst()
            DispatchQueue.main.async { done(status, status == nil ? URLError(.notConnectedToInternet) : nil) }
        }
        push.schedule = { delay, work in delays.append(delay); DispatchQueue.main.async(execute: work) }
        let msg = WebPush.Message(payload: Data(#"{"body":"secret"}"#.utf8), hiddenPayload: Data(#"{"body":"An agent needs you"}"#.utf8),
                                  urgency: .high, topic: "AbCdEfGhIjKlMnOpQrStUvWxYz012345")
        func deliver(_ statuses: [Int?], _ m: WebPush.Message = msg) -> WebPush.Outcome? {
            answers = statuses; sent = []; delays = []
            var outcome: WebPush.Outcome?
            push.send(m, to: device.id) { outcome = $0 }
            spin { outcome != nil }
            return outcome
        }
        func opened(_ r: URLRequest?) -> String {
            r?.httpBody.flatMap { try? WebPush.decrypt($0, receiver: phone, auth: phoneAuth) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }

        check("push: 201 is delivered", deliver([201]) == .delivered && sent.count == 1)
        let r = sent.first
        let authz = r?.value(forHTTPHeaderField: "Authorization") ?? ""
        check("push: the request carries VAPID, TTL, urgency, topic and aes128gcm",
              authz.hasPrefix("vapid t=") && authz.hasSuffix(", k=" + vapid.publicKey.x963Representation.base64URLEncodedString())
              && r?.value(forHTTPHeaderField: "TTL") == "3600" && r?.value(forHTTPHeaderField: "Urgency") == "high"
              && r?.value(forHTTPHeaderField: "Topic") == "AbCdEfGhIjKlMnOpQrStUvWxYz012345"
              && r?.value(forHTTPHeaderField: "Content-Encoding") == "aes128gcm" && r?.httpMethod == "POST"
              && r?.url?.host == "web.push.apple.com")
        check("push: the push service gets ciphertext the phone can open", opened(r) == #"{"body":"secret"}"#
              && !(r?.httpBody.map { String(decoding: $0, as: UTF8.self).contains("secret") } ?? true))
        check("push: 413 resends once with the content hidden", deliver([413, 201]) == .delivered && sent.count == 2
              && opened(sent.last).contains("An agent needs you"))
        check("push: 413 twice gives up", deliver([413, 413]) == .failed("The push service refused it (HTTP 413)") && sent.count == 2)
        check("push: 429 and 5xx retry after 2 and 10 s", deliver([429, 503, 201]) == .delivered && delays == [2, 10] && sent.count == 3)
        if case .failed? = deliver([500, 500, 500, 500]) {
            check("push: 5xx gives up after retries at 2, 10 and 60 s", delays == [2, 10, 60] && sent.count == 4)
        } else {
            check("push: 5xx gives up after retries at 2, 10 and 60 s", false)
        }
        if case .failed? = deliver([403]) { check("push: other refusals aren't retried", sent.count == 1) }
        else { check("push: other refusals aren't retried", false) }

        // Offline: queued (at most 20, a newer push for the same topic replaces the older), sent when back.
        push.setOnline(false)
        for i in 0..<25 {
            var m = msg
            m.topic = "topic\(i % 22)"
            push.send(m, to: device.id)
        }
        check("push: offline pushes queue, at most 20 per device", push.queued(for: device.id) == 20)
        answers = []; sent = []
        push.setOnline(true)
        spin { sent.count == 20 }
        check("push: queued pushes go out when the network is back", sent.count == 20 && push.queued(for: device.id) == 0)
        check("push: a network error queues the push", deliver([nil]) == .queued && push.queued(for: device.id) == 1)
        push.resetQueue()

        // Turning on Hide content also covers pushes that waited offline.
        push.setOnline(false)
        push.send(msg, to: device.id)
        var prefs = devices.device(device.id)?.pushPrefs ?? PushPrefs()
        prefs.hideContent = true
        devices.setPrefs(prefs, for: device.id)
        answers = []; sent = []
        push.setOnline(true)
        spin { sent.count == 1 }
        check("push: a queued push follows Hide content as it is when it goes out",
              opened(sent.first).contains("An agent needs you") && !opened(sent.first).contains("secret"))
        prefs.hideContent = false
        devices.setPrefs(prefs, for: device.id)

        check("push: 410 forgets the subscription", deliver([410]) == .unsubscribed && devices.device(device.id)?.pushSubscription == nil)
        check("push: no subscription, no request", deliver([]) == .failed("Notifications are off for this device") && sent.isEmpty)
        devices.setSubscription(PushSubscription(endpoint: "https://push.apple.com.evil.test/x", p256dh: subscription.p256dh,
                                                 auth: subscription.auth), for: device.id)
        if case .failed? = deliver([201]) { check("push: a subscription outside the allowlist is never contacted", sent.isEmpty) }
        else { check("push: a subscription outside the allowlist is never contacted", false) }
    }

    // MARK: - Keep awake

    /// Names of the power assertions this process holds right now.
    private static func myAssertions() -> [String] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let all = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return (all[NSNumber(value: getpid())] ?? []).compactMap { $0["AssertName"] as? String }
    }

    private static func keepAwake() {
        func session(_ status: AgentStatus, tasks: Int = 0) -> AgentSession {
            var s = AgentSession(id: UUID().uuidString, workspaceId: "w", cwd: "/tmp", pid: nil, terminal: TerminalLocation(),
                                 status: status, handle: "claude-1")
            s.backgroundTasks = tasks
            return s
        }
        let ask = InboxItem(sessionId: "s", workspaceId: "w", kind: .permission, title: "Run", body: "$ ls")
        let done = InboxItem(sessionId: "s", workspaceId: "w", kind: .finished, title: "Done", body: "ok")
        check("awake: needed while an agent works", PowerAssertion.needed(sessions: [session(.working)], items: []))
        check("awake: needed while an agent is blocked on you", PowerAssertion.needed(sessions: [session(.waiting)], items: [])
              && PowerAssertion.needed(sessions: [session(.idle)], items: [ask]))
        check("awake: needed while background tasks run", PowerAssertion.needed(sessions: [session(.done, tasks: 1)], items: []))
        check("awake: not needed when agents are done, ready or idle",
              !PowerAssertion.needed(sessions: [session(.done), session(.ready), session(.idle)], items: [done]))

        let power = PowerAssertion()
        power.hold(true)
        check("awake: the assertion is held", power.isHeld && myAssertions().contains("Relay: agents are working"))
        power.hold(true)
        check("awake: holding twice keeps one assertion", myAssertions().filter { $0 == "Relay: agents are working" }.count == 1)
        power.hold(false)
        check("awake: the assertion is released", !power.isHeld && !myAssertions().contains("Relay: agents are working"))
    }
}
