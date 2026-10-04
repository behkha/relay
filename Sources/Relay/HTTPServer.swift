import Foundation
import Network

/// A parsed HTTP/1.1 request.
struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]   // lowercased keys
    var body: Data
    var remoteHost: String?

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
    var status: Int = 200
    var contentType: String = "application/json"
    var body: Data = Data()
    var extraHeaders: [String: String] = [:]

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func encodable<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func text(_ s: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, contentType: type, body: Data(s.utf8))
    }

    static let empty = HTTPResponse(status: 200, contentType: "application/json", body: Data())
    static let notFound = HTTPResponse.text("not found", status: 404)
    static let unauthorized = HTTPResponse.text("unauthorized", status: 401)
}

/// Minimal HTTP server on top of Network.framework. One request per connection.
/// Handlers may complete asynchronously (used for long-polling hook decisions).
final class HTTPServer {
    typealias Handler = (HTTPRequest, HTTPExchange) -> Void

    private var listener: NWListener?
    private let queue: DispatchQueue
    private let handler: Handler
    private let localOnly: Bool
    private let maxBody: Int
    /// Optional gate on the peer address, checked before anything is parsed.
    var acceptPeer: ((String?) -> Bool)?
    private(set) var port: UInt16 = 0

    init(label: String, localOnly: Bool, maxBody: Int = 32 << 20, handler: @escaping Handler) {
        self.queue = DispatchQueue(label: "relay.http.\(label)")
        self.localOnly = localOnly
        self.maxBody = maxBody
        self.handler = handler
    }

    /// Starts on the preferred port, falling back to any free port.
    func start(preferredPort: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if localOnly {
            params.requiredInterfaceType = .loopback
        }
        var l: NWListener
        do {
            l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: preferredPort) ?? .any)
        } catch {
            l = try NWListener(using: params, on: .any)
        }
        let ready = DispatchSemaphore(value: 0)
        var failed: Error?
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = l.port?.rawValue ?? 0
                ready.signal()
            case .failed(let e):
                failed = e
                ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        if let failed {
            l.cancel()
            if preferredPort != 0 {
                try start(preferredPort: 0)
                return
            }
            throw failed
        }
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        if let acceptPeer, !acceptPeer(Self.host(of: conn.endpoint)) {
            conn.cancel()
            return
        }
        conn.start(queue: queue)
        // Drop connections that never finish sending a request.
        let parsed = ParsedFlag()
        queue.asyncAfter(deadline: .now() + 30) { if !parsed.value { conn.cancel() } }
        receive(conn, buffer: Data(), parsed: parsed)
    }

    private final class ParsedFlag { var value = false }

    private func receive(_ conn: NWConnection, buffer: Data, parsed: ParsedFlag) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > self.maxBody + 64 * 1024 { conn.cancel(); return }
            switch Self.parse(buf, remote: conn.endpoint, maxBody: self.maxBody) {
            case .request(let req):
                parsed.value = true
                let exchange = HTTPExchange(queue: self.queue) { resp in
                    self.send(resp, on: conn)
                }
                self.watchForClose(conn, exchange: exchange)
                self.handler(req, exchange)
            case .bad:
                parsed.value = true
                self.send(.text("bad request", status: 400), on: conn)
            case .incomplete:
                if isComplete || error != nil { conn.cancel(); return }
                self.receive(conn, buffer: buf, parsed: parsed)
            }
        }
    }

    static func host(of endpoint: NWEndpoint) -> String? {
        if case .hostPort(let h, _) = endpoint {
            switch h {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            case .name(let n, _): return n
            @unknown default: return nil
            }
        }
        return nil
    }

    /// Detects the client hanging up while a response is still pending (e.g. the hook was killed).
    private func watchForClose(_ conn: NWConnection, exchange: HTTPExchange) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            if isComplete || error != nil || data == nil {
                exchange.clientClosed()
                conn.cancel()   // release the socket; nothing will ever be sent on it
            } else {
                self?.watchForClose(conn, exchange: exchange)
            }
        }
    }

    private func send(_ resp: HTTPResponse, on conn: NWConnection) {
        var head = "HTTP/1.1 \(resp.status) \(Self.reason(resp.status))\r\n"
        head += "Content-Type: \(resp.contentType)\r\n"
        head += "Content-Length: \(resp.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for (k, v) in resp.extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(resp.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    enum ParseResult {
        case incomplete
        case bad
        case request(HTTPRequest)
    }

    /// Returns a request once headers and the full body (per Content-Length) are buffered.
    static func parse(_ data: Data, remote: NWEndpoint?, maxBody: Int) -> ParseResult {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: sep) else {
            return data.count > 64 * 1024 ? .bad : .incomplete
        }
        guard let headText = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8) else { return .bad }
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .bad }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .bad }
        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        if headers["transfer-encoding"] != nil { return .bad }   // chunked bodies aren't supported
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= maxBody else { return .bad }
        let bodyStart = range.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]

        let target = String(requestLine[1])
        var path = target
        var query: [String: String] = [:]
        if let comps = URLComponents(string: target) {
            path = comps.path
            for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        return .request(HTTPRequest(method: String(requestLine[0]), path: path, query: query,
                                    headers: headers, body: Data(body), remoteHost: remote.flatMap(host(of:))))
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        default: return "Status"
        }
    }
}

/// One request/response pair. `respond` may be called once, from any thread.
final class HTTPExchange {
    private let queue: DispatchQueue
    private let sender: (HTTPResponse) -> Void
    private let lock = NSLock()
    private var done = false
    private var clientGone = false
    private var closeHandlers: [() -> Void] = []

    init(queue: DispatchQueue, sender: @escaping (HTTPResponse) -> Void) {
        self.queue = queue
        self.sender = sender
    }

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return done }

    func respond(_ response: HTTPResponse) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        closeHandlers.removeAll()
        lock.unlock()
        queue.async { self.sender(response) }
    }

    /// Called if the client disconnects before a response was sent.
    /// Runs right away when the client already hung up before the handler was registered.
    func onClientClose(_ handler: @escaping () -> Void) {
        lock.lock()
        if clientGone { lock.unlock(); handler(); return }
        if !done { closeHandlers.append(handler) }
        lock.unlock()
    }

    fileprivate func clientClosed() {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        clientGone = true
        let handlers = closeHandlers
        closeHandlers.removeAll()
        lock.unlock()
        handlers.forEach { $0() }
    }
}
