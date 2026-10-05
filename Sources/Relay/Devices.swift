import Foundation
import CryptoKit

/// Which pushes a paired device wants, and whether they may show what the agent said.
struct PushPrefs: Codable, Equatable {
    var blocked = true        // an agent asks a question or needs permission
    var finished = true       // an agent finished its turn
    var fire = true           // an agent is heating up the Mac
    var hideContent = false   // "An agent needs you" instead of the agent's words

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? true
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? true
        fire = try c.decodeIfPresent(Bool.self, forKey: .fire) ?? true
        hideContent = try c.decodeIfPresent(Bool.self, forKey: .hideContent) ?? false
    }
}

/// Where Web Push reaches one device (from `PushManager.subscribe` on the phone).
struct PushSubscription: Codable, Equatable {
    var endpoint: String
    var p256dh: String   // the browser's P-256 public key, base64url (65 bytes)
    var auth: String     // its auth secret, base64url (16 bytes)
}

/// A phone paired over Tailscale. Its private key never leaves the phone; Relay keeps the public half.
struct Device: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// Uncompressed P-256 point (X9.63, 65 bytes), base64url.
    var publicKey: String
    /// The Tailscale login that paired it. Every request must arrive through Tailscale Serve as this login.
    var ownerLogin: String
    var pairedAt: Date
    var lastSeen: Date?
    var revoked = false
    var pushSubscription: PushSubscription?
    var pushPrefs = PushPrefs()

    init(id: String, name: String, publicKey: String, ownerLogin: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.ownerLogin = ownerLogin
        self.pairedAt = pairedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        publicKey = try c.decode(String.self, forKey: .publicKey)
        ownerLogin = try c.decode(String.self, forKey: .ownerLogin)
        pairedAt = try c.decode(Date.self, forKey: .pairedAt)
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        // A record that can't say whether it was revoked is treated as revoked.
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked) ?? true
        pushSubscription = try c.decodeIfPresent(PushSubscription.self, forKey: .pushSubscription)
        pushPrefs = try c.decodeIfPresent(PushPrefs.self, forKey: .pushPrefs) ?? PushPrefs()
    }
}

/// Paired devices (devices.json, mode 0600), one-time pairing codes, and the signature check every
/// tailnet request goes through. Main thread only.
///
/// Anyone on the tailnet can reach the tailnet URL, and any local process can reach the loopback port
/// and forge headers. So a request is trusted only when a paired device signed it; the Tailscale
/// identity header that Serve adds is a second factor on top.
final class DeviceStore: ObservableObject {
    static let shared = DeviceStore(file: Paths.devices)

    @Published private(set) var devices: [Device] = []
    /// Fixed by the first pairing; later pairings must come from the same Tailscale login.
    /// Forgotten once no paired device is left.
    @Published private(set) var ownerLogin: String?
    /// When the code the Mac is showing stops working (nil when there is none).
    @Published private(set) var pairingExpires: Date?

    static let codeLifetime: TimeInterval = 5 * 60
    static let maxClockSkew: TimeInterval = 60
    /// A signature stays usable for up to twice the clock skew (stamped a minute ahead, used a minute
    /// late), so it is remembered a little longer than that.
    static let replayWindow: TimeInterval = 2 * maxClockSkew + 5
    /// More failures than this within a minute starts the cool-down.
    static let failureLimit = 20
    static let coolDown: TimeInterval = 60

    private let file: URL
    private var code: Data?
    /// Replay cache: hash of each accepted signed message, with when it was seen.
    private var seen: [String: Date] = [:]
    /// Recent failures and cool-downs per Tailscale login ("" when a request had none), so one
    /// person on the tailnet can't lock another out of pairing.
    private var failures: [String: [Date]] = [:]
    private var coolDownUntil: [String: Date] = [:]

    init(file: URL) {
        self.file = file
        load()
    }

    /// Paired devices that haven't been revoked.
    var active: [Device] { devices.filter { !$0.revoked } }

    func device(_ id: String) -> Device? {
        devices.first { $0.id == id && !$0.revoked }
    }

    // MARK: Pairing codes

    /// A new single-use code for the QR on the Mac (32 random bytes, valid 5 minutes). Replaces any earlier one.
    func newPairingCode(now: Date = Date()) -> String {
        let c = Secure.randomBytes(32).base64URLEncodedString()
        code = Data(c.utf8)
        pairingExpires = now.addingTimeInterval(Self.codeLifetime)
        return c
    }

