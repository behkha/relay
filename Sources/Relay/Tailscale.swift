import Foundation

/// The `tailscale` CLI: finding it, reading its status, and turning Relay's Tailscale Serve entry on
/// and off. Relay only ever adds or removes its own entry, HTTPS 443 (or 8443) → http://127.0.0.1:47902,
/// and never touches anything else that Serve is doing on this Mac.
enum Tailscale {
    /// The loopback port of Relay's tailnet door; Serve proxies to it.
    static let relayPort: UInt16 = 47902
    static var target: String { "http://127.0.0.1:\(relayPort)" }
    /// Tried in this order when Relay has no entry yet. 8443 is only used when 443 serves something else.
    static let httpsPorts: [UInt16] = [443, 8443]
    static let adminDNS = URL(string: "https://login.tailscale.com/admin/dns")!
    static let download = URL(string: "https://tailscale.com/download/mac")!

    // MARK: Errors

    enum Failure: Error, Equatable {
        case notInstalled
        case needsLogin
        case notRunning(String)       // tailscaled's BackendState
        case magicDNSOff
        case noName
        case httpsDisabled(URL?)      // where to turn HTTPS certificates on
        case portsTaken               // 443 and 8443 both serve something else
        case command(String)          // the CLI failed; what it said

        var message: String {
            switch self {
            case .notInstalled:
                return "Tailscale isn't installed on this Mac. Install it, sign in, then turn this on again."
            case .needsLogin:
                return "Sign in to Tailscale on this Mac, then try again."
            case .notRunning(let state):
                return state == "Stopped"
                    ? "Tailscale is turned off. Open Tailscale and connect, then try again."
                    : "Tailscale isn't connected yet (\(state)). Open Tailscale and connect, then try again."
            case .magicDNSOff:
                return "Turn on MagicDNS for your tailnet (Tailscale admin console → DNS), then try again."
            case .noName:
                return "Tailscale didn't report a name for this Mac. Check that MagicDNS is on, then try again."
            case .httpsDisabled:
                return "Turn on HTTPS certificates for your tailnet (Tailscale admin console → DNS → HTTPS Certificates), then try again."
            case .portsTaken:
                return "Tailscale Serve already uses ports 443 and 8443 on this Mac for something else. Relay won't change them; free one (for example `tailscale serve --https=8443 off`) and try again."
            case .command(let output):
                return "Tailscale said: \(output)"
            }
        }

        /// Where the user can fix it, if a page helps.
        var link: URL? {
            switch self {
            case .notInstalled: return Tailscale.download
            case .magicDNSOff: return Tailscale.adminDNS
            case .httpsDisabled(let url): return url ?? Tailscale.adminDNS
            default: return nil
            }
        }
    }

    // MARK: CLI

    /// The CLI on PATH, else the one inside the Mac app.
    static func cli() -> String? {
        if let path = Proc.which("tailscale") { return path }
        let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        return FileManager.default.isExecutableFile(atPath: app) ? app : nil
    }

    private static func run(_ cli: String, _ args: [String], timeout: TimeInterval = 15) -> ProcessResult {
        Proc.run(cli, args, timeout: timeout)
    }

    /// The first line the CLI printed on failure, for error messages.
    private static func complaint(_ r: ProcessResult) -> String {
        let text = (r.stderr + "\n" + r.stdout).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "exit status \(r.status)"
        return String(text.prefix(300))
    }

    // MARK: Status

    struct Status: Equatable {
        var backendState: String
        /// This Mac's MagicDNS name, without the trailing dot ("mac.tail1234.ts.net").
        var dnsName: String?
        var magicDNS: Bool
        /// Names the control server will issue HTTPS certificates for; empty when certificates are off.
        var certDomains: [String]
    }

