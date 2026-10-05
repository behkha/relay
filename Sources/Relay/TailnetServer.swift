import Foundation
import AppKit
import CryptoKit

/// The tailnet door: a listener on 127.0.0.1:47902 that only Tailscale Serve should talk to.
/// The page, its PWA files and pairing are open; every other request must be signed by a paired
/// device (`DeviceStore.verify`) and then gets the full phone API, including starting and killing agents.
final class TailnetServer {
    private var server: HTTPServer?
    private let api: RemoteAPI
    private let devices: DeviceStore
    /// Asks on the Mac whether to pair a device; `done` runs on the main thread. Returns a way to
    /// withdraw the question (the phone gave up waiting).
    var confirmPairing: (_ name: String, _ login: String, _ fingerprint: String,
                         _ done: @escaping (Bool) -> Void) -> (() -> Void) = PairingPrompt.ask
    /// Shows a short message on the Mac.
    var notify: (String) -> Void = { Store.shared.showToast($0) }
    /// Which Host headers to answer (a seam for the self-tests, which talk to 127.0.0.1 directly).
    var acceptHost: (String?) -> Bool = TailnetServer.isTailnetHost
    /// Connections at once, and how long one may take to send its request. Serve opens one
    /// connection per request, so this caps what anyone on the tailnet can hold open.
    static let maxConnections = 32
    static let requestTimeout: TimeInterval = 10

    init(api: RemoteAPI, devices: DeviceStore) {
        self.api = api
        self.devices = devices
    }

    var isRunning: Bool { server != nil }
    var port: UInt16 { server?.port ?? 0 }

    /// Listens on exactly `port`; never falls back to another one, because Serve points at it.
    func start(port: UInt16 = Tailscale.relayPort) throws {
        guard server == nil else { return }
        let s = HTTPServer(label: "tailnet", localOnly: true, maxBody: 256 * 1024) { [weak self] req, ex in
            guard let self else { ex.respond(.empty); return }
            self.handle(req, ex)
        }
        s.acceptPeer = { TailnetServer.isLoopback($0) }
        s.defaultHeaders = Self.securityHeaders
        s.maxConnections = Self.maxConnections
        s.requestTimeout = Self.requestTimeout
        try s.start(exactPort: port)
        server = s
    }

    func stop() {
        server?.stop()
        server = nil
        PairingPrompt.withdrawAll()
    }

    var connectionCount: Int { server?.connectionCount ?? 0 }

    static func isLoopback(_ host: String?) -> Bool {
        guard var h = host?.lowercased() else { return false }
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
        if h.hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
        return h == "::1" || h.hasPrefix("127.")
    }

