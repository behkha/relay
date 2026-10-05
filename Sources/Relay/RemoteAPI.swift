import Foundation
import CryptoKit

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
    private let devices: DeviceStore
    private let pushOverride: WebPush?
    private var push: WebPush { pushOverride ?? .shared }
    /// Shows a short message on the Mac.
    var notify: (String) -> Void = { Store.shared.showToast($0) }
    /// Starts an agent in tmux (a seam for the self-tests). Runs off the main thread.
    var launch: (Workspace, String, String, String) -> Result<String, Launcher.LaunchError> = {
        Launcher.newDetachedTmux(workspace: $0, folder: $1, prompt: $2, mode: $3)
    }

    init(store: Store, devices: DeviceStore = .shared, push: WebPush? = nil) {
        self.store = store
        self.devices = devices
        pushOverride = push
    }

    /// The capability a route needs; nil when the route doesn't exist.
    static func capability(_ method: String, _ path: String) -> Capability? {
        switch (method, path) {
        case ("GET", "/"), ("GET", "/remote"), ("GET", "/api/state"), ("GET", "/api/session"),
             ("POST", "/api/artifact/open"): return .read
        case ("POST", "/api/answer"): return .answer
        case ("GET", "/api/folders"), ("POST", "/api/start"), ("POST", "/api/kill"), ("GET", "/api/terminal"),
             ("POST", "/api/launch/dismiss"): return .control
        // A paired device's own settings.
        case ("POST", "/api/push/subscribe"), ("POST", "/api/push/unsubscribe"), ("POST", "/api/push/prefs"),
             ("POST", "/api/push/test"), ("POST", "/api/device/forget"): return .read
        default: return nil
        }
    }

    /// Routes about the calling device exist only on the tailnet door, where requests are signed by one.
    static func needsDevice(_ path: String) -> Bool {
        path.hasPrefix("/api/push/") || path.hasPrefix("/api/device/")
    }

    /// `device` is the paired device that signed the request (tailnet door only).
    func handle(_ req: HTTPRequest, _ ex: HTTPExchange, caps: Set<Capability>, device: Device? = nil) {
        // Routes a door doesn't allow look the same as routes that don't exist.
        guard let need = Self.capability(req.method, req.path), caps.contains(need),
              device != nil || !Self.needsDevice(req.path) else {
            ex.respond(.notFound); return
        }
        if let device, Self.needsDevice(req.path) { deviceRoute(req, ex, device: device); return }
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/remote"):
            ex.respond(.text(Self.page(), type: "text/html; charset=utf-8"))
        case ("GET", "/api/state"):
            DispatchQueue.main.async { ex.respond(.json(self.snapshot(caps: caps, device: device))) }
        case ("GET", "/api/folders"), ("POST", "/api/start"), ("POST", "/api/kill"), ("GET", "/api/terminal"),
             ("POST", "/api/launch/dismiss"):
            control(req, ex, from: device?.name ?? "Your phone")
        case ("GET", "/api/session"):
            let id = req.query["id"] ?? ""
            DispatchQueue.main.async {
                guard let s = self.store.sessions[id] else { ex.respond(.json(["ok": false], status: 404)); return }
                let path = s.transcriptPath
                DispatchQueue.global(qos: .userInitiated).async {
                    ex.respond(.json(["ok": true, "entries": RemoteAPI.transcriptJSON(path)]))
                }
            }
        case ("POST", "/api/artifact/open"):
            openArtifact(req, ex)
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
    func snapshot(caps: Set<Capability>, device: Device? = nil) -> [String: Any] {
        var snap = Self.snapshot(workspaces: store.workspaces, sessions: Array(store.sessions.values), items: store.items,
                                 filter: store.workspaceFilter, heat: HeatMonitor.shared.heat, caps: caps,
                                 launches: store.launches, canKill: store.canKill,
                                 artifacts: { ArtifactIndex.shared.cached($0.transcriptPath) })
        if let device = device.flatMap({ devices.device($0.id) }) {
            let p = device.pushPrefs
            snap["device"] = [
                "id": device.id, "name": device.name, "subscribed": device.pushSubscription != nil,
                "prefs": ["blocked": p.blocked, "finished": p.finished, "fire": p.fire, "hideContent": p.hideContent],
                "vapidKey": push.publicKey,
            ] as [String: Any]
        }
        return snap
    }

    static func snapshot(workspaces: [Workspace], sessions: [AgentSession], items: [InboxItem], filter: String?,
                         heat: [String: SessionHeat], caps: Set<Capability>, launches: [Store.PendingLaunch] = [],
                         canKill: (String) -> Bool = { _ in false },
                         artifacts: (AgentSession) -> [ArtifactRef] = { _ in [] }, now: Date = Date()) -> [String: Any] {
        let control = caps.contains(.control)
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
            let made = artifacts(s)
            if !made.isEmpty { d["artifacts"] = made.prefix(12).map { Self.artifactJSON($0, session: s, now: now) } }
            if control {
                d["canKill"] = canKill(s.id)
                d["tmux"] = !(s.terminal.tmuxPane ?? "").isEmpty
                d["title"] = s.displayName
            }
            return d
        }
        // Oldest first: new cards are appended, so nothing moves under a finger mid-tap.
        let items = items.sorted { $0.createdAt < $1.createdAt }.map { it -> [String: Any] in
            var d: [String: Any] = [
                "id": it.id, "sessionId": it.sessionId, "workspaceId": it.workspaceId, "kind": it.kind.rawValue,
                "title": it.title, "body": String(it.body.prefix(4000)), "createdAt": it.createdAt.timeIntervalSince1970 * 1000,
                "toolName": it.toolName ?? "", "live": it.isLive, "asking": InboxFilter.isAsking(it),
            ]
            if it.kind == .permission { d["options"] = KeyActions.permissionOptions(it).map { $0.0 } }
            d["questions"] = it.questions.map { q in
                ["question": q.question, "header": q.header ?? "", "multiSelect": q.multiSelect,
                 "options": q.options.map { ["label": $0.label, "description": $0.description ?? ""] }] as [String: Any]
            }
            return d
        }
        var snap: [String: Any] = ["workspaces": workspaces, "sessions": sessions, "items": items, "filter": filter ?? "",
                                   "caps": Capability.allCases.filter(caps.contains).map(\.rawValue)]
        if control {
            snap["launches"] = launches.map { l -> [String: Any] in
                ["id": l.id, "workspaceId": l.workspaceId, "folder": (l.folder as NSString).lastPathComponent,
                 "prompt": String(l.prompt.prefix(200)), "mode": l.mode, "startedAt": l.startedAt.timeIntervalSince1970 * 1000,
                 "error": l.error ?? "", "sessionId": l.sessionId ?? ""]
            }
        }
        return snap
    }

    /// One artifact for the phone. `inTurn`: made during the session's current turn (or, when Relay
    /// didn't see the turn start, in the last 30 minutes), so it may be what a question is about.
    static func artifactJSON(_ a: ArtifactRef, session s: AgentSession, now: Date) -> [String: Any] {
        let since = s.turnStartedAt ?? now.addingTimeInterval(-30 * 60)
        var d: [String: Any] = ["id": a.id, "title": a.title, "kind": a.kind.rawValue,
                                "createdAt": a.createdAt.timeIntervalSince1970 * 1000, "inTurn": a.createdAt >= since,
                                "name": (a.path as NSString).lastPathComponent]
        if let url = a.url { d["url"] = url }
        if let c = a.caption, !c.isEmpty { d["caption"] = String(c.prefix(300)) }
        return d
    }

    static func heatName(_ level: HeatLevel) -> String {
        switch level {
        case .none: return "none"
        case .warm: return "warm"
        case .hot: return "hot"
        }
    }

    // MARK: Artifacts

    /// POST /api/artifact/open {sessionId, artifactId}: a ticket link for one file the agent made.
    /// Only files the session's transcript shows it published or sent can be opened, never a path from the phone.
    private func openArtifact(_ req: HTTPRequest, _ ex: HTTPExchange) {
        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        let sid = body["sessionId"] as? String ?? ""
        let aid = body["artifactId"] as? String ?? ""
        DispatchQueue.main.async {
            guard let path = self.store.sessions[sid]?.transcriptPath else {
                ex.respond(.json(["ok": false, "error": "That agent is gone."])); return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let a = ArtifactIndex.shared.current(path).first(where: { $0.id == aid }) else {
                    ex.respond(.json(["ok": false, "error": "That artifact isn't in this session."])); return
                }
                var r: [String: Any] = ["ok": false, "title": a.title, "kind": a.kind.rawValue, "name": (a.path as NSString).lastPathComponent]
                if let url = a.url { r["claudeUrl"] = url }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: a.path, isDirectory: &isDir), !isDir.boolValue,
                      let size = (try? FileManager.default.attributesOfItem(atPath: a.path)[.size] as? Int) ?? nil else {
                    r["error"] = a.url == nil ? "That file isn't on the Mac anymore." : "That file isn't on the Mac anymore. It's still on claude.ai."
                    ex.respond(.json(r)); return
                }
                r["size"] = size
                guard size <= ArtifactTickets.maxBytes else {
                    r["error"] = "It's too big to open on the phone (\(size / 1_048_576) MB)."
                    ex.respond(.json(r)); return
                }
                let ticket = ArtifactTickets.shared.issue(path: a.path)
                let name = (a.path as NSString).lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
                r["ok"] = true
                r["url"] = ArtifactTickets.prefix + ticket + "/" + name
                ex.respond(.json(r))
            }
        }
    }

    // MARK: Control (start, kill, terminal)

    enum StartProblem: Equatable {
        case unknownWorkspace, badMode, unknownFolder, badPrompt

        var message: String {
            switch self {
            case .unknownWorkspace: return "That workspace isn't on this Mac anymore."
            case .badMode: return "Pick Default, Plan or Accept edits."
            case .unknownFolder: return "Relay only starts agents in folders it knows: where your agents ran, or folders pinned in Settings → Phone on the Mac."
            case .badPrompt: return "That prompt can't be used."
            }
        }
    }

    /// Whether the phone may start this agent: a known workspace, one of the folders Relay already knows
    /// for it (never a path typed on the phone), a mode other than bypassing permissions, a sane prompt.
    static func startProblem(workspaceId: String, folder: String, prompt: String, mode: String,
                             workspaces: [Workspace], known: (String) -> [String]) -> StartProblem? {
        guard workspaces.contains(where: { $0.id == workspaceId }) else { return .unknownWorkspace }
        guard Launcher.phoneModes.contains(mode) else { return .badMode }
        guard known(workspaceId).contains(folder) else { return .unknownFolder }
        guard prompt.count <= 20_000, !prompt.contains("\0") else { return .badPrompt }
        return nil
    }

    private func control(_ req: HTTPRequest, _ ex: HTTPExchange, from deviceName: String) {
        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        switch req.path {
        case "/api/folders":
            DispatchQueue.main.async {
                let list = self.store.workspaces.map { ws -> [String: Any] in
                    let folders = self.store.knownFolders(workspace: ws.id).map { f -> [String: Any] in
                        ["path": f.path, "name": (f.path as NSString).lastPathComponent,
                         "short": (f.path as NSString).abbreviatingWithTildeInPath, "pinned": f.pinned]
                    }
                    return ["id": ws.id, "name": ws.name, "color": ws.colorHex, "folders": folders]
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let tmux = Proc.which("tmux") != nil
                    ex.respond(.json(["ok": true, "workspaces": list, "tmux": tmux, "modes": Launcher.phoneModes]))
                }
            }
        case "/api/start":
            let wsId = body["workspaceId"] as? String ?? ""
            let folder = body["folder"] as? String ?? ""
            let prompt = body["prompt"] as? String ?? ""
            let mode = body["mode"] as? String ?? "default"
            DispatchQueue.main.async {
                if let problem = Self.startProblem(workspaceId: wsId, folder: folder, prompt: prompt, mode: mode,
                                                   workspaces: self.store.workspaces,
                                                   known: { self.store.knownFolders(workspace: $0).map(\.path) }) {
                    ex.respond(.json(["ok": false, "error": problem.message])); return
                }
                guard let ws = self.store.workspace(wsId) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = self.launch(ws, folder, prompt, mode)
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let id):
                            self.store.addLaunch(Store.PendingLaunch(id: id, workspaceId: ws.id, folder: folder, prompt: prompt, mode: mode))
                            self.notify("\(deviceName) started an agent in \((folder as NSString).lastPathComponent)")
                            ex.respond(.json(["ok": true, "launchId": id]))
                        case .failure(let e):
                            ex.respond(.json(["ok": false, "error": e.message, "needsTmux": e == .noTmux]))
                        }
                    }
                }
            }
        case "/api/kill":
            let sid = body["sessionId"] as? String ?? ""
            DispatchQueue.main.async {
                // The same path as Kill agent on the Mac.
                guard let s = self.store.sessions[sid], self.store.canKill(sid) else {
                    ex.respond(.json(["ok": false, "error": "This agent can't be stopped from Relay."])); return
                }
                self.store.killAgent(sid)
                if self.store.sessions[sid] == nil {
                    self.notify("\(deviceName) stopped @\(s.handle)")
                    ex.respond(.json(["ok": true]))
                } else {
                    ex.respond(.json(["ok": false, "error": "Couldn't stop @\(s.handle)."]))
                }
            }
        case "/api/terminal":
            let sid = req.query["id"] ?? ""
            DispatchQueue.main.async {
                guard let s = self.store.sessions[sid], let pane = s.terminal.tmuxPane, !pane.isEmpty else {
                    ex.respond(.json(["ok": false, "error": "Only agents running in tmux have a terminal view."])); return
                }
                let socket = s.terminal.tmux.flatMap { $0.split(separator: ",").first.map(String.init) }
                DispatchQueue.global(qos: .userInitiated).async {
                    if let text = Launcher.capturePane(target: pane, socket: socket, lines: 60) {
                        ex.respond(.json(["ok": true, "text": text]))
                    } else {
                        ex.respond(.json(["ok": false, "error": "Couldn't read its tmux pane."]))
                    }
                }
            }
        case "/api/launch/dismiss":
            let id = body["id"] as? String ?? ""
            DispatchQueue.main.async {
                self.store.dismissLaunch(id)
                ex.respond(.json(["ok": true]))
            }
        default:
            ex.respond(.notFound)
        }
    }

    // MARK: The calling device

    private func deviceRoute(_ req: HTTPRequest, _ ex: HTTPExchange, device: Device) {
        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        switch req.path {
        case "/api/push/subscribe":
            let keys = body["keys"] as? [String: Any] ?? [:]
            let sub = PushSubscription(endpoint: body["endpoint"] as? String ?? "",
                                       p256dh: keys["p256dh"] as? String ?? "", auth: keys["auth"] as? String ?? "")
            guard Self.isUsable(sub) else {
                ex.respond(.json(["ok": false, "error": "This browser's push service isn't one Relay sends to."], status: 400)); return
            }
            DispatchQueue.main.async {
                self.devices.setSubscription(sub, for: device.id)
                ex.respond(.json(["ok": true]))
            }
        case "/api/push/unsubscribe":
            DispatchQueue.main.async {
                self.devices.setSubscription(nil, for: device.id)
                ex.respond(.json(["ok": true]))
            }
        case "/api/push/prefs":
            DispatchQueue.main.async {
                var p = self.devices.device(device.id)?.pushPrefs ?? device.pushPrefs
                if let v = body["blocked"] as? Bool { p.blocked = v }
                if let v = body["finished"] as? Bool { p.finished = v }
                if let v = body["fire"] as? Bool { p.fire = v }
                if let v = body["hideContent"] as? Bool { p.hideContent = v }
                self.devices.setPrefs(p, for: device.id)
                ex.respond(.json(["ok": true]))
            }
        case "/api/push/test":
            DispatchQueue.main.async {
                let hide = self.devices.device(device.id)?.pushPrefs.hideContent ?? false
                self.push.send(PushDispatcher.testMessage(hidden: hide), to: device.id) { outcome in
                    switch outcome {
                    case .delivered: ex.respond(.json(["ok": true]))
                    case .queued: ex.respond(.json(["ok": true, "note": "The Mac is offline; it sends this when it's back."]))
                    case .unsubscribed: ex.respond(.json(["ok": false, "error": "The push service no longer knows this device. Turn notifications on again."]))
                    case .failed(let why): ex.respond(.json(["ok": false, "error": why]))
                    }
                }
            }
        case "/api/device/forget":
            DispatchQueue.main.async {
                self.devices.revoke(device.id)
                self.notify("\(device.name) was unpaired from the phone")
                ex.respond(.json(["ok": true]))
            }
        default:
            ex.respond(.notFound)
        }
    }

    /// A subscription Relay may send to: an allowed push service and well-formed keys.
    static func isUsable(_ sub: PushSubscription) -> Bool {
        guard WebPush.allowedEndpoint(sub.endpoint) != nil,
              let key = Data(base64URL: sub.p256dh), key.count == 65,
              (try? P256.KeyAgreement.PublicKey(x963Representation: key)) != nil,
              Data(base64URL: sub.auth)?.count == 16 else { return false }
        return true
    }

    // MARK: Answers

    private func answer(_ body: [String: Any]) -> [String: Any] {
        let action = body["action"] as? String ?? ""
        if action == "message", let sid = body["sessionId"] as? String, let text = body["text"] as? String {
            store.sendText(text, toSession: sid)
            return ["ok": true]
        }
        if action == "clear" {
            // Bulk clear from the phone: only finished and idle cards, never an open question.
            let ids = Set(body["itemIds"] as? [String] ?? [])
            return ["ok": true, "cleared": store.clearDone(ids: ids)]
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
