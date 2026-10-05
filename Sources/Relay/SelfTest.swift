import Foundation
import CryptoKit

/// Checks run by `Relay --self-test` (scripts/selftest.sh). Package.swift has no test target and XCTest
/// isn't guaranteed with only the Command Line Tools, so the app carries its own small harness.
/// It runs before NSApplication, listeners, hooks or UI exist, and only ever touches temp files.
enum SelfTest {
    /// Set first thing in `runAll`, before anything reads `Paths.support`, so the checks get a temp folder.
    private(set) static var isRunning = false
    private static var passed = 0
    private static var failures: [String] = []

    /// Runs every suite and prints a summary. True when all checks passed.
    static func runAll() -> Bool {
        isRunning = true
        // Never run (or clean up) anywhere but the temp sandbox.
        let sandbox = Paths.support
        guard sandbox.lastPathComponent.hasPrefix("relay-selftest-") else {
            print("FAIL sandbox: support folder is \(sandbox.path), not a temp folder")
            return false
        }
        defer { try? FileManager.default.removeItem(at: sandbox) }
        harness()
        remoteAPI()
        devices()
        tailscale()
        tailnetDoor()
        print("\(passed) passed, \(failures.count) failed")
        if !failures.isEmpty { print("Failed: " + failures.joined(separator: ", ")) }
        return failures.isEmpty
    }

    /// Records one check and prints `PASS name` or `FAIL name`. A thrown error counts as a failure.
    static func check(_ name: String, _ condition: @autoclosure () throws -> Bool) {
        do {
            if try condition() {
                passed += 1
                print("PASS \(name)")
            } else {
                failures.append(name)
                print("FAIL \(name)")
            }
        } catch {
            failures.append(name)
            print("FAIL \(name) (\(error))")
        }
    }

    // MARK: - Harness

    private static func harness() {
        check("harness: a true check passes", 1 + 1 == 2)
    }

    // MARK: - Remote API

    private static func remoteAPI() {
        let lan: Set<Capability> = [.read, .answer]
        func allowed(_ method: String, _ path: String, _ caps: Set<Capability>) -> Bool {
            RemoteAPI.capability(method, path).map(caps.contains) ?? false
        }
        check("api: LAN door reads state, sessions and the page",
              allowed("GET", "/api/state", lan) && allowed("GET", "/api/session", lan) && allowed("GET", "/", lan))
        check("api: LAN door answers", allowed("POST", "/api/answer", lan))
        check("api: answering needs the answer capability", !allowed("POST", "/api/answer", [.read]))
        check("api: unknown routes don't exist", RemoteAPI.capability("GET", "/api/nope") == nil
              && RemoteAPI.capability("DELETE", "/api/state") == nil)
        check("api: heat level names", RemoteAPI.heatName(.none) == "none" && RemoteAPI.heatName(.warm) == "warm"
              && RemoteAPI.heatName(.hot) == "hot")

        // The LAN snapshot keeps every field it had and only gains new ones.
        let ws = Workspace(id: "w1", name: "Personal", configDir: nil, colorHex: "#E8A85A")
        var s = AgentSession(id: "s1", workspaceId: "w1", cwd: "/tmp/proj", pid: nil, terminal: TerminalLocation(),
                             status: .working, handle: "claude-1")
        s.lastPrompt = "fix it"
        s.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var perm = InboxItem(sessionId: "s1", workspaceId: "w1", kind: .permission, title: "Run a command", body: "$ ls")
        perm.isLive = true
        perm.toolName = "Bash"
        let snap = RemoteAPI.snapshot(workspaces: [ws], sessions: [s], items: [perm], filter: nil,
                                      heat: ["s1": SessionHeat(cpu: 312.4, level: .hot)], caps: lan)
        let sess = (snap["sessions"] as? [[String: Any]])?.first ?? [:]
        let item = (snap["items"] as? [[String: Any]])?.first ?? [:]
        let oldSessionKeys = ["id", "handle", "path", "status", "statusLabel", "workspaceId", "lastPrompt", "lastMessage"]
        let oldItemKeys = ["id", "sessionId", "workspaceId", "kind", "title", "body", "createdAt", "toolName", "live", "options", "questions"]
        check("api: snapshot keeps the original top-level fields",
              ["workspaces", "sessions", "items", "filter"].allSatisfy { snap[$0] != nil })
        check("api: snapshot keeps the original session and item fields",
              oldSessionKeys.allSatisfy { sess[$0] != nil } && oldItemKeys.allSatisfy { item[$0] != nil }
              && sess["handle"] as? String == "claude-1" && item["options"] as? [String] == ["Yes", "No"])
        check("api: snapshot adds caps, heat and last activity",
              snap["caps"] as? [String] == ["read", "answer"] && sess["cpu"] as? Int == 312
              && sess["heat"] as? String == "hot" && sess["updatedAt"] as? Double == 1_700_000_000_000)
        check("api: snapshot is valid JSON", JSONSerialization.isValidJSONObject(snap))
    }