    /// Serve passes on the name the phone used, which is always a *.ts.net name. A web page in a
    /// browser on this Mac that rebinds its own domain to 127.0.0.1 can't send that Host.
    static func isTailnetHost(_ host: String?) -> Bool {
        guard var h = host?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return false }
        if let colon = h.lastIndex(of: ":"), h[h.index(after: colon)...].allSatisfy(\.isNumber) { h = String(h[..<colon]) }
        return h.hasSuffix(".ts.net") && h.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }
    }

    /// Every response: nothing runs inline, only this origin is contacted, nothing may frame it.
    static let securityHeaders = [
        "Content-Security-Policy": "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
        "X-Frame-Options": "DENY",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
    ]

    /// The page's policy: its own inline script runs (allowed by hash, so an injected script or
    /// event handler never does), its inline styles apply, and it only talks to this origin.
    static func pageCSP(for html: String) -> String {
        var hashes: [String] = []
        var rest = html[...]
        while let open = rest.range(of: "<script>"), let close = rest.range(of: "</script>", range: open.upperBound..<rest.endIndex) {
            hashes.append("'sha256-" + Data(SHA256.hash(data: Data(rest[open.upperBound..<close.lowerBound].utf8))).base64EncodedString() + "'")
            rest = rest[close.upperBound...]
        }
        return "default-src 'self'; script-src 'self' \(hashes.joined(separator: " ")); style-src 'self' 'unsafe-inline'; "
            + "img-src 'self' data:; connect-src 'self'; manifest-src 'self'; worker-src 'self'; "
            + "frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    }

    static func page(_ html: String) -> HTTPResponse {
        var r = HTTPResponse.text(html, type: "text/html; charset=utf-8")
        r.extraHeaders["Content-Security-Policy"] = pageCSP(for: html)
        return r
    }

    /// Files the Home Screen app needs before it is paired, by URL path: (resource name, extension, type).
    static let assets: [String: (String, String, String)] = [
        "/manifest.webmanifest": ("manifest", "webmanifest", "application/manifest+json"),
        "/sw.js": ("sw", "js", "text/javascript; charset=utf-8"),
        "/icon-192.png": ("icon-192", "png", "image/png"),
        "/icon-512.png": ("icon-512", "png", "image/png"),
    ]

    // MARK: Routes

    func handle(_ req: HTTPRequest, _ ex: HTTPExchange) {
        // Funnel would put this on the public internet. Relay never answers it.
        if req.header("tailscale-funnel-request") != nil { ex.respond(.text("forbidden", status: 403)); return }
        guard acceptHost(req.header("host")) else { ex.respond(.text("misdirected request", status: 421)); return }
        switch (req.method, req.path) {
        case ("GET", "/"):
            ex.respond(Self.page(RemoteAPI.page()))
        case ("GET", "/pair"):
            // Installed from here, the Home Screen app opens on this pairing link (the code stays in
            // the fragment): iOS gives Home Screen apps their own storage, so they pair themselves.
            ex.respond(Self.page(RemoteAPI.page().replacingOccurrences(of: "/manifest.webmanifest", with: "/pair.webmanifest")))
        case ("GET", "/pair.webmanifest"):
            ex.respond(Self.pairManifest())
        case ("GET", let path) where Self.assets[path] != nil:
            ex.respond(Self.asset(path))
        case ("POST", "/api/pair"):
            pair(req, ex)
        case ("GET", let path) where path.hasPrefix(ArtifactTickets.prefix):
            // The ticket is the credential: the phone got it from a signed request a moment ago.
            ex.respond(ArtifactTickets.shared.response(for: path))
        default:
            authenticated(req, ex)
        }
    }

    static func asset(_ path: String) -> HTTPResponse {
        guard let (name, ext, type) = assets[path],
              let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return .notFound }
        return HTTPResponse(status: 200, contentType: type, body: data)
    }

    /// The manifest without a start URL, so an app installed from /pair#c=… opens on that link.
    static func pairManifest() -> HTTPResponse {
        let base = asset("/manifest.webmanifest")
        guard base.status == 200, var json = (try? JSONSerialization.jsonObject(with: base.body)) as? [String: Any] else { return base }
        json.removeValue(forKey: "start_url")
        json.removeValue(forKey: "id")
        var r = HTTPResponse.json(json)
        r.contentType = "application/manifest+json"
        return r
    }

    private func authenticated(_ req: HTTPRequest, _ ex: HTTPExchange) {
        DispatchQueue.main.async {
            guard let device = self.devices.verify(req) else { ex.respond(.unauthorized); return }
            self.devices.touch(device.id)
            self.api.handle(req, ex, caps: [.read, .answer, .control], device: device)
        }
    }

    // MARK: Pairing

    /// POST /api/pair {code, publicKey, deviceName}: a valid code, the Tailscale login of whoever asks,
    /// and a yes on the Mac. The answer waits for that yes (up to two minutes).
    private func pair(_ req: HTTPRequest, _ ex: HTTPExchange) {
        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        let code = body["code"] as? String ?? ""
        let publicKey = body["publicKey"] as? String ?? ""
        let name = DeviceStore.cleanName(body["deviceName"] as? String ?? "")
        let login = req.header("tailscale-user-login") ?? ""
        DispatchQueue.main.async {
            // Without the login, the request didn't come through Tailscale Serve as a signed-in person
            // (Serve gives tagged devices no identity). The code stays valid.
            guard !login.isEmpty, login.count <= 254,
                  !login.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                self.devices.recordFailure()
                ex.respond(.json(["ok": false, "error": "Relay pairs devices that reach it through Tailscale as a signed-in user. Tagged devices can't pair."], status: 403))
                return
            }
            guard !self.devices.isCoolingDown(login: login) else {
                ex.respond(.json(["ok": false, "error": "Too many failed attempts from this Tailscale account. Wait a minute, then make a new code."], status: 429))
                return
            }
            guard self.devices.consumePairingCode(code, login: login) else { ex.respond(.unauthorized); return }
            switch self.devices.pairingProblem(publicKey: publicKey, login: login) {
            case .badKey?:
                ex.respond(.json(["ok": false, "error": "This browser's key isn't valid. Reload and try again."], status: 400))
                return
            case .otherOwner?:
                ex.respond(.json(["ok": false, "error": "Pair from the same Tailscale account as your other devices, or revoke them on the Mac first."], status: 403))
                return
            case nil:
                break
            }
            let fingerprint = Self.fingerprint(publicKey)
            let withdraw = self.confirmPairing(name, login, fingerprint) { allowed in
                // The phone may have given up, or remote access was turned off, while the question was up;
                // then nothing is stored.
                guard allowed, !ex.isFinished, self.isRunning,
                      let device = self.devices.addDevice(name: name, publicKey: publicKey, login: login) else {
                    ex.respond(.json(["ok": false, "error": "Not allowed on the Mac."], status: 403))
                    return
                }
                self.notify("Paired \(device.name)")
                ex.respond(.json(["ok": true, "deviceId": device.id, "name": device.name]))
            }
            ex.onClientClose { DispatchQueue.main.async { withdraw() } }
        }
    }

    /// A short code both screens show, so you can tell your phone's request from anyone else's:
    /// the first 4 bytes of SHA-256 of the raw public key, as "1A2B-3C4D".
    static func fingerprint(_ publicKey: String) -> String {
        guard let raw = Data(base64URL: publicKey) else { return "" }
        let hex = Data(SHA256.hash(data: raw).prefix(4)).hexString.uppercased()
        return String(hex.prefix(4)) + "-" + String(hex.suffix(4))
    }
}

