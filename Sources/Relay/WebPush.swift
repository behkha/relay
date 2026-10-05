import Foundation
import CryptoKit
import Network

/// Web Push to paired phones with CryptoKit only: VAPID (RFC 8292) identifies Relay to the push
/// service, and the payload is encrypted for the phone with aes128gcm (RFC 8291 / RFC 8188), so the
/// push service only ever sees ciphertext.
final class WebPush {
    static let shared = WebPush()

    /// VAPID contact. Apple's push service refuses `mailto:…@localhost` (403 BadJwtToken); a real
    /// https URL is accepted everywhere and says nothing about whose Mac this is.
    static let subject = "https://github.com/behkha/relay"
    static let recordSize: UInt32 = 4096
    static let ttl = 3600

    enum Urgency: String {
        case high, normal
    }

    /// One notification: the JSON the service worker shows, the same with the content hidden (sent
    /// when the push service says the first is too large), its urgency and its replace-key.
    struct Message {
        var payload: Data
        var hiddenPayload: Data
        var urgency: Urgency
        var topic: String
    }

    enum Outcome: Equatable {
        case delivered
        case unsubscribed        // the push service forgot the subscription (404/410); it's deleted
        case queued              // offline; sent when the network is back
        case failed(String)
    }

    // Seams for the self-tests: how a request goes out, how retries wait, and where devices live.
    var transport: (URLRequest, @escaping (Int?, Error?) -> Void) -> Void = WebPush.urlSessionTransport
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    var devices: DeviceStore { devicesOverride ?? .shared }
    var devicesOverride: DeviceStore?
    var keyFile: URL { keyFileOverride ?? Paths.vapid }
    var keyFileOverride: URL?
    /// Retry delays for 429 and 5xx answers.
    var retryDelays: [TimeInterval] = [2, 10, 60]

    private var cachedKey: P256.Signing.PrivateKey?
    private var tokens: [String: (jwt: String, made: Date)] = [:]
    /// Messages waiting for the network, per device (at most 20 each, newest kept).
    private var offline: [String: [Message]] = [:]
    private let monitor = NWPathMonitor()
    private var online = true

