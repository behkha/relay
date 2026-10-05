import Foundation

/// A file an agent made for you: a page it published with the Artifact tool, or a file it sent with
/// SendUserFile. Read from the session's transcript, so the phone can open it while you're away.
struct ArtifactRef: Equatable {
    var id: String          // stable per file path
    var path: String
    var title: String
    var url: String?        // the claude.ai link of a published artifact
    var caption: String?
    var createdAt: Date

    enum Kind: String { case html, markdown, image, pdf, text, other }
    var kind: Kind { Self.kind(of: path) }

    static func kind(of path: String) -> Kind {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return .html
        case "md", "markdown": return .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return .image
        case "pdf": return .pdf
        case "txt", "json", "csv", "tsv", "log", "yaml", "yml", "xml", "swift", "js", "ts", "py", "sh", "css": return .text
        default: return .other
        }
    }

    static func id(for path: String) -> String {
        // FNV-1a: stable across launches (Swift's hashValue isn't), short enough for a URL.
        var h: UInt64 = 0xcbf29ce484222325
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 36)
    }
}

/// Finds artifacts in Claude Code transcripts. Transcripts only grow, so each one is read once and then
/// only its new lines; work happens off the main thread and callers get the last result right away.
final class ArtifactIndex {
    static let shared = ArtifactIndex()

    private struct Entry {
        var offset: UInt64 = 0
        var pending: [String: (name: String, input: [String: Any])] = [:]
        var refs: [ArtifactRef] = []
        var refreshing = false
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "relay.artifacts", qos: .utility)

    /// The artifacts found so far, newest first; reads any new lines in the background.
    func cached(_ path: String?) -> [ArtifactRef] {
        guard let path else { return [] }
        lock.lock()
        let entry = entries[path] ?? Entry()
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
        let stale = size.map { $0 != entry.offset } ?? false
        if stale && !entry.refreshing {
            var e = entry
            e.refreshing = true
            entries[path] = e
            queue.async { [weak self] in self?.refresh(path) }
        }
        lock.unlock()
        return entry.refs
    }

    /// Reads the transcript up to now and returns the result (call off the main thread).
    func current(_ path: String?) -> [ArtifactRef] {
        guard let path else { return [] }
        refresh(path)
        lock.lock(); defer { lock.unlock() }
        return entries[path]?.refs ?? []
    }

    private func refresh(_ path: String) {
        lock.lock()
        var e = entries[path] ?? Entry()
        lock.unlock()
        defer {
            lock.lock()
            e.refreshing = false
            entries[path] = e
            lock.unlock()
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < e.offset { e = Entry() }   // rewritten: start over
        guard size > e.offset else { return }
        try? handle.seek(toOffset: e.offset)
        let data = handle.readData(ofLength: Int(size - e.offset))
        // Only whole lines; a line still being written is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let chunk = data[data.startIndex...lastNewline]
        e.offset += UInt64(chunk.count)
        Self.scan(chunk, pending: &e.pending, refs: &e.refs)
    }

    /// Adds the artifacts in these transcript lines to `refs` (newest first, one per file).
    static func scan(_ data: Data, pending: inout [String: (name: String, input: [String: Any])], refs: inout [ArtifactRef]) {
        for raw in data.split(separator: 0x0A) {
            let line = String(decoding: raw, as: UTF8.self)
            let isCall = line.contains("\"Artifact\"") || line.contains("\"SendUserFile\"")
            let isResult = !pending.isEmpty && pending.keys.contains { line.contains($0) }
            guard isCall || isResult,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    guard let name = block["name"] as? String, name == "Artifact" || name == "SendUserFile",
                          let id = block["id"] as? String else { continue }
                    pending[id] = (name, block["input"] as? [String: Any] ?? [:])
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String, let call = pending.removeValue(forKey: id),
                          block["is_error"] as? Bool != true else { continue }
                    let when = (obj["timestamp"] as? String).flatMap(parseDate) ?? Date()
                    let result = obj["toolUseResult"] as? [String: Any] ?? [:]
                    for ref in artifacts(call: call.name, input: call.input, result: result, at: when) {
                        add(ref, to: &refs)
                    }
                default:
                    continue
                }
            }
        }
    }

    private static func artifacts(call: String, input: [String: Any], result: [String: Any], at when: Date) -> [ArtifactRef] {
        if call == "Artifact" {
            // Only page publishes; reads, lists, deletes and asset uploads aren't things to look at.
            let action = input["action"] as? String ?? "publish"
            guard action == "publish", input["asset"] as? Bool != true,
                  let path = (result["path"] as? String) ?? (input["file_path"] as? String), path.hasPrefix("/") else { return [] }
            let title = (result["title"] as? String) ?? (input["title"] as? String) ?? (path as NSString).lastPathComponent
            return [ArtifactRef(id: ArtifactRef.id(for: path), path: path, title: title,
                                url: (result["url"] as? String).flatMap(claudeURL),
                                caption: input["description"] as? String, createdAt: when)]
        }
        let caption = (result["caption"] as? String) ?? (input["caption"] as? String)
        let paths: [String] = ((result["attachments"] as? [[String: Any]])?.compactMap { $0["path"] as? String })
            ?? (input["files"] as? [String]) ?? []
        return paths.filter { $0.hasPrefix("/") }.map {
            ArtifactRef(id: ArtifactRef.id(for: $0), path: $0, title: ($0 as NSString).lastPathComponent,
                        url: nil, caption: caption, createdAt: when)
        }
    }

    /// Keeps one entry per file: the newest, with the last claude.ai link it had.
    private static func add(_ ref: ArtifactRef, to refs: inout [ArtifactRef]) {
        var ref = ref
        if let i = refs.firstIndex(where: { $0.path == ref.path }) {
            let old = refs.remove(at: i)
            if ref.url == nil { ref.url = old.url }
            if ref.caption == nil { ref.caption = old.caption }
        }
        refs.insert(ref, at: 0)
        if refs.count > 50 { refs.removeLast(refs.count - 50) }
    }

    /// Only links to claude.ai artifacts are passed on to the phone.
    static func claudeURL(_ s: String) -> String? {
        guard let u = URL(string: s), u.scheme == "https", u.host == "claude.ai", u.path.contains("/artifact/") else { return nil }
        return s
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    static func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }
}

