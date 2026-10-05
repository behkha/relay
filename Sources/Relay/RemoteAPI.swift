import Foundation

/// What a phone may do through one door.
enum Capability: String, CaseIterable {
    case read       // inbox, agents, transcripts
    case answer     // answer questions and permission prompts, reply to and message agents
    case control    // start and kill agents, read their tmux terminals
}

/// The phone API, shared by both doors: the LAN page (token link) and the tailnet page (paired device).
/// Each door authenticates a request first, then hands it here with what that door allows.
final class RemoteAPI {
    private let store: Store

    init(store: Store) {
        self.store = store
    }

    /// The capability a route needs; nil when the route doesn't exist.
    static func capability(_ method: String, _ path: String) -> Capability? {
        switch (method, path) {
        case ("GET", "/"), ("GET", "/remote"), ("GET", "/api/state"), ("GET", "/api/session"): return .read
        case ("POST", "/api/answer"): return .answer
        default: return nil
        }
    }

    func handle(_ req: HTTPRequest, _ ex: HTTPExchange, caps: Set<Capability>) {
        // Routes a door doesn't allow look the same as routes that don't exist.
        guard let need = Self.capability(req.method, req.path), caps.contains(need) else {
            ex.respond(.notFound); return
        }
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/remote"):
            ex.respond(.text(Self.page(), type: "text/html; charset=utf-8"))
        case ("GET", "/api/state"):
            DispatchQueue.main.async { ex.respond(.json(self.snapshot(caps: caps))) }
        case ("GET", "/api/session"):
            let id = req.query["id"] ?? ""
            DispatchQueue.main.async {
                guard let s = self.store.sessions[id] else { ex.respond(.json(["ok": false], status: 404)); return }
                let path = s.transcriptPath
                DispatchQueue.global(qos: .userInitiated).async {
                    ex.respond(.json(["ok": true, "entries": RemoteAPI.transcriptJSON(path)]))
                }
            }
        case ("POST", "/api/answer"):
            guard let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
                ex.respond(.json(["ok": false, "error": "bad request"], status: 400)); return
            }
            DispatchQueue.main.async { ex.respond(.json(self.answer(body))) }
        default:
            ex.respond(.notFound)
        }
    }

    /// The phone page (one page for both doors; it shows only what `caps` allows).
    static func page() -> String {
        Bundle.main.url(forResource: "remote", withExtension: "html")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "<h1>Relay</h1>"
    }

    /// Last ~80 conversation entries for the phone's session view.
    static func transcriptJSON(_ path: String?) -> [[String: Any]] {
        let reader = TranscriptReader(path: path)
        let entries = reader.loadOnce().suffix(80)
        return entries.map { e in
            var d: [String: Any] = ["id": e.id, "text": String(e.text.prefix(3000))]
            switch e.kind {
            case .user: d["kind"] = "user"
            case .assistant: d["kind"] = "assistant"
            case .tool: d["kind"] = "tool"; d["detail"] = String((e.toolDetail ?? "").prefix(400)); d["error"] = e.isError
            case .notice: d["kind"] = "notice"
            }
            return d
        }
    }

    // MARK: State

    /// Everything the page shows. Call on the main thread.
    func snapshot(caps: Set<Capability>) -> [String: Any] {
        Self.snapshot(workspaces: store.workspaces, sessions: Array(store.sessions.values), items: store.items,
                      filter: store.workspaceFilter, heat: HeatMonitor.shared.heat, caps: caps)
    }

    static func snapshot(workspaces: [Workspace], sessions: [AgentSession], items: [InboxItem], filter: String?,
                         heat: [String: SessionHeat], caps: Set<Capability>) -> [String: Any] {
        let workspaces = workspaces.map { ["id": $0.id, "name": $0.name, "color": $0.colorHex, "email": $0.email ?? ""] }
        let sessions = sessions.sorted { $0.startedAt < $1.startedAt }.map { s -> [String: Any] in
            var d: [String: Any] = [
                "id": s.id, "handle": s.handle, "path": s.shortPath, "status": s.shownStatus.rawValue,
                "statusLabel": s.shownStatus.label, "workspaceId": s.workspaceId,
                "lastPrompt": s.lastPrompt ?? "", "lastMessage": String((s.lastMessage ?? "").prefix(2000)),
                "updatedAt": s.updatedAt.timeIntervalSince1970 * 1000,
            ]
            let h = heat[s.id]
            d["cpu"] = Int((h?.cpu ?? 0).rounded())
            d["heat"] = Self.heatName(h?.level ?? .none)
            return d
        }
        // Oldest first: new cards are appended, so nothing moves under a finger mid-tap.
        let items = items.sorted { $0.createdAt < $1.createdAt }.map { it -> [String: Any] in
            var d: [String: Any] = [
                "id": it.id, "sessionId": it.sessionId, "workspaceId": it.workspaceId, "kind": it.kind.rawValue,
                "title": it.title, "body": String(it.body.prefix(4000)), "createdAt": it.createdAt.timeIntervalSince1970 * 1000,
                "toolName": it.toolName ?? "", "live": it.isLive,
            ]
            if it.kind == .permission { d["options"] = KeyActions.permissionOptions(it).map { $0.0 } }
            d["questions"] = it.questions.map { q in
                ["question": q.question, "header": q.header ?? "", "multiSelect": q.multiSelect,
                 "options": q.options.map { ["label": $0.label, "description": $0.description ?? ""] }] as [String: Any]
            }
            return d
        }
        return ["workspaces": workspaces, "sessions": sessions, "items": items, "filter": filter ?? "",
                "caps": Capability.allCases.filter(caps.contains).map(\.rawValue)]
    }

    static func heatName(_ level: HeatLevel) -> String {
        switch level {
        case .none: return "none"
        case .warm: return "warm"
        case .hot: return "hot"
        }
    }

    // MARK: Answers

    private func answer(_ body: [String: Any]) -> [String: Any] {
        let action = body["action"] as? String ?? ""
        if action == "message", let sid = body["sessionId"] as? String, let text = body["text"] as? String {
            store.sendText(text, toSession: sid)
            return ["ok": true]
        }
        guard let id = body["itemId"] as? String, let item = store.items.first(where: { $0.id == id }) else {
            return ["ok": false, "error": "That question was already answered."]
        }
        switch action {
        case "answers":
            guard let answers = body["answers"] as? [String: String] else { return ["ok": false] }
            store.answerQuestion(item, answers: answers)
        case "permission":
            let idx = body["index"] as? Int ?? -1
            let opts = KeyActions.permissionOptions(item)
            guard idx >= 0, idx < opts.count else { return ["ok": false] }
            store.answerPermission(item, choice: opts[idx].1)
        case "reply":
            store.reply(to: item, text: body["text"] as? String ?? "")
        case "dismiss":
            store.dismiss(item)
        default:
            return ["ok": false, "error": "unknown action"]
        }
        return ["ok": true]
    }
}