    func cancelPairingCode() {
        code = nil
        pairingExpires = nil
    }

    /// True once for the current code while it is valid; it can't be used again after that.
    /// Wrong and expired codes count as failures of `login`.
    func consumePairingCode(_ given: String, login: String = "", now: Date = Date()) -> Bool {
        guard !isCoolingDown(now, login: login), let code, let expires = pairingExpires else {
            recordFailure(now, login: login)
            return false
        }
        if now > expires {
            cancelPairingCode()
            recordFailure(now, login: login)
            return false
        }
        guard Secure.equal(Data(given.utf8), code) else {
            recordFailure(now, login: login)
            return false
        }
        cancelPairingCode()
        return true
    }

    // MARK: Pairing

    enum PairingProblem: Error, Equatable {
        case badKey        // not an uncompressed P-256 public key
        case otherOwner    // a different Tailscale login than the devices already paired
    }

    /// Checked before the Mac asks you about a pairing, and again when it is stored.
    func pairingProblem(publicKey: String, login: String) -> PairingProblem? {
        guard Self.parseKey(publicKey) != nil else { return .badKey }
        if let owner = ownerLogin, owner != login { return .otherOwner }
        return nil
    }

    /// Stores a device you allowed on the Mac.
    @discardableResult
    func addDevice(name: String, publicKey: String, login: String, now: Date = Date()) -> Device? {
        guard !login.isEmpty, pairingProblem(publicKey: publicKey, login: login) == nil else { return nil }
        let device = Device(id: Secure.randomBytes(16).base64URLEncodedString(), name: Self.cleanName(name),
                            publicKey: publicKey, ownerLogin: login, pairedAt: now)
        devices.append(device)
        ownerLogin = login
        save()
        return device
    }

    /// A device name for the Mac's prompt and lists: no control characters, at most 40 characters.
    static func cleanName(_ name: String) -> String {
        let t = printable(name, max: 40)
        return t.isEmpty ? "Phone" : t
    }

    /// Text from a request, safe to show on the Mac: no control characters (no line breaks to restyle
    /// a prompt with), trimmed, at most `max` characters.
    static func printable(_ s: String, max: Int) -> String {
        let scalars = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }

    static func parseKey(_ base64: String) -> P256.Signing.PublicKey? {
        guard let raw = Data(base64URL: base64), raw.count == 65, raw.first == 0x04 else { return nil }
        return try? P256.Signing.PublicKey(x963Representation: raw)
    }

    // MARK: Request verification

    enum Rejection: Error, Equatable {
        case unknownDevice, badTimestamp, staleTimestamp, badSignature, replayed, noLogin, wrongLogin
    }

    /// What a device signs: `method \n path?query \n ts \n hex(sha256(body))`.
    static func signedMessage(method: String, target: String, ts: String, body: Data) -> String {
        "\(method)\n\(target)\n\(ts)\n\(Data(SHA256.hash(data: body)).hexString)"
    }

    /// The device that signed this request, when it passes every check.
    func verify(_ req: HTTPRequest, now: Date = Date()) -> Device? {
        if case .success(let device) = check(req, now: now) { return device }
        return nil
    }

    /// Runs the checks in order and counts a failure toward the cool-down.
    func check(_ req: HTTPRequest, now: Date = Date()) -> Result<Device, Rejection> {
        let result = evaluate(req, now: now)
        if case .failure = result { recordFailure(now, login: req.header("tailscale-user-login") ?? "") }
        return result
    }