/// Short-lived links that let the phone open one artifact file. The phone's own requests are signed
/// (or carry the LAN token), but an <iframe> or <img> can't add those, so it asks for a ticket first.
/// A ticket names one file, works for 10 minutes, and is 32 random bytes.
final class ArtifactTickets {
    static let shared = ArtifactTickets()
    static let ttl: TimeInterval = 600
    static let maxBytes = 25 * 1024 * 1024
    static let prefix = "/view/"

    private var tickets: [String: (path: String, expires: Date)] = [:]
    private let lock = NSLock()
    var now: () -> Date = Date.init

    func issue(path: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let ticket = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        lock.lock(); defer { lock.unlock() }
        let t = now()
        tickets = tickets.filter { $0.value.expires > t }
        if tickets.count >= 100, let oldest = tickets.min(by: { $0.value.expires < $1.value.expires }) { tickets.removeValue(forKey: oldest.key) }
        tickets[ticket] = (path, t.addingTimeInterval(Self.ttl))
        return ticket
    }

    /// The file a `/view/<ticket>[/name]` path may read, if the ticket is valid.
    func path(for urlPath: String) -> String? {
        guard urlPath.hasPrefix(Self.prefix) else { return nil }
        let ticket = urlPath.dropFirst(Self.prefix.count).split(separator: "/").first.map(String.init) ?? ""
        lock.lock(); defer { lock.unlock() }
        guard let entry = tickets[ticket], entry.expires > now() else { return nil }
        return entry.path
    }

    /// Serves `/view/<ticket>`. Pages and anything that could run script are served under a CSP
    /// sandbox: they get an opaque origin, so an artifact can't read the phone page's storage
    /// (the device key, the LAN token) or call Relay's API, even if opened on its own.
    func response(for urlPath: String) -> HTTPResponse {
        guard let path = path(for: urlPath) else { return .text("This link expired. Open the artifact again.", status: 404) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil,
              size <= Self.maxBytes, let data = FileManager.default.contents(atPath: path) else {
            return .text("That file isn't on the Mac anymore.", status: 404)
        }
        var r = HTTPResponse(status: 200, contentType: Self.contentType(path), body: data)
        r.extraHeaders = Self.headers(for: path)
        return r
    }

    static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        default:
            // Everything else is shown as text, never run or sniffed into something that runs.
            return ArtifactRef.kind(of: path) == .other ? "application/octet-stream" : "text/plain; charset=utf-8"
        }
    }

    static func headers(for path: String) -> [String: String] {
        var h = [
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "X-Frame-Options": "SAMEORIGIN",
            "Cache-Control": "no-store",
        ]
        // Plain images and PDFs can't run script; a sandbox would only stop PDF viewers from working.
        let inert = ["png", "jpg", "jpeg", "gif", "webp", "pdf"].contains((path as NSString).pathExtension.lowercased())
        h["Content-Security-Policy"] = inert
            ? "frame-ancestors 'self'"
            : "sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox allow-forms allow-modals allow-downloads; frame-ancestors 'self'"
        if contentType(path) == "application/octet-stream" {
            h["Content-Disposition"] = "attachment; filename=\"\((path as NSString).lastPathComponent.replacingOccurrences(of: "\"", with: ""))\""
        }
        return h
    }
}
