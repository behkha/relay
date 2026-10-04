import Foundation
import AppKit
import Combine
import CoreImage
import Security

/// Serves the phone inbox on the local network (http://<mac-ip>:47901/?t=<token>).
final class RemoteServer: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var url: URL?
    @Published private(set) var error: String?

    private var server: HTTPServer?
    private let store: Store
    private let tokenLock = NSLock()
    private var _token: String
    private var token: String {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _token }
        set { tokenLock.lock(); _token = newValue; tokenLock.unlock() }
    }

    init(store: Store) {
        self.store = store
        _token = UserDefaults.standard.string(forKey: "remoteToken") ?? RemoteServer.randomToken()
        UserDefaults.standard.set(_token, forKey: "remoteToken")
        if UserDefaults.standard.bool(forKey: "remoteEnabled") { setEnabled(true) }
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "remoteEnabled")
        server?.stop()
        server = nil
        url = nil
        enabled = on
        guard on else { return }
        let s = HTTPServer(label: "remote", localOnly: false, maxBody: 256 * 1024) { [weak self] req, ex in self?.handle(req, ex) }
        s.acceptPeer = { RemoteServer.isLocalNetwork($0) }
        do {
            try s.start(preferredPort: 47901)
            server = s
            refreshURL()
        } catch {
            self.error = "Couldn't start: \(error.localizedDescription)"
        }
    }

    func rotateToken() {
        token = Self.randomToken()
        UserDefaults.standard.set(token, forKey: "remoteToken")
        refreshURL()
    }

    func refreshURL() {
        guard let port = server?.port, port > 0 else { return }
        guard let ip = Self.lanAddress() else {
            url = nil
            error = "Connect this Mac to Wi‑Fi or Ethernet to use your phone."
            return
        }
        error = nil
        url = URL(string: "http://\(ip):\(port)/?t=\(token)")
    }

    /// First private IPv4 address on an active interface (en0 preferred).
    static func lanAddress() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var found: [(String, String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let name = String(cString: ifa.ifa_name)
                let ip = String(cString: host)
                if ip.hasPrefix("169.254.") { continue }
                found.append((name, ip))
            }
        }
        return (found.first { $0.0 == "en0" } ?? found.first { $0.0.hasPrefix("en") } ?? found.first)?.1
    }

    /// Only devices on this Mac's own network may connect (no public or VPN-routed addresses).
    static func isLocalNetwork(_ host: String?) -> Bool {
        guard var h = host?.lowercased() else { return false }
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
        if h.hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
        if h == "::1" { return true }
        if h.contains(":") {
            return h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb")   // link-local
                || h.hasPrefix("fc") || h.hasPrefix("fd")                                                // unique local
        }
        let p = h.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        switch (p[0], p[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    private func authorized(_ req: HTTPRequest) -> Bool {
        let given = req.query["t"] ?? req.header("x-relay-token") ?? ""
        guard given.utf8.count == token.utf8.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(given.utf8, token.utf8) { diff |= a ^ b }
        return diff == 0
    }

    // MARK: Routes

    private func handle(_ req: HTTPRequest, _ ex: HTTPExchange) {
        guard authorized(req) else { ex.respond(.unauthorized); return }
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/remote"):
            let html = Bundle.main.url(forResource: "remote", withExtension: "html")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "<h1>Relay</h1>"
            ex.respond(.text(html, type: "text/html; charset=utf-8"))
        case ("GET", "/api/state"):
            DispatchQueue.main.async { ex.respond(.json(self.snapshot())) }
        case ("GET", "/api/session"):
            let id = req.query["id"] ?? ""
            DispatchQueue.main.async {
                guard let s = self.store.sessions[id] else { ex.respond(.json(["ok": false], status: 404)); return }
                let path = s.transcriptPath
                DispatchQueue.global(qos: .userInitiated).async {
                    ex.respond(.json(["ok": true, "entries": RemoteServer.transcriptJSON(path)]))
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

    private func snapshot() -> [String: Any] {
        let workspaces = store.workspaces.map { ["id": $0.id, "name": $0.name, "color": $0.colorHex, "email": $0.email ?? ""] }
        let sessions = store.sessions.values.sorted { $0.startedAt < $1.startedAt }.map { s -> [String: Any] in
            ["id": s.id, "handle": s.handle, "path": s.shortPath, "status": s.status.rawValue,
             "statusLabel": s.status.label, "workspaceId": s.workspaceId,
             "lastPrompt": s.lastPrompt ?? "", "lastMessage": String((s.lastMessage ?? "").prefix(2000))]
        }
        // Oldest first: new cards are appended, so nothing moves under a finger mid-tap.
        let items = store.items.sorted { $0.createdAt < $1.createdAt }.map { it -> [String: Any] in
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
        return ["workspaces": workspaces, "sessions": sessions, "items": items, "filter": store.workspaceFilter ?? ""]
    }

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

enum QRCode {
    static func image(for text: String, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