    // MARK: - Devices

    /// A request signed the way the phone page signs it.
    private static func signedRequest(_ method: String, _ target: String, body: String = "", ts: Date,
                                      key: P256.Signing.PrivateKey, device: String,
                                      login: String? = "ada@example.com") -> HTTPRequest {
        let tsText = String(Int64(ts.timeIntervalSince1970 * 1000))
        let bodyData = Data(body.utf8)
        let message = DeviceStore.signedMessage(method: method, target: target, ts: tsText, body: bodyData)
        let sig = (try? key.signature(for: Data(message.utf8)).rawRepresentation) ?? Data()
        var headers = ["x-relay-device": device, "x-relay-ts": tsText, "x-relay-sig": sig.base64URLEncodedString()]
        if let login { headers["tailscale-user-login"] = login }
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        return HTTPRequest(method: method, path: path, query: [:], headers: headers, body: bodyData,
                           remoteHost: "127.0.0.1", target: target)
    }

    /// n − s on P-256: the other valid signature for the same message (ECDSA malleability).
    private static func malleated(_ raw: Data) -> Data {
        let n: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                          0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51]
        let s = [UInt8](raw.suffix(32))
        var out = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for i in stride(from: 31, through: 0, by: -1) {
            var d = Int(n[i]) - Int(s[i]) - borrow
            borrow = d < 0 ? 1 : 0
            if d < 0 { d += 256 }
            out[i] = UInt8(d)
        }
        return raw.prefix(32) + Data(out)
    }

    private static func devices() {
        let now = Date(timeIntervalSince1970: 1_759_660_000)
        let file = Paths.support.appendingPathComponent("devices-test.json")
        let store = DeviceStore(file: file)
        let key = P256.Signing.PrivateKey()
        let pub = key.publicKey.x963Representation.base64URLEncodedString()
        guard let phone = store.addDevice(name: "Ada's iPhone\u{7}", publicKey: pub, login: "ada@example.com", now: now) else {
            check("devices: pairing stores the device", false); return
        }
        check("devices: pairing stores the device", store.active.count == 1 && store.ownerLogin == "ada@example.com"
              && phone.name == "Ada's iPhone" && phone.id.count == 22)

        func outcome(_ r: HTTPRequest, at t: Date = now) -> Result<Device, DeviceStore.Rejection> { store.check(r, now: t) }
        func rejected(_ r: HTTPRequest, _ why: DeviceStore.Rejection, at t: Date = now) -> Bool {
            if case .failure(let e) = outcome(r, at: t) { return e == why }
            return false
        }

        let ok = signedRequest("GET", "/api/state", ts: now, key: key, device: phone.id)
        check("devices: a valid signature is accepted", (try? outcome(ok).get())?.id == phone.id)
        check("devices: the same request again is a replay", rejected(ok, .replayed))

        var tampered = signedRequest("POST", "/api/answer", body: #"{"action":"dismiss"}"#, ts: now, key: key, device: phone.id)
        tampered.body = Data(#"{"action":"dismisx"}"#.utf8)
        check("devices: a tampered body is rejected", rejected(tampered, .badSignature))
        var moved = signedRequest("GET", "/api/session?id=a", ts: now, key: key, device: phone.id)
        moved.target = "/api/session?id=b"
        check("devices: a tampered path or query is rejected", rejected(moved, .badSignature))
        var otherMethod = signedRequest("GET", "/api/kill", ts: now, key: key, device: phone.id)
        otherMethod.method = "POST"
        check("devices: a tampered method is rejected", rejected(otherMethod, .badSignature))

        for (offset, accepted) in [(-61.0, false), (61, false), (-60, true), (59, true)] {
            let r = signedRequest("GET", "/api/state?n=\(offset)", ts: now.addingTimeInterval(offset), key: key, device: phone.id)
            let result = outcome(r)
            let pass: Bool
            if accepted { pass = (try? result.get()) != nil } else { pass = rejected(r, .staleTimestamp) }
            check("devices: timestamp \(offset > 0 ? "+" : "")\(Int(offset)) s is \(accepted ? "accepted" : "rejected")", pass)
        }
        var badTs = signedRequest("GET", "/api/state", ts: now, key: key, device: phone.id)
        badTs.headers["x-relay-ts"] = "-1759660000000"
        check("devices: a malformed timestamp is rejected", rejected(badTs, .badTimestamp))

        // A captured request can't be replayed by rewriting its signature (s → n − s).
        let fresh = signedRequest("GET", "/api/state?m=1", ts: now, key: key, device: phone.id)
        _ = outcome(fresh)
        var twin = fresh
        let raw = Data(base64URL: fresh.headers["x-relay-sig"] ?? "") ?? Data()
        twin.headers["x-relay-sig"] = malleated(raw).base64URLEncodedString()
        // CryptoKit accepts the rewritten signature, so it's the replay cache that has to catch it.
        check("devices: a malleated signature can't replay a request", rejected(twin, .replayed))

        var short = signedRequest("GET", "/api/state?s=1", ts: now, key: key, device: phone.id)
        short.headers["x-relay-sig"] = Data(repeating: 1, count: 63).base64URLEncodedString()
        check("devices: a signature of the wrong length is rejected", rejected(short, .badSignature))
        let impostor = signedRequest("GET", "/api/state?i=1", ts: now, key: P256.Signing.PrivateKey(), device: phone.id)
        check("devices: another key's signature is rejected", rejected(impostor, .badSignature))

        check("devices: a request without the Tailscale login is rejected",
              rejected(signedRequest("GET", "/api/state?l=1", ts: now, key: key, device: phone.id, login: nil), .noLogin))
        check("devices: a request from another Tailscale login is rejected",
              rejected(signedRequest("GET", "/api/state?l=2", ts: now, key: key, device: phone.id, login: "eve@example.com"), .wrongLogin))
        check("devices: an unknown device is rejected",
              rejected(signedRequest("GET", "/api/state?u=1", ts: now, key: key, device: "nope"), .unknownDevice))

        // Hard-coded vector from WebCrypto (non-extractable ECDSA P-256 key, raw r‖s signature).
        let webStore = DeviceStore(file: Paths.support.appendingPathComponent("devices-webcrypto.json"))
        let webKey = "BOx3iKYdRY4nUAZpsN98DXEemL2Fj7D6FSCuW3R77a6zPDuwe23xyjlOm8NQuWkC82fsTnTC0sdH5hgpa3Ovqsg"
        if let web = webStore.addDevice(name: "WebCrypto", publicKey: webKey, login: "ada@example.com", now: now) {
            let body = #"{"action":"dismiss","itemId":"A1B2"}"#
            check("devices: WebCrypto body hash matches",
                  DeviceStore.signedMessage(method: "POST", target: "/api/answer", ts: "1759660000000", body: Data(body.utf8))
                    .hasSuffix("1f46c23ac6ff02d9a0a8e06242728766eae3fbfcf7a955e25b902e584d498c1f"))
            let req = HTTPRequest(method: "POST", path: "/api/answer", query: [:], headers: [
                "x-relay-device": web.id, "x-relay-ts": "1759660000000",
                "x-relay-sig": "IyR2tqnhMyposEeKnEhIwSj6RvIqwk6j_H92gXD3Iy8xofAY_OxhmHzdWUOaZqXZomJd9MfTxQm5VatGPsJ26g",
                "tailscale-user-login": "ada@example.com",
            ], body: Data(body.utf8), remoteHost: "127.0.0.1", target: "/api/answer")
            check("devices: a WebCrypto signature verifies", webStore.verify(req, now: now)?.id == web.id)
        } else {
            check("devices: the WebCrypto public key parses", false)
        }
        check("devices: invalid public keys are refused",
              DeviceStore.parseKey(Data([0x04] + [UInt8](repeating: 7, count: 64)).base64URLEncodedString()) == nil
              && DeviceStore.parseKey(key.publicKey.compressedRepresentation.base64URLEncodedString()) == nil
              && DeviceStore.parseKey("not base64!") == nil)

        // Owner and revocation.
        check("devices: a second pairing from another login is refused",
              store.pairingProblem(publicKey: pub, login: "eve@example.com") == .otherOwner
              && store.addDevice(name: "Eve", publicKey: pub, login: "eve@example.com", now: now) == nil)
        store.revoke(phone.id)
        check("devices: a revoked device is rejected",
              rejected(signedRequest("GET", "/api/state?r=1", ts: now, key: key, device: phone.id), .unknownDevice))
        check("devices: revoking the last device forgets the owner", store.ownerLogin == nil
              && store.pairingProblem(publicKey: pub, login: "eve@example.com") == nil)

        // The file: 0600, and it reads back the same.
        let mode = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.intValue
        check("devices: devices.json is mode 0600", mode == 0o600)
        let reloaded = DeviceStore(file: file)
        check("devices: devices.json reads back", reloaded.devices == store.devices && reloaded.active.isEmpty)

        // Pairing codes: single use, five minutes.
        let codes = DeviceStore(file: Paths.support.appendingPathComponent("devices-codes.json"))
        let code = codes.newPairingCode(now: now)
        check("devices: a pairing code is 32 random bytes", Data(base64URL: code)?.count == 32)
        check("devices: a wrong pairing code is refused", !codes.consumePairingCode(code + "x", now: now))
        check("devices: the pairing code works once", codes.consumePairingCode(code, now: now.addingTimeInterval(299)))
        check("devices: a used pairing code is refused", !codes.consumePairingCode(code, now: now.addingTimeInterval(1)))
        let late = codes.newPairingCode(now: now)
        check("devices: an expired pairing code is refused", !codes.consumePairingCode(late, now: now.addingTimeInterval(301)))
        let replaced = codes.newPairingCode(now: now)
        _ = codes.newPairingCode(now: now)
        check("devices: a new pairing code replaces the old one", !codes.consumePairingCode(replaced, now: now))

        // More than 20 failures a minute starts a 60 s cool-down.
        let cool = DeviceStore(file: Paths.support.appendingPathComponent("devices-cool.json"))
        for i in 0..<20 { cool.recordFailure(now.addingTimeInterval(Double(i))) }
        check("devices: 20 failures a minute don't cool down", !cool.isCoolingDown(now.addingTimeInterval(20)))
        cool.recordFailure(now.addingTimeInterval(21))
        let coolCode = cool.newPairingCode(now: now.addingTimeInterval(21))
        check("devices: the 21st failure cools down", cool.isCoolingDown(now.addingTimeInterval(22)))
        check("devices: no pairing during the cool-down", !cool.consumePairingCode(coolCode, now: now.addingTimeInterval(22)))
        check("devices: the cool-down ends after 60 s", !cool.isCoolingDown(now.addingTimeInterval(82)))
    }

    // MARK: - Tailscale

    private static func tailscale() {
        func status(_ json: String) -> Tailscale.Status? { Tailscale.parseStatus(Data(json.utf8)) }
        func serve(_ json: String) -> Tailscale.ServeStatus? { Tailscale.parseServeStatus(Data(json.utf8)) }
        func port(_ json: String, previous: UInt16? = nil) -> Result<(port: UInt16, existing: Bool), Tailscale.Failure>? {
            serve(json).map { Tailscale.choosePort($0, previous: previous) }
        }
        func picks(_ json: String, _ expected: UInt16, existing: Bool, previous: UInt16? = nil) -> Bool {
            if case .success(let c)? = port(json, previous: previous) { return c.port == expected && c.existing == existing }
            return false
        }

        let running = """
        {"Version":"1.88.1","TUN":false,"BackendState":"Running","HaveNodeKey":true,"AuthURL":"",
         "TailscaleIPs":["100.101.102.103"],
         "Self":{"ID":"n1","HostName":"Ada's MacBook Pro","DNSName":"adas-macbook-pro.tail1234.ts.net.","Online":true},
         "Health":[],"MagicDNSSuffix":"tail1234.ts.net",
         "CurrentTailnet":{"Name":"ada@example.com","MagicDNSSuffix":"tail1234.ts.net","MagicDNSEnabled":true},
         "CertDomains":["adas-macbook-pro.tail1234.ts.net"],"Peer":{},"User":{}}
        """
        let r = status(running)
        check("tailscale: parses a running status", r?.backendState == "Running" && r?.dnsName == "adas-macbook-pro.tail1234.ts.net"
              && r?.magicDNS == true && r?.certDomains == ["adas-macbook-pro.tail1234.ts.net"])
        check("tailscale: a running status with MagicDNS is usable", r.map(Tailscale.problem(with:)) == .some(nil))
        let stopped = status(#"{"BackendState":"Stopped","Self":{"DNSName":"mac.tail1234.ts.net."},"CertDomains":null,"MagicDNSSuffix":"tail1234.ts.net"}"#)
        check("tailscale: a stopped Tailscale is reported", stopped.flatMap(Tailscale.problem(with:)) == .notRunning("Stopped")
              && stopped?.certDomains == [])
        check("tailscale: a signed-out Tailscale asks to sign in",
              status(#"{"BackendState":"NeedsLogin","Self":null}"#).flatMap(Tailscale.problem(with:)) == .needsLogin)
        check("tailscale: MagicDNS off is reported", status(#"""
            {"BackendState":"Running","Self":{"DNSName":"mac.tail1234.ts.net."},"CurrentTailnet":{"MagicDNSEnabled":false}}
            """#).flatMap(Tailscale.problem(with:)) == .magicDNSOff)
        check("tailscale: no name is reported", status(#"""
            {"BackendState":"Running","Self":{"DNSName":""},"CurrentTailnet":{"MagicDNSEnabled":true}}
            """#).flatMap(Tailscale.problem(with:)) == .noName)
        check("tailscale: garbage isn't a status", status("tailscale: not running") == nil && serve("<html>") == nil)

        let ours = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47902"}}}}}"#
        let foreign443 = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}"#
        check("tailscale: nothing served means 443 is free", picks("{}\n", 443, existing: false) && picks("null\n", 443, existing: false)
              && picks("", 443, existing: false))
        check("tailscale: 443 already Relay's is kept", picks(ours, 443, existing: true) && serve(ours)?.relayPorts == [443])
        check("tailscale: 443 serving something else falls back to 8443",
              picks(foreign443, 8443, existing: false) && serve(foreign443)?.use(443) == .other)
        let both = #"""
            {"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},
             "Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}},
                    "mac.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47902"}}}}}
            """#
        check("tailscale: Relay's existing 8443 entry is kept", picks(both, 8443, existing: true))
        let taken = #"""
            {"TCP":{"443":{"HTTPS":true},"8443":{"TCPForward":"127.0.0.1:22"}},
             "Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Text":"hello"}}}}}
            """#
        if case .failure(let f)? = port(taken) { check("tailscale: 443 and 8443 both taken is refused", f == .portsTaken) }
        else { check("tailscale: 443 and 8443 both taken is refused", false) }
        check("tailscale: a TCP forward on 443 counts as taken",
              serve(#"{"TCP":{"443":{"TCPForward":"127.0.0.1:47902"}}}"#)?.use(443) == .other)
        check("tailscale: a foreground serve on 443 counts as taken", picks(#"""
            {"Foreground":{"abc123":{"TCP":{"443":{"HTTPS":true}},
             "Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47902"}}}}}}}
            """#, 8443, existing: false))
        check("tailscale: other mounts next to Relay's are left alone", serve(#"""
            {"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{
             "/":{"Proxy":"http://127.0.0.1:47902"},"/grafana":{"Proxy":"http://127.0.0.1:3000"}}}}}
            """#)?.use(443) == .relay)
        check("tailscale: the last port used is preferred while free", picks("{}", 8443, existing: false, previous: 8443)
              && picks("{}", 443, existing: false, previous: 9000))
        check("tailscale: Funnel on a port is noticed", serve(#"""
            {"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47902"}}}},
             "AllowFunnel":{"mac.tail1234.ts.net:443":true}}
            """#)?.funnel == [443])
        check("tailscale: Relay's proxy target is recognised", Tailscale.isRelayTarget("http://127.0.0.1:47902")
              && Tailscale.isRelayTarget("http://localhost:47902/") && !Tailscale.isRelayTarget("https://127.0.0.1:47902")
              && !Tailscale.isRelayTarget("http://127.0.0.1:4790") && !Tailscale.isRelayTarget("http://10.0.0.2:47902")
              && !Tailscale.isRelayTarget("http://127.0.0.1:47902/api"))
        let notEnabled = "\nServe is not enabled on your tailnet.\nTo enable, visit:\n\n         https://login.tailscale.com/f/serve?node=nAbC123\n\n"
        check("tailscale: the enable-HTTPS link is found in CLI output",
              Tailscale.enableLink(in: notEnabled)?.absoluteString == "https://login.tailscale.com/f/serve?node=nAbC123"
              && Tailscale.enableLink(in: "error: no such host") == nil)
        check("tailscale: URLs omit the default port",
              Tailscale.url(name: "mac.tail1234.ts.net", port: 443)?.absoluteString == "https://mac.tail1234.ts.net"
              && Tailscale.url(name: "mac.tail1234.ts.net", port: 8443)?.absoluteString == "https://mac.tail1234.ts.net:8443")
        check("tailscale: failures explain themselves", Tailscale.Failure.httpsDisabled(nil).link == Tailscale.adminDNS
              && Tailscale.Failure.notInstalled.link != nil && !Tailscale.Failure.portsTaken.message.isEmpty)

        fakeTailscale(running: running, ours: ours, foreign443: foreign443)
    }

    /// Drives enable() and disable() against a stand-in `tailscale` script that logs every call.
    private static func fakeTailscale(running: String, ours: String, foreign443: String) {
        let dir = Paths.support.appendingPathComponent("fake-tailscale", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cli = dir.appendingPathComponent("tailscale").path
        let script = """
        #!/bin/bash
        D="$(cd "$(dirname "$0")" && pwd)"
        echo "$*" >> "$D/calls.log"
        case "$1 $2" in
          "status --json") cat "$D/status.json"; exit 0 ;;
          "serve status") cat "$D/serve.json" 2>/dev/null || echo "{}"; exit 0 ;;
        esac
        if [ "$1" = serve ] && [ "$2" = --bg ]; then
          [ -f "$D/enable.txt" ] && { cat "$D/enable.txt"; exit 0; }
          cp "$D/after.json" "$D/serve.json"; echo "Available within your tailnet"; exit 0
        fi
        if [ "$1" = serve ] && [ "${@: -1}" = off ]; then cp "$D/off.json" "$D/serve.json"; exit 0; fi
        echo "unexpected: $*" >&2; exit 1
        """
        func put(_ name: String, _ text: String) { try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func reset(serve: String, after: String = "{}", off: String = "{}", enableText: String? = nil) {
            for f in ["calls.log", "serve.json", "enable.txt"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
            put("status.json", running); put("serve.json", serve); put("after.json", after); put("off.json", off)
            if let enableText { put("enable.txt", enableText) }
        }
        func calls() -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        put("tailscale", script)
        chmod(cli, 0o755)

        reset(serve: "{}", after: ours)
        var steps: [Tailscale.Step] = []
        let fresh = Tailscale.enable(cli: cli, previousPort: nil) { steps.append($0) }
        check("tailscale: enable serves Relay on 443", (try? fresh.get())?.url.absoluteString == "https://adas-macbook-pro.tail1234.ts.net"
              && calls().contains("serve --bg --https=443 http://127.0.0.1:47902") && steps == Tailscale.Step.allCases)

        reset(serve: ours)
        let again = Tailscale.enable(cli: cli, previousPort: 443)
        check("tailscale: enable keeps an entry Relay already has", (try? again.get())?.port == 443
              && !calls().contains { $0.hasPrefix("serve --bg") })

        let ours8443 = foreign443.replacingOccurrences(of: #"}}}}}"#, with: #"}}},"mac.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47902"}}}}}"#)
            .replacingOccurrences(of: #""443":{"HTTPS":true}"#, with: #""443":{"HTTPS":true},"8443":{"HTTPS":true}"#)
        reset(serve: foreign443, after: ours8443)
        let fallback = Tailscale.enable(cli: cli, previousPort: nil)
        check("tailscale: enable leaves a foreign 443 alone and uses 8443",
              (try? fallback.get())?.url.absoluteString == "https://adas-macbook-pro.tail1234.ts.net:8443"
              && calls().contains("serve --bg --https=8443 http://127.0.0.1:47902")
              && !calls().contains { $0.contains("--https=443") })

        reset(serve: "{}", enableText: "\nServe is not enabled on your tailnet.\nTo enable, visit:\n\n         https://login.tailscale.com/f/serve?node=nTEST\n\n")
        if case .failure(.httpsDisabled(let link)) = Tailscale.enable(cli: cli, previousPort: nil) {
            check("tailscale: HTTPS certificates off links to the page that turns them on",
                  link?.absoluteString == "https://login.tailscale.com/f/serve?node=nTEST")
        } else {
            check("tailscale: HTTPS certificates off links to the page that turns them on", false)
        }

        reset(serve: ours8443, off: foreign443)
        check("tailscale: disable removes only Relay's entry", Tailscale.disable(cli: cli) == nil
              && calls().filter { $0.hasSuffix(" off") } == ["serve --https=8443 --set-path=/ off"])
        reset(serve: foreign443)
        check("tailscale: disable never touches a foreign entry", Tailscale.disable(cli: cli) == nil
              && !calls().contains { $0.hasSuffix(" off") })

        put("status.json", #"{"BackendState":"Stopped","Self":{"DNSName":"mac.tail1234.ts.net."}}"#)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("calls.log"))
        check("tailscale: enable stops at a stopped Tailscale", Tailscale.enable(cli: cli, previousPort: nil) == .failure(.notRunning("Stopped"))
              && calls() == ["status --json"])
        check("tailscale: enable without the CLI says to install it", Tailscale.enable(cli: nil, previousPort: nil) == .failure(.notInstalled))
    }

    // MARK: - Tailnet door (over real HTTP)

    private struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    /// Sends one request and keeps the main run loop turning meanwhile, since the server hops to it.
    private static func http(_ method: String, _ port: UInt16, _ target: String, headers: [String: String] = [:],
                             body: Data? = nil) -> Reply {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(target)")!)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        var reply: Reply?
        session.dataTask(with: req) { data, response, _ in
            let r = response as? HTTPURLResponse
            var h: [String: String] = [:]
            for (k, v) in r?.allHeaderFields ?? [:] { h[String(describing: k).lowercased()] = String(describing: v) }
            let result = Reply(status: r?.statusCode ?? -1, headers: h, body: data ?? Data())
            DispatchQueue.main.async { reply = result }
        }.resume()
        let deadline = Date().addingTimeInterval(15)
        while reply == nil && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return reply ?? Reply(status: -1, headers: [:], body: Data())
    }

    /// The headers a phone sends for a signed request (as the page builds them).
    private static func signedHeaders(_ method: String, _ target: String, body: Data = Data(), key: P256.Signing.PrivateKey,
                                      device: String, login: String? = "ada@example.com", ts: Date = Date()) -> [String: String] {
        let r = signedRequest(method, target, body: String(decoding: body, as: UTF8.self), ts: ts, key: key, device: device, login: login)
        var h = ["X-Relay-Device": r.headers["x-relay-device"]!, "X-Relay-Ts": r.headers["x-relay-ts"]!,
                 "X-Relay-Sig": r.headers["x-relay-sig"]!]
        if let login { h["Tailscale-User-Login"] = login }
        if !body.isEmpty { h["Content-Type"] = "application/json" }
        return h
    }

    private static func tailnetDoor() {
        let store = Store()
        let devices = DeviceStore(file: Paths.support.appendingPathComponent("devices-door.json"))
        let door = TailnetServer(api: RemoteAPI(store: store), devices: devices)
        var allow = true
        var asked: [(String, String, String)] = []
        door.confirmPairing = { name, login, fingerprint, done in
            asked.append((name, login, fingerprint))
            DispatchQueue.main.async { done(allow) }
            return {}
        }
        door.notify = { _ in }
        do { try door.start(port: 0) } catch {
            check("door: listens on an ephemeral loopback port", false); return
        }
        defer { door.stop() }
        let port = door.port
        check("door: listens on an ephemeral loopback port", port > 0)

        let second = TailnetServer(api: RemoteAPI(store: store), devices: devices)
        check("door: a busy port is an error, never a fallback", (try? second.start(port: port)) == nil && !second.isRunning)

        let page = http("GET", port, "/")
        check("door: the page is served without a device", page.status == 200
              && page.headers["content-security-policy"]?.contains("frame-ancestors 'none'") == true
              && page.headers["x-frame-options"] == "DENY")
        check("door: the API needs a signature", http("GET", port, "/api/state").status == 401
              && http("POST", port, "/api/answer", body: Data("{}".utf8)).status == 401)
        check("door: Funnel traffic is refused", http("GET", port, "/", headers: ["Tailscale-Funnel-Request": "?1"]).status == 403)

        let key = P256.Signing.PrivateKey()
        let pub = key.publicKey.x963Representation.base64URLEncodedString()
        func pairBody(_ code: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["code": code, "publicKey": pub, "deviceName": "Test iPhone"])
        }
        let code = devices.newPairingCode()
        check("door: pairing with a wrong code is refused",
              http("POST", port, "/api/pair", headers: ["Tailscale-User-Login": "ada@example.com"], body: pairBody("nope")).status == 401)
        check("door: pairing that didn't come through Tailscale Serve is refused",
              http("POST", port, "/api/pair", body: pairBody(code)).status == 401 && asked.isEmpty)
        let paired = http("POST", port, "/api/pair", headers: ["Tailscale-User-Login": "ada@example.com"], body: pairBody(code))
        let deviceId = paired.json["deviceId"] as? String ?? ""
        check("door: pairing asks on the Mac and returns the device", paired.status == 200 && devices.device(deviceId) != nil
              && asked.count == 1 && asked.first?.1 == "ada@example.com"
              && asked.first?.2 == TailnetServer.fingerprint(pub) && asked.first?.2.count == 9)
        check("door: a pairing code works only once",
              http("POST", port, "/api/pair", headers: ["Tailscale-User-Login": "ada@example.com"], body: pairBody(code)).status == 401)

        let state = http("GET", port, "/api/state", headers: signedHeaders("GET", "/api/state", key: key, device: deviceId))
        check("door: a signed request gets the full API", state.status == 200
              && state.json["caps"] as? [String] == ["read", "answer", "control"])
        check("door: a request updates last seen", devices.device(deviceId)?.lastSeen != nil)
        let replayed = signedHeaders("GET", "/api/session?id=nope", key: key, device: deviceId)
        let first = http("GET", port, "/api/session?id=nope", headers: replayed)
        check("door: the signature covers the query", first.status == 404 && first.json["ok"] as? Bool == false)
        check("door: a replayed request is refused", http("GET", port, "/api/session?id=nope", headers: replayed).status == 401)
        check("door: another Tailscale login is refused", http("GET", port, "/api/state",
              headers: signedHeaders("GET", "/api/state", key: key, device: deviceId, login: "eve@example.com")).status == 401)
        var funnel = signedHeaders("GET", "/api/state", key: key, device: deviceId)
        funnel["Tailscale-Funnel-Request"] = "?1"
        check("door: Funnel traffic is refused even when signed", http("GET", port, "/api/state", headers: funnel).status == 403)

        allow = false
        let denyCode = devices.newPairingCode()
        let other = P256.Signing.PrivateKey().publicKey.x963Representation.base64URLEncodedString()
        let denied = http("POST", port, "/api/pair", headers: ["Tailscale-User-Login": "ada@example.com"],
                          body: try! JSONSerialization.data(withJSONObject: ["code": denyCode, "publicKey": other, "deviceName": "x"]))
        check("door: pairing denied on the Mac stores nothing", denied.status == 403 && devices.active.count == 1)
    }
}