    /// Parses `tailscale status --json`.
    static func parseStatus(_ data: Data) -> Status? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = root["BackendState"] as? String else { return nil }
        let me = root["Self"] as? [String: Any]
        var name = (me?["DNSName"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        let tailnet = root["CurrentTailnet"] as? [String: Any]
        let suffix = tailnet?["MagicDNSSuffix"] as? String ?? root["MagicDNSSuffix"] as? String ?? ""
        let magic = tailnet?["MagicDNSEnabled"] as? Bool ?? !suffix.isEmpty
        let certs = (root["CertDomains"] as? [String] ?? []).map { $0.lowercased() }
        return Status(backendState: state, dnsName: name.isEmpty ? nil : name, magicDNS: magic, certDomains: certs)
    }

    /// What's wrong with this status for serving Relay, if anything.
    static func problem(with s: Status) -> Failure? {
        switch s.backendState {
        case "Running": break
        case "NeedsLogin", "NeedsMachineAuth": return .needsLogin
        default: return .notRunning(s.backendState)
        }
        guard s.magicDNS else { return .magicDNSOff }
        guard s.dnsName != nil else { return .noName }
        return nil
    }

    static func status(cli: String) -> Result<Status, Failure> {
        let r = run(cli, ["status", "--json"])
        // `status` exits non-zero when stopped but still prints the JSON.
        if let s = parseStatus(Data(r.stdout.utf8)) { return .success(s) }
        return .failure(.command(complaint(r)))
    }

    // MARK: Serve status

    enum PortUse: Equatable {
        case free
        case relay      // HTTPS, and "/" proxies to Relay's port
        case other      // anything else: another app, a TCP forward, a foreground `serve`
    }

    struct ServeStatus: Equatable {
        var ports: [UInt16: PortUse] = [:]
        /// Ports where Funnel (public internet access) is on.
        var funnel: Set<UInt16> = []

        func use(_ port: UInt16) -> PortUse { ports[port] ?? .free }
        var relayPorts: [UInt16] { ports.filter { $0.value == .relay }.map(\.key).sorted() }
    }

    /// Parses `tailscale serve status --json` (a raw ServeConfig; "{}" or "null" when nothing is served).
    static func parseServeStatus(_ data: Data) -> ServeStatus? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "null" { return ServeStatus() }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var status = ServeStatus()

        // Foreground `tailscale serve` sessions (without --bg) hold their ports too; never ours.
        for case let config as [String: Any] in (root["Foreground"] as? [String: Any] ?? [:]).values {
            for key in (config["TCP"] as? [String: Any] ?? [:]).keys { if let p = UInt16(key) { status.ports[p] = .other } }
            for key in (config["Web"] as? [String: Any] ?? [:]).keys { if let p = port(ofHostPort: key) { status.ports[p] = .other } }
        }

        let tcp = root["TCP"] as? [String: Any] ?? [:]
        let web = root["Web"] as? [String: Any] ?? [:]
        var ports = Set(tcp.keys.compactMap { UInt16($0) })
        ports.formUnion(web.keys.compactMap(port(ofHostPort:)))
        for p in ports where status.ports[p] == nil {
            let handler = tcp[String(p)] as? [String: Any] ?? [:]
            let https = handler["HTTPS"] as? Bool ?? false
            let forwards = !(handler["TCPForward"] as? String ?? "").isEmpty
            // The "/" handler of each host on this port; other mounts on the port are left alone.
            let targets = web.filter { port(ofHostPort: $0.key) == p }.compactMap { entry -> String? in
                let handlers = (entry.value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
                return (handlers["/"] as? [String: Any])?["Proxy"] as? String
            }
            status.ports[p] = https && !forwards && !targets.isEmpty && targets.allSatisfy(isRelayTarget) ? .relay : .other
        }
        for (key, value) in root["AllowFunnel"] as? [String: Any] ?? [:] where value as? Bool == true {
            if let p = port(ofHostPort: key) { status.funnel.insert(p) }
        }
        return status
    }

    /// "mac.tail1234.ts.net:443" → 443.
    private static func port(ofHostPort s: String) -> UInt16? {
        s.split(separator: ":").last.flatMap { UInt16($0) }
    }

    /// True for a Serve proxy target that points at Relay's loopback port.
    static func isRelayTarget(_ proxy: String) -> Bool {
        guard let url = URL(string: proxy), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(), host == "127.0.0.1" || host == "localhost",
              url.port == Int(relayPort), url.path.isEmpty || url.path == "/" else { return false }
        return url.user == nil && url.query == nil
    }

    static func serveStatus(cli: String) -> Result<ServeStatus, Failure> {
        let r = run(cli, ["serve", "status", "--json"])
        if r.status == 0, let s = parseServeStatus(Data(r.stdout.utf8)) { return .success(s) }
        return .failure(.command(complaint(r)))
    }

    /// The port Relay serves on: the one it already has, else the one it used last (if still free,
    /// so the phone's address stays the same), else 443, else 8443. Never a port in use by something else.
    static func choosePort(_ serve: ServeStatus, previous: UInt16?) -> Result<(port: UInt16, existing: Bool), Failure> {
        if let p = httpsPorts.first(where: { serve.use($0) == .relay }) ?? serve.relayPorts.first {
            return .success((p, true))
        }
        if let previous, httpsPorts.contains(previous), serve.use(previous) == .free { return .success((previous, false)) }
        if let p = httpsPorts.first(where: { serve.use($0) == .free }) { return .success((p, false)) }
        return .failure(.portsTaken)
    }

    /// The first https://login.tailscale.com/… link the CLI printed (its "enable HTTPS" page).
    static func enableLink(in output: String) -> URL? {
        for word in output.split(whereSeparator: { $0.isWhitespace }) {
            let w = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()<>.,"))
            if w.hasPrefix("https://login.tailscale.com/"), let url = URL(string: w) { return url }
        }
        return nil
    }

    static func url(name: String, port: UInt16) -> URL? {
        URL(string: port == 443 ? "https://\(name)" : "https://\(name):\(port)")
    }

    // MARK: On and off

    enum Step: String, CaseIterable {
        case cli = "Tailscale is installed"
        case connected = "Connected to your tailnet"
        case name = "MagicDNS name"
        case serve = "HTTPS through Tailscale Serve"
    }

    struct Enabled: Equatable {
        var url: URL
        var port: UInt16
        var name: String
        var funnel: Bool
    }

    /// Runs each check in order and stops at the first failure. `progress` hears about each step as it
    /// passes. Blocks (runs the CLI); call off the main thread.
    static func enable(cli: String? = cli(), previousPort: UInt16?,
                       progress: (Step) -> Void = { _ in }) -> Result<Enabled, Failure> {
        guard let cli else { return .failure(.notInstalled) }
        progress(.cli)
        let status: Status
        switch Self.status(cli: cli) {
        case .failure(let f): return .failure(f)
        case .success(let s): status = s
        }
        if let problem = problem(with: status) {
            if problem == .magicDNSOff || problem == .noName { progress(.connected) }
            return .failure(problem)
        }
        progress(.connected)
        guard let name = status.dnsName else { return .failure(.noName) }
        progress(.name)

        let serve: ServeStatus
        switch serveStatus(cli: cli) {
        case .failure(let f): return .failure(f)
        case .success(let s): serve = s
        }
        let choice: (port: UInt16, existing: Bool)
        switch choosePort(serve, previous: previousPort) {
        case .failure(let f): return .failure(f)
        case .success(let c): choice = c
        }
        if !choice.existing {
            let r = run(cli, ["serve", "--bg", "--https=\(choice.port)", target], timeout: 20)
            // Without HTTPS certificates the CLI prints a page to turn them on, then either exits or waits.
            let after = serveStatus(cli: cli)
            guard case .success(let now) = after, now.use(choice.port) == .relay else {
                let output = r.stdout + "\n" + r.stderr
                if let link = enableLink(in: output) { return .failure(.httpsDisabled(link)) }
                let lower = output.lowercased()
                if lower.contains("https") && (lower.contains("not enabled") || lower.contains("disabled") || lower.contains("certificate")) {
                    return .failure(.httpsDisabled(nil))
                }
                if status.certDomains.isEmpty { return .failure(.httpsDisabled(nil)) }
                return .failure(.command(complaint(r)))
            }
        }
        progress(.serve)
        guard let url = url(name: name, port: choice.port) else { return .failure(.noName) }
        return .success(Enabled(url: url, port: choice.port, name: name, funnel: serve.funnel.contains(choice.port)))
    }

    /// Removes Relay's own Serve entries (only the "/" handler that points at Relay). Blocks; call off main.
    @discardableResult
    static func disable(cli: String? = cli()) -> Failure? {
        guard let cli else { return nil }   // nothing Relay could have set up
        let serve: ServeStatus
        switch serveStatus(cli: cli) {
        case .failure(let f): return f
        case .success(let s): serve = s
        }
        for p in serve.relayPorts {
            let r = run(cli, ["serve", "--https=\(p)", "--set-path=/", "off"])
            if r.status != 0 { return .command(complaint(r)) }
        }
        return nil
    }
}