    /// `watchNetwork: false` keeps a test instance off the real network state.
    init(watchNetwork: Bool = true) {
        guard watchNetwork else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let was = self.online
                self.online = path.status == .satisfied
                if self.online && !was { self.flush() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "relay.push.path"))
    }

    // MARK: VAPID

    /// Relay's VAPID key, created once and kept in vapid.json (mode 0600). Not in the Keychain: the
    /// ad-hoc signature changes with every build and would make the Keychain ask each time.
    func vapidKey() -> P256.Signing.PrivateKey {
        if let cachedKey { return cachedKey }
        let key = Self.loadKey(keyFile) ?? {
            let k = P256.Signing.PrivateKey()
            let stored = ["privateKey": k.rawRepresentation.base64URLEncodedString(),
                          "publicKey": k.publicKey.x963Representation.base64URLEncodedString()]
            if let data = try? JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted, .sortedKeys]) {
                do { try Secure.write(data, to: keyFile) } catch { NSLog("Relay: couldn't save the push key: \(error)") }
            }
            return k
        }()
        cachedKey = key
        return key
    }

    /// The key the phone passes to `PushManager.subscribe` (applicationServerKey).
    var publicKey: String { vapidKey().publicKey.x963Representation.base64URLEncodedString() }

    static func loadKey(_ url: URL) -> P256.Signing.PrivateKey? {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let raw = json["privateKey"].flatMap({ Data(base64URL: $0) }) else { return nil }
        chmod(url.path, 0o600)
        return try? P256.Signing.PrivateKey(rawRepresentation: raw)
    }

    /// An ES256 JWT for one push service origin, valid 12 hours.
    static func jwt(audience: String, key: P256.Signing.PrivateKey, subject: String = subject, now: Date = Date()) -> String {
        func part(_ object: [String: Any]) -> String {
            ((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()).base64URLEncodedString()
        }
        let input = part(["typ": "JWT", "alg": "ES256"]) + "." +
            part(["aud": audience, "exp": Int(now.timeIntervalSince1970) + 12 * 3600, "sub": subject])
        let signature = (try? key.signature(for: Data(input.utf8)).rawRepresentation) ?? Data()
        return input + "." + signature.base64URLEncodedString()
    }

    /// "https://web.push.apple.com" for an endpoint on that host.
    static func audience(of endpoint: URL) -> String {
        "\(endpoint.scheme ?? "https")://\(endpoint.host ?? "")" + (endpoint.port.map { ":\($0)" } ?? "")
    }

    private func token(for endpoint: URL) -> String {
        let aud = Self.audience(of: endpoint)
        if let t = tokens[aud], Date().timeIntervalSince(t.made) < 30 * 60 { return t.jwt }
        let jwt = Self.jwt(audience: aud, key: vapidKey())
        tokens[aud] = (jwt, Date())
        return jwt
    }

    // MARK: Endpoints

    /// Push services Relay will talk to. A paired phone can't make the Mac POST anywhere else.
    static func allowedEndpoint(_ s: String) -> URL? {
        guard s.count < 2048, let url = URL(string: s), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        let ok = host == "push.apple.com" || host.hasSuffix(".push.apple.com")
            || host == "fcm.googleapis.com" || host == "updates.push.services.mozilla.com"
        return ok ? url : nil
    }

    // MARK: Encryption (RFC 8291)

    struct Keys: Equatable {
        var ikm: Data
        var cek: Data
        var nonce: Data
    }

    /// Key derivation shared by both sides: IKM from the ECDH secret and the auth secret, then the
    /// content key and nonce from IKM and the salt.
    static func deriveKeys(shared: SharedSecret, auth: Data, uaPublic: Data, asPublic: Data, salt: Data) -> Keys {
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(uaPublic)
        keyInfo.append(asPublic)
        let ikm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: auth, sharedInfo: keyInfo, outputByteCount: 32)
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        func bytes(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }
        return Keys(ikm: bytes(ikm), cek: bytes(cek), nonce: bytes(nonce))
    }

    enum CryptoError: Error {
        case badKey, tooLarge, badBody
    }

    /// Encrypts one push message for a subscription (`p256dh` and `auth` from the phone) as a single
    /// aes128gcm record. The salt and sender key are fresh each time; tests pass fixed ones.
    static func encrypt(_ plaintext: Data, p256dh: Data, auth: Data, salt: Data = Secure.randomBytes(16),
                        sender: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()) throws -> Data {
        guard p256dh.count == 65, auth.count == 16, salt.count == 16,
              let uaPublic = try? P256.KeyAgreement.PublicKey(x963Representation: p256dh) else { throw CryptoError.badKey }
        guard plaintext.count + 1 + 16 <= Int(recordSize) else { throw CryptoError.tooLarge }
        let asPublic = sender.publicKey.x963Representation
        let shared = try sender.sharedSecretFromKeyAgreement(with: uaPublic)
        let keys = deriveKeys(shared: shared, auth: auth, uaPublic: p256dh, asPublic: asPublic, salt: salt)
        var padded = plaintext
        padded.append(0x02)   // padding delimiter of the last (only) record
        let sealed = try AES.GCM.seal(padded, using: SymmetricKey(data: keys.cek), nonce: AES.GCM.Nonce(data: keys.nonce))
        var body = salt
        withUnsafeBytes(of: recordSize.bigEndian) { body.append(contentsOf: $0) }
        body.append(UInt8(asPublic.count))
        body.append(asPublic)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        return body
    }

    /// The phone's side, for the self-tests: opens a single-record aes128gcm body.
    static func decrypt(_ body: Data, receiver: P256.KeyAgreement.PrivateKey, auth: Data) throws -> Data {
        let b = [UInt8](body)
        guard b.count > 21 else { throw CryptoError.badBody }
        let idLength = Int(b[20])
        guard b.count >= 21 + idLength + 16 else { throw CryptoError.badBody }
        let salt = Data(b[0..<16])
        let asPublic = Data(b[21..<(21 + idLength)])
        let sealed = Data(b[(21 + idLength)...])
        let sender = try P256.KeyAgreement.PublicKey(x963Representation: asPublic)
        let shared = try receiver.sharedSecretFromKeyAgreement(with: sender)
        let keys = deriveKeys(shared: shared, auth: auth, uaPublic: receiver.publicKey.x963Representation,
                              asPublic: asPublic, salt: salt)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: keys.nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        var padded = try AES.GCM.open(box, using: SymmetricKey(data: keys.cek))
        while padded.last == 0 { padded.removeLast() }
        guard padded.last == 0x02 else { throw CryptoError.badBody }
        padded.removeLast()
        return padded
    }

    // MARK: Sending

    /// Builds the HTTP request for one message (nil when the subscription is unusable).
    func request(_ payload: Data, to sub: PushSubscription, urgency: Urgency, topic: String) -> URLRequest? {
        guard let endpoint = Self.allowedEndpoint(sub.endpoint), let p256dh = Data(base64URL: sub.p256dh),
              let auth = Data(base64URL: sub.auth),
              let body = try? Self.encrypt(payload, p256dh: p256dh, auth: auth) else { return nil }
        var req = URLRequest(url: endpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("vapid t=\(token(for: endpoint)), k=\(publicKey)", forHTTPHeaderField: "Authorization")
        req.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(String(Self.ttl), forHTTPHeaderField: "TTL")
        req.setValue(urgency.rawValue, forHTTPHeaderField: "Urgency")
        req.setValue(topic, forHTTPHeaderField: "Topic")
        return req
    }

    /// Sends to one paired device, following the error rules: 404/410 deletes the subscription,
    /// 413 resends once with the content hidden, 429/5xx retry after 2, 10 and 60 s, and offline
    /// messages wait (up to 20 per device) until the network is back. Main thread.
    func send(_ message: Message, to deviceId: String, completion: ((Outcome) -> Void)? = nil) {
        attempt(message, to: deviceId, retry: 0, hidden: false, completion: completion)
    }

    private func attempt(_ message: Message, to deviceId: String, retry: Int, hidden: Bool, completion: ((Outcome) -> Void)?) {
        guard let sub = devices.device(deviceId)?.pushSubscription else { completion?(.failed("Notifications are off for this device")); return }
        guard online else { enqueue(message, for: deviceId); completion?(.queued); return }
        guard let req = request(hidden ? message.hiddenPayload : message.payload, to: sub,
                                urgency: message.urgency, topic: message.topic) else {
            completion?(.failed("This device's push subscription isn't usable")); return
        }
        transport(req) { [weak self] status, error in
            DispatchQueue.main.async {
                guard let self else { return }
                switch status {
                case let s? where (200..<300).contains(s):
                    completion?(.delivered)
                case 404?, 410?:
                    // Only forget the subscription that failed; the phone may have sent a new one meanwhile.
                    if self.devices.device(deviceId)?.pushSubscription == sub { self.devices.setSubscription(nil, for: deviceId) }
                    completion?(.unsubscribed)
                case 413? where !hidden:
                    self.attempt(message, to: deviceId, retry: retry, hidden: true, completion: completion)
                case let s? where s == 429 || (500..<600).contains(s):
                    guard retry < self.retryDelays.count else {
                        NSLog("Relay: push to \(deviceId) gave up after \(retry) retries (HTTP \(s))")
                        completion?(.failed("The push service kept answering \(s)")); return
                    }
                    self.schedule(self.retryDelays[retry]) {
                        self.attempt(message, to: deviceId, retry: retry + 1, hidden: hidden, completion: completion)
                    }
                case let s?:
                    NSLog("Relay: push to \(deviceId) refused (HTTP \(s))")
                    completion?(.failed("The push service refused it (HTTP \(s))"))
                case nil:
                    if let e = error as? URLError, Self.offlineErrors.contains(e.code) {
                        self.enqueue(message, for: deviceId)
                        completion?(.queued)
                    } else {
                        completion?(.failed(error?.localizedDescription ?? "No answer from the push service"))
                    }
                }
            }
        }
    }

    private static let offlineErrors: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff,
    ]

    private func enqueue(_ message: Message, for deviceId: String) {
        var list = offline[deviceId, default: []].filter { $0.topic != message.topic }   // a newer push replaces an older one
        list.append(message)
        offline[deviceId] = Array(list.suffix(20))
    }

    /// Sends what waited for the network.
    func flush() {
        let waiting = offline
        offline = [:]
        for (id, list) in waiting { list.forEach { send($0, to: id) } }
    }

    /// Network seam for tests (the default never follows redirects: a push service doesn't send any,
    /// and following one could POST to a host outside the allowlist).
    static func urlSessionTransport(_ req: URLRequest, _ done: @escaping (Int?, Error?) -> Void) {
        session.dataTask(with: req) { _, response, error in
            done((response as? HTTPURLResponse)?.statusCode, error)
        }.resume()
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    // MARK: Test helpers

    /// Forgets the offline queue (self-tests only).
    func resetQueue() { offline = [:] }
    func queued(for deviceId: String) -> Int { offline[deviceId]?.count ?? 0 }
    /// Pretends the network went away or came back (self-tests only).
    func setOnline(_ on: Bool) {
        let was = online
        online = on
        if on && !was { flush() }
    }
}