    private func evaluate(_ req: HTTPRequest, now: Date) -> Result<Device, Rejection> {
        // 1. A paired device that hasn't been revoked.
        guard let device = device(req.header("x-relay-device") ?? "") else { return .failure(.unknownDevice) }

        // 2. Signed within a minute of now, either way (clocks drift).
        let ts = req.header("x-relay-ts") ?? ""
        guard (1...16).contains(ts.count), ts.allSatisfy({ $0.isASCII && $0.isNumber }), let ms = Double(ts) else {
            return .failure(.badTimestamp)
        }
        guard abs(now.timeIntervalSince1970 - ms / 1000) <= Self.maxClockSkew else { return .failure(.staleTimestamp) }

        // 3. ECDSA P-256 / SHA-256 by the device's key. WebCrypto signs in raw r‖s form.
        let message = Self.signedMessage(method: req.method, target: req.target, ts: ts, body: req.body)
        guard let key = Self.parseKey(device.publicKey),
              let raw = Data(base64URL: req.header("x-relay-sig") ?? ""), raw.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              key.isValidSignature(signature, for: Data(message.utf8)) else {
            return .failure(.badSignature)
        }

        // 4. Not seen before. Keyed by what was signed rather than the signature bytes, because one
        //    ECDSA signature can be turned into a second valid one (s → n − s).
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.replayWindow }
        let fingerprint = Data(SHA256.hash(data: Data((device.id + "\n" + message).utf8))).hexString
        guard seen[fingerprint] == nil else { return .failure(.replayed) }
        seen[fingerprint] = now

        // 5. Came through Tailscale Serve (which sets this header and drops any the client sent)
        //    as the login that paired the device.
        guard let login = req.header("tailscale-user-login"), !login.isEmpty else { return .failure(.noLogin) }
        guard login == device.ownerLogin else { return .failure(.wrongLogin) }
        return .success(device)
    }

    // MARK: Failures

    /// Only the last `failureLimit + 1` failures of a login matter, so a flood costs constant work per
    /// request (this runs on the main thread).
    func recordFailure(_ now: Date = Date(), login: String = "") {
        var list = failures[login, default: []]
        list.append(now)
        if list.count > Self.failureLimit + 1 { list.removeFirst(list.count - Self.failureLimit - 1) }
        failures[login] = list
        if list.count > Self.failureLimit, let oldest = list.first, now.timeIntervalSince(oldest) < 60 {
            coolDownUntil[login] = now.addingTimeInterval(Self.coolDown)
        }
        // Logins a local process makes up can't grow this without bound.
        if failures.count > 64 {
            failures = failures.filter { $0.key == login || now.timeIntervalSince($0.value.last ?? .distantPast) < 60 }
            coolDownUntil = coolDownUntil.filter { $0.value > now }
            if failures.count > 64 { failures = [login: list] }
        }
    }

    /// During a login's cool-down the tailnet door won't pair anything for it. Signed requests from
    /// paired devices aren't affected, so nobody can lock the owner out of their phone.
    func isCoolingDown(_ now: Date = Date(), login: String = "") -> Bool {
        coolDownUntil[login].map { now < $0 } ?? false
    }

    // MARK: Changes

    /// Records when a device last made a request (written at most every 30 s).
    func touch(_ id: String, now: Date = Date()) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        if let last = devices[i].lastSeen, now.timeIntervalSince(last) < 30, now >= last { return }
        devices[i].lastSeen = now
        save()
    }

    /// Ends a device's access and deletes its push subscription.
    func revoke(_ id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].revoked = true
        devices[i].pushSubscription = nil
        if active.isEmpty { ownerLogin = nil }
        save()
    }

    func revokeAll() {
        for i in devices.indices {
            devices[i].revoked = true
            devices[i].pushSubscription = nil
        }
        ownerLogin = nil
        cancelPairingCode()
        save()
    }

    func setSubscription(_ subscription: PushSubscription?, for id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id && !$0.revoked }) else { return }
        devices[i].pushSubscription = subscription
        save()
    }

    func setPrefs(_ prefs: PushPrefs, for id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id && !$0.revoked }) else { return }
        devices[i].pushPrefs = prefs
        save()
    }

    // MARK: File

    private struct Stored: Codable {
        var ownerLogin: String?
        var devices: [Device]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        chmod(file.path, 0o600)   // tighten a copy restored with looser permissions
        guard let stored = try? Self.decoder.decode(Stored.self, from: data) else {
            NSLog("Relay: \(file.lastPathComponent) is unreadable; no devices are paired until you pair again")
            return
        }
        devices = stored.devices
        ownerLogin = devices.contains { !$0.revoked } ? stored.ownerLogin : nil
    }

    private func save() {
        guard let data = try? Self.encoder.encode(Stored(ownerLogin: ownerLogin, devices: devices)) else { return }
        do { try Secure.write(data, to: file) } catch { NSLog("Relay: couldn't save \(file.lastPathComponent): \(error)") }
    }
}