/// The Mac's question for a pairing request. Being at the Mac is what makes a leaked code useless.
/// It's a floating alert window, not a modal session: a modal loop started from a main-queue block
/// would hold up every other main-queue block (hooks, the API) until it was answered.
enum PairingPrompt {
    private final class Prompt: NSObject {
        let alert = NSAlert()
        var done: ((Bool) -> Void)?

        @objc func allow() { finish(true) }
        @objc func deny() { finish(false) }

        func finish(_ allowed: Bool) {
            guard let done else { return }
            self.done = nil
            alert.window.orderOut(nil)
            PairingPrompt.open.removeAll { $0 === self }
            done(allowed)
        }
    }

    private static var open: [Prompt] = []

    static func ask(name: String, login: String, fingerprint: String, done: @escaping (Bool) -> Void) -> () -> Void {
        let prompt = Prompt()
        prompt.done = done
        open.append(prompt)
        let alert = prompt.alert
        alert.messageText = "Pair “\(name)” with Relay?"
        alert.informativeText = """
        \(DeviceStore.printable(login, max: 120)) via Tailscale wants to use your agents from this device: answer them, start new ones and stop them.

        Check that the device shows \(fingerprint). Allow it only if you just scanned the pairing code yourself.
        """
        // Deny is the default, so Return never pairs anything by accident.
        let deny = alert.addButton(withTitle: "Deny")
        deny.target = prompt
        deny.action = #selector(Prompt.deny)
        let allow = alert.addButton(withTitle: "Allow")
        allow.target = prompt
        allow.action = #selector(Prompt.allow)
        alert.alertStyle = .warning
        alert.layout()
        alert.window.level = .floating
        alert.window.center()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { prompt.finish(false) }
        return { prompt.finish(false) }
    }

