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
    private let api: RemoteAPI
    private let tokenLock = NSLock()
    private var _token: String
    private var token: String {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _token }
        set { tokenLock.lock(); _token = newValue; tokenLock.unlock() }
    }

    init(store: Store) {
        api = RemoteAPI(store: store)
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
        api.handle(req, ex, caps: [.read, .answer])
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