    /// Answers every open question with Deny (remote access was turned off).
    static func withdrawAll() {
        open.forEach { $0.finish(false) }
    }
}

// MARK: - Remote access

/// Phone access from anywhere: the tailnet door plus Relay's Tailscale Serve entry, turned on and
/// off together from Settings → Phone (remembered as `tailnetEnabled`).
final class RemoteAccess: ObservableObject {
    @Published private(set) var enabled = false
    /// The checks run so far (for Settings), and whether a check is running.
    @Published private(set) var passed: [Tailscale.Step] = []
    @Published private(set) var busy = false
    @Published private(set) var failure: Tailscale.Failure?
    /// Port 47902 couldn't be opened.
    @Published private(set) var portError: String?
    /// The phone's address, e.g. https://mac.tail1234.ts.net.
    @Published private(set) var url: URL?
    /// Funnel (public access) is on for Relay's port; Relay refuses that traffic, but it shouldn't be on.
    @Published private(set) var funnelOn = false

    let devices: DeviceStore
    let server: TailnetServer
    private let queue = DispatchQueue(label: "relay.tailscale", qos: .userInitiated)
    private var generation = 0

    init(store: Store, devices: DeviceStore = .shared) {
        self.devices = devices
        server = TailnetServer(api: RemoteAPI(store: store, devices: devices), devices: devices)
        if !Demo.isOn, UserDefaults.standard.bool(forKey: "tailnetEnabled") { setEnabled(true) }
    }

    private var lastPort: UInt16? {
        get { (UserDefaults.standard.object(forKey: "tailnetPort") as? Int).flatMap { UInt16(exactly: $0) } }
        set { UserDefaults.standard.set(newValue.map { Int($0) }, forKey: "tailnetPort") }
    }

    /// The pairing link for the QR code (with a fresh single-use code), or nil until Serve is up.
    func newPairingLink() -> URL? {
        guard let url else { return nil }
        let code = devices.newPairingCode()
        return URL(string: url.absoluteString + "/pair#c=" + code)
    }

    func setEnabled(_ on: Bool) {
        guard !Demo.isOn else { return }
        UserDefaults.standard.set(on, forKey: "tailnetEnabled")
        enabled = on
        on ? start() : stop()
    }

    /// Runs the checks again (after you fixed what the last one reported).
    func retry() {
        if enabled { start() }
    }

    private func start() {
        generation += 1
        let run = generation
        failure = nil
        passed = []
        url = nil
        if !server.isRunning {
            do {
                try server.start()
                portError = nil
            } catch {
                portError = "Port \(Tailscale.relayPort) is in use by another app, so Relay can't open its door for Tailscale. Quit that app and try again."
                return
            }
        }
        busy = true
        let previous = lastPort
        queue.async {
            let result = Tailscale.enable(previousPort: previous) { step in
                DispatchQueue.main.async { if self.generation == run { self.passed.append(step) } }
            }
            DispatchQueue.main.async {
                guard self.generation == run else { return }   // turned off or retried meanwhile
                self.busy = false
                switch result {
                case .success(let e):
                    self.url = e.url
                    self.funnelOn = e.funnel
                    self.lastPort = e.port
                case .failure(let f):
                    self.failure = f
                }
            }
        }
    }

    private func stop() {
        generation += 1
        let run = generation
        server.stop()
        devices.cancelPairingCode()
        url = nil
        failure = nil
        portError = nil
        passed = []
        funnelOn = false
        busy = true
        queue.async {
            let problem = Tailscale.disable()
            DispatchQueue.main.async {
                guard self.generation == run else { return }
                self.busy = false
                self.failure = problem
            }
        }
    }
}
