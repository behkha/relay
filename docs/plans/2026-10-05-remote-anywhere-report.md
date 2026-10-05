# Remote anywhere: implementation report

Spec: [docs/specs/2026-10-05-remote-anywhere-design.md](../specs/2026-10-05-remote-anywhere-design.md)
Plan: [docs/plans/2026-10-05-remote-anywhere-plan.md](2026-10-05-remote-anywhere-plan.md)
Branch: `remote-anywhere`, one commit per task, not pushed. Date: 2026-10-05.

`tmux` and `tailscale` are not installed on the build Mac and no iPhone was available, so everything that needs them was tested against stand-ins (a fake `tailscale` script, `/bin/sh` in place of tmux, a mock server in a browser) and the end-to-end check on a real phone is the checklist at the end.

## What was built

| Task | What |
| --- | --- |
| 1 | `Relay --self-test` (checked before `NSApplication` is touched, so no listener, hook install or UI ever starts) and `scripts/selftest.sh`. The checks run in a temp support folder (guarded: they refuse to run if it isn't one), and the HTTP ones use an ephemeral loopback port, never 47823/47901/47902. |
| 2 | `RemoteAPI.swift`: the phone API both doors share. Each route needs a capability (read, answer, control); a route a door doesn't allow answers 404 like one that doesn't exist. The LAN door keeps its token check and passes read + answer. The snapshot gained `caps` and per-session `cpu`, `heat` and `updatedAt`. |
| 3 | `Devices.swift`: `DeviceStore` (devices.json written 0600 through a 0600 temp file and an atomic rename), 32-byte single-use pairing codes valid 5 minutes, `verify()` with the spec's five checks in order, the replay cache and the failure cool-down. |
| 4 | `Tailscale.swift`: CLI discovery (PATH, then `/Applications/Tailscale.app/Contents/MacOS/Tailscale`), `status --json` and `serve status --json` parsing, `enable()` and `disable()` with a typed, user-facing error per step. |
| 5 | `TailnetServer.swift`: the loopback door on exactly 127.0.0.1:47902 (no fallback), `POST /api/pair` with a confirmation on the Mac, and `RemoteAccess`, which turns the listener and the Serve entry on and off together (`tailnetEnabled`). |
| 6 | `WebPush.swift`: VAPID ES256 JWTs with a key in vapid.json (0600), RFC 8291 `aes128gcm` with CryptoKit, the endpoint allowlist, and the delivery rules (404/410 drop, 413 resend hidden, 429/5xx at 2/10/60 s, offline queue of 20 per device flushed by `NWPathMonitor`). |
| 7 | `PushDispatcher` (in WebPush.swift), called next to `Notifier.notify`: away from the Mac it pushes at once, otherwise after 45 s if still unanswered; per-device toggles, Hide content, 32-character topics, fire pushes at most once per agent per 10 minutes, nothing in demo mode. Device routes: push subscribe/unsubscribe/prefs/test, device/forget. |
| 8 | Remote start and kill: `Launcher.newDetachedTmux`, known and pinned folders, `X-Relay-Launch` in both hook header lists, pending launches that turn into the real session or, after 30 s, into an error row with the pane's last lines; routes folders, start, kill, terminal, launch/dismiss; Mac toasts. |
| 9 | `remote.html` for both doors (signing, pairing, Inbox/Agents tabs, heat badges, Stop with confirm + 2 s undo, New agent sheet, terminal view, device sheet, deep links, notification cleanup, unreachable banner, polling only while visible), `sw.js`, `manifest.webmanifest`, and 192/512 PNG icons from `build.sh`. |
| 10 | Settings → Phone: the Tailscale toggle with each step, the address, Pair a device (QR, countdown, copyable link), paired devices with Revoke / Revoke all, pinned folders, the keep-awake toggle. The LAN controls are unchanged. |
| 11 | `PowerAssertion.swift`: holds `PreventUserIdleSystemSleep` only while enabled and an agent works or is blocked. |
| 12 | README: "Phone, anywhere (Tailscale)" (requirements, setup, security model, push privacy), feature tour, diagram, source map, Relay vs. One. |
| 13 | Verification, an independent security review of the whole branch, fixes, this report. |

Package.swift is unchanged: still one target and no dependencies. New system frameworks: CryptoKit, Network, IOKit.pwr_mgt, CoreGraphics.

## How it was verified

- **Builds.** A clean `swift build -c release --arch arm64` (after deleting `.build`) succeeds after every task. The only warning is the existing one in `Demo.swift`.
- **Self-tests.** `scripts/selftest.sh`: 211 checks, all PASS (output below). Highlights:
  - The RFC 8291 §5 example encrypts to the published body and the body decrypts; all Appendix A values (ECDH secret, IKM, CEK, nonce) match.
  - The VAPID JWT decodes and verifies.
  - A signature made by WebCrypto (Node's implementation, non-extractable P-256 key) verifies.
  - The tailnet door is driven over real HTTP on an ephemeral port: pairing, signatures, replay, the Tailscale login, Funnel, the API, push and control routes. The Host rule is checked through direct handler calls, because URLSession always sends its own Host.
  - `Tailscale.enable/disable` run against a stand-in `tailscale` script that logs every call.
  - The tmux launch script runs under `/bin/sh` with hostile prompts and folder names; a canary file proves nothing in them ran.
  - The keep-awake assertion is really created and released (checked with `IOPMCopyAssertionsByProcess`).
- **Phone page in a real browser.** `remote.html` was served by a mock backend with the same hash-based CSP and driven in a Chromium pane. Flows exercised:
  - pairing, with the fingerprint shown;
  - the inbox (an agent's `<script>` stays text);
  - answering, the session sheet and the terminal view;
  - Stop: undo cancels it, waiting 2 s sends it;
  - the New agent sheet: pinned folders first, mode, the instant "Starting…" row, dismissing a failed row;
  - the device sheet and a preference toggle;
  - `#item=` and `#session=` deep links;
  - revoked-device handling and retry;
  - an old pairing link once paired;
  - Forget;
  - the iOS "install first" and paste-a-link screens (spoofed user agent);
  - LAN mode (token, no signatures, control hidden).

  All 115 signed requests the page made were verified afterwards with CryptoKit using the server's message format, including POST bodies with non-ASCII text, query strings, and timestamps that strictly increase. No console errors appeared under the CSP.
- **Mac UI.** The Phone pane and the pairing sheet were rendered offscreen in a scratch harness and inspected. The non-modal pairing prompt was exercised in a scratch AppKit harness:
  - the main queue keeps running while it's up;
  - Deny is the default button;
  - Allow and withdraw each resolve exactly once;
  - a login containing newlines can't restyle the text.
- **Hook script.** `relay-hook.sh` was run against a local listener (with `HOME` pointed at a temp dir): `X-Relay-Launch` is sent on the normal and the `Wait` paths, and the `Wait` path still delivers a message and exits 2. `bash -n` passes.
- **App bundle.** `scripts/build.sh` (without `--install`) assembles and signs `build/Relay.app`. `Contents/Resources` holds `relay-hook.sh`, `remote.html`, `sw.js`, `manifest.webmanifest`, `icon-192.png` (192×192), `icon-512.png` (512×512) and `AppIcon.icns`, identical to the sources. The installed app was not touched and the real app was never launched.

## Self-test output

```text
PASS harness: a true check passes
PASS api: LAN door reads state, sessions and the page
PASS api: LAN door answers
PASS api: answering needs the answer capability
PASS api: unknown routes don't exist
PASS api: heat level names
PASS api: snapshot keeps the original top-level fields
PASS api: snapshot keeps the original session and item fields
PASS api: snapshot adds caps, heat and last activity
PASS api: snapshot is valid JSON
PASS devices: pairing stores the device
PASS devices: a valid signature is accepted
PASS devices: the same request again is a replay
PASS devices: a tampered body is rejected
PASS devices: a tampered path or query is rejected
PASS devices: a tampered method is rejected
PASS devices: timestamp -61 s is rejected
PASS devices: timestamp +61 s is rejected
PASS devices: timestamp -60 s is accepted
PASS devices: timestamp +59 s is accepted
PASS devices: a request stamped a minute ahead can't be replayed two minutes later
PASS devices: a malformed timestamp is rejected
PASS devices: a malleated signature can't replay a request
PASS devices: a signature of the wrong length is rejected
PASS devices: another key's signature is rejected
PASS devices: a request without the Tailscale login is rejected
PASS devices: a request from another Tailscale login is rejected
PASS devices: an unknown device is rejected
PASS devices: WebCrypto body hash matches
PASS devices: a WebCrypto signature verifies
PASS devices: invalid public keys are refused
PASS devices: a second pairing from another login is refused
PASS devices: a revoked device is rejected
PASS devices: revoking the last device forgets the owner
PASS devices: devices.json is mode 0600
PASS devices: devices.json reads back
PASS devices: a pairing code is 32 random bytes
PASS devices: a wrong pairing code is refused
PASS devices: the pairing code works once
PASS devices: a used pairing code is refused
PASS devices: an expired pairing code is refused
PASS devices: a new pairing code replaces the old one
PASS devices: 20 failures a minute don't cool down
PASS devices: the 21st failure cools down
PASS devices: no pairing during the cool-down
PASS devices: the cool-down ends after 60 s
PASS devices: one login's failures don't stop another's pairing
PASS devices: 21 failures spread over 80 s don't cool down
PASS devices: a flood of failures costs constant work each
PASS tailscale: parses a running status
PASS tailscale: a running status with MagicDNS is usable
PASS tailscale: a stopped Tailscale is reported
PASS tailscale: a signed-out Tailscale asks to sign in
PASS tailscale: MagicDNS off is reported
PASS tailscale: no name is reported
PASS tailscale: garbage isn't a status
PASS tailscale: nothing served means 443 is free
PASS tailscale: 443 already Relay's is kept
PASS tailscale: 443 serving something else falls back to 8443
PASS tailscale: Relay's existing 8443 entry is kept
PASS tailscale: 443 and 8443 both taken is refused
PASS tailscale: a TCP forward on 443 counts as taken
PASS tailscale: a foreground serve on 443 counts as taken
PASS tailscale: Relay next to other mounts counts as shared and isn't used
PASS tailscale: the last port used is preferred while free
PASS tailscale: Funnel on a port is noticed
PASS tailscale: Relay's proxy target is recognised
PASS tailscale: the enable-HTTPS link is found in CLI output
PASS tailscale: URLs omit the default port
PASS tailscale: failures explain themselves
PASS tailscale: enable serves Relay on 443
PASS tailscale: enable keeps an entry Relay already has
PASS tailscale: enable leaves a foreign 443 alone and uses 8443
PASS tailscale: HTTPS certificates off links to the page that turns them on
PASS tailscale: enable moves off a port shared with other web apps
PASS tailscale: disable removes only Relay's entry
PASS tailscale: disable never touches a foreign entry
PASS tailscale: enable stops at a stopped Tailscale
PASS tailscale: enable without the CLI says to install it
PASS door: listens on an ephemeral loopback port
PASS door: a busy port is an error, never a fallback
PASS door: only *.ts.net Host headers are answered
PASS door: a request for another Host is refused
PASS door: a login with control characters can't pair
PASS door: pairing during a cool-down says to wait
PASS door: the page is served without a device
PASS door: the page's scripts are allowed by hash, never inline at large
PASS door: API responses allow no scripts
PASS door: the API needs a signature
PASS door: Funnel traffic is refused
PASS door: pairing with a wrong code is refused
PASS door: pairing that didn't come through Tailscale Serve is refused
PASS door: pairing asks on the Mac and returns the device
PASS door: a pairing code works only once
PASS door: a signed request gets the full API
PASS door: a request updates last seen
PASS door: the signature covers the query
PASS door: a replayed request is refused
PASS door: another Tailscale login is refused
PASS door: Funnel traffic is refused even when signed
PASS door: pairing denied on the Mac stores nothing
PASS door: a push subscription outside the allowlist is refused
PASS door: a push subscription with bad keys is refused
PASS door: a push subscription is stored
PASS door: push preferences are stored
PASS door: a test push reaches the push service, hidden when asked
PASS door: state describes the calling device
PASS door: notifications can be turned off
PASS door: a device can unpair itself
PASS door: an unpaired device is refused
PASS control: folders lists where agents run
PASS control: start refuses a folder Relay doesn't know
PASS control: start refuses mode "bypassPermissions"
PASS control: start refuses mode "dangerously-skip-permissions"
PASS control: start refuses mode "auto"
PASS control: start refuses mode ""
PASS control: start launches in a known folder
PASS control: state shows the Starting… row
PASS control: state says which agents can be killed or have a terminal
PASS control: the agent's hook claims its row
PASS control: an agent Relay can't stop isn't killed
PASS control: only tmux agents have a terminal view
PASS control: a launch row can be dismissed
PASS api: device routes don't exist without a device
PASS api: the LAN door can't start agents
PASS limits: idle connections count against the cap
PASS limits: past the cap, connections are refused
PASS limits: connections that send nothing are dropped after the deadline
PASS limits: the tailnet door caps connections and waits 10 s for a request
PASS push: RFC 8291 keys match the example
PASS push: RFC 8291 intermediate values match (ECDH, IKM, CEK, nonce)
PASS push: RFC 8291 example encrypts to the published body
PASS push: RFC 8291 published body decrypts
PASS push: a message round-trips with fresh keys
PASS push: two encryptions of one message differ (fresh salt and key)
PASS push: a payload larger than one record is refused
PASS push: a tampered body doesn't decrypt
PASS push: the VAPID key is saved 0600 and reloads
PASS push: the JWT header is ES256
PASS push: the JWT claims name the push service, 12 h and an https contact
PASS push: the JWT signature verifies
PASS push: known push services are allowed
PASS push: https://push.apple.com.evil.test/x is refused
PASS push: http://web.push.apple.com/x is refused
PASS push: https://evilpush.apple.com/x is refused
PASS push: https://web.push.apple.com:8443/x is refused
PASS push: https://user:pw@web.push.apple.com/x is refused
PASS push: https://fcm.googleapis.com.evil.test/x is refused
PASS push: https://127.0.0.1/x is refused
PASS push: https://[::1]/x is refused
PASS push: ftp://web.push.apple.com/x is refused
PASS push: https://web.push.apple.com./x is refused
PASS push: https://evil.test#@web.push.apple.com/ is refused
PASS push: https://evil.test/?.push.apple.com is refused
PASS push: web.push.apple.com/x is refused
PASS push: an empty endpoint is refused
PASS push: https://127.0.0.1%00.push.apple.com/x is refused
PASS push: https://evil.com%2F.push.apple.com/x is refused
PASS push: https://web.push.apple.com%2E/x is refused
PASS push: https://web.push.apple.com\@evil.test/x is refused
PASS push: https://.push.apple.com/x is refused
PASS push: https://a..push.apple.com/x is refused
PASS pu2026-10-05 16:37:16.688 Relay[64855:9154306] Relay: push to RMT4TKOcOFCWQQthjHiaYw refused (HTTP 413)
PASS push: the request carries VAPID, TTL, urgency, topic and aes128gcm
PASS push: the push service gets ciphertext the phone can open
PASS push: 413 resends once with the content hidden
PASS push: 413 twice gives up
PASS push: 429 and 5xx retry after 2 and 10 s
PASS push: 5xx gives up after retries at 2, 10 and 60 s
PASS push: other refusals aren't retried
PASS push: offline pushes queue, at most 20 per device
PASS push: queued pushes go out when the network is back
PASS push: a network error queues the push
PASS push: a queued push follows Hide content as it is when it goes out
PASS push: 410 forgets the subscription
PASS push: no subscription, no request
PASS push: a subscription outside the allowlist is never contacted
PASS timing: away from the Mac, a question goes out right away to devices that want it
PASS timing: payload is {title, body ≤ 120, itemId, sessionId, kind}
PASS timing: the topic is 32 base64url characters, one per item
PASS timing: finished turns go to devices that want them, normal urgency
PASS timing: hide content sends only "An agent needs you"
PASS timing: every push carries a hidden version for 413
PASS timing: at the Mac, a push waits 45 s
PASS timing: still unanswered after 45 s, it goes out
PASS timing: answered at the desk, nothing goes out
PASS timing: an MCP elicitation counts as blocked
PASS timing: an idle agent counts as finished
PASS timing: on fire goes out once to devices that want it
PASS timing: not again within 10 minutes
PASS timing: an agent that cooled down in the 45 s isn't pushed
PASS start: a known folder and mode are accepted
PASS start: an unknown folder is refused
PASS start: bypassing permissions is refused
PASS start: an unknown workspace is refused
PASS start: a prompt with a NUL byte is refused
PASS start: tmux runs /bin/sh -c directly with no start directory
PASS start: a hostile prompt arrives as one argument after --
PASS start: nothing in the prompt or folder ran
PASS start: a prompt can't pass itself off as a flag
PASS start: a one-word prompt isn't taken for a claude command
PASS start: Default is passed explicitly, so settings can't pick another mode
PASS start: no prompt, only the mode
PASS start: the workspace's account is used
PASS awake: needed while an agent works
PASS awake: needed while an agent is blocked on you
PASS awake: needed while background tasks run
PASS awake: not needed when agents are done, ready or idle
PASS awake: the assertion is held
PASS awake: holding twice keeps one assertion
PASS awake: the assertion is released
211 passed, 0 failed
```

## Deviations from the spec

1. **VAPID `sub` is `https://github.com/behkha/relay`, not `mailto:relay@localhost`.** Apple's push service answers `403 BadJwtToken` for `@localhost` subjects. Other projects report exactly this, with `mailto:x@localhost` refused and https subjects accepted. An https URL works everywhere and reveals nothing about the user.
2. **Idle time uses `kCGAnyInputEventType` (`CGEventType(rawValue: ~0)`), not `.null`.** Measured on this Mac: `.null` reported 231,446 s while the user was active, any-input reported 390 s.
3. **The replay cache is keyed by device + signed message, not signature bytes.** CryptoKit accepts the malleated twin (r, n−s) of an ECDSA signature (20/20 in a probe), so a cache keyed by signature bytes could be bypassed. The cache also lasts 125 s instead of 120 s: a request stamped +60 s is otherwise replayable at exactly +120 s.
4. **Pairing happens inside the Home Screen app.** iOS keeps a Home Screen app's IndexedDB separate from Safari's, so a key made in Safari is useless to the installed app. Changes:
   - `/pair` in Safari on iOS walks through installing first.
   - `/pair` serves a manifest without `start_url`, so the installed app opens on the pairing link.
   - The app can paste a link instead (Copy pairing link on the page, or Universal Clipboard from the Mac's sheet).
   - A "pair this tab instead" escape exists.
5. **tmux gets `new-session -d -s relay-<id> -x 120 -y 40 /bin/sh -c <script>`, not `-c <folder> '<cmd>'`.** tmux format-expands `-c` (and `#(…)` runs a command), and a single command string runs through your default shell, where `Shell.quote`'s quoting isn't valid (fish: a crafted prompt breaks out). With separate arguments tmux calls `execvp` with no expansion, and the script does `cd` itself.
6. **The prompt's argument is hardened beyond "quoted":**
   - It follows `--`.
   - A one-word prompt gets a trailing space, because the claude CLI would otherwise run it as a command: `purge`, `rm`, `update` and `install` exist.
   - A prompt never starts with `-`.
   - The mode is always passed, `--permission-mode default` included, because without it a `permissions.defaultMode` in a settings file (possibly `bypassPermissions`) would apply.
   - If claude exits within 30 s, the pane stays up 2 minutes so the error row can show why.
7. **Pairing confirmation:**
   - It shows a key fingerprint (the first 4 bytes of SHA-256, "1A2B-3C4D") that the phone also shows.
   - Deny is the default button, and the prompt times out after 2 minutes.
   - It's withdrawn if the phone stops waiting or remote access is turned off.
   - It's a floating, non-modal alert: `runModal` from a main-queue block stalled every other main-queue block (hooks, the API), as the review confirmed.
8. **The cool-down:**
   - It counts per Tailscale login and pauses only pairing; requests signed by paired devices are never blocked.
   - Otherwise anyone on the tailnet could keep the owner from pairing, and a global flood would add nothing against 256-bit codes.
   - The failure list is bounded, so a flood costs constant work.
   - Pairing during a cool-down gets a 429 that says to wait.
9. **The owner login is forgotten once no paired device is left.** The spec only says the first pairing fixes it, which would leave a revoked-only list stuck on an old account.
10. **Port choice:**
    - It prefers Relay's existing entry, then the last port it used, so an installed app's origin stays the same; only then 443, then 8443.
    - A port where Relay's `/` sits next to other mounts counts as shared. Relay removes its own handler there and moves, because other apps on the same origin could use the phone's stored key.
11. **Turning off runs `serve --https=<port> --set-path=/ off`, not `serve --https=<port> off`.** The latter removes every handler on the port, and asks for confirmation when there are several.
12. **Additions the spec didn't list:**
    - Funnel traffic and requests whose Host isn't `*.ts.net` are refused.
    - The tailnet door holds at most 32 connections with a 10 s request deadline.
    - Every inline handler was removed from `remote.html` so the tailnet door can serve a CSP that allows only the page's script, by hash.
    - The listener binds 127.0.0.1 itself and accepts only loopback peers.
    - Pairing without the Tailscale login gets a 403 that explains why.
    - Logins with control characters are refused.
13. **Extra routes the UI needed:** `/api/push/unsubscribe`, `/api/device/forget`, `/api/launch/dismiss`, `/pair.webmanifest`. The test push returns the push service's answer.
14. **Push details:**
    - An MCP elicitation ("Needs input in the terminal") counts as blocked; an idle "Waiting for you" counts as finished.
    - Fire pushes follow the same away/45 s rule and are skipped if the agent cooled down.
    - Hide content also hides the title (`Relay` / `An agent needs you`).
    - Hide content is applied when the push goes out, so it covers queued and retried pushes.
    - Titles are capped at 80 characters.
15. **Known folders come from:**
    - live sessions' working directories;
    - the folders sessions start in, remembered per workspace in `recentFolders` (Relay kept no folder history before);
    - pinned folders.
16. **The LAN page also stops polling while hidden** (the spec's network rule); its API is unchanged apart from the new fields.
17. **RFC 8291 erratum:** the §5 example says `Content-Length: 145`; the body is 144 bytes (the test checks the bytes).

## Security review

Two passes over `git diff main...HEAD` against the spec's threat model: my own, and an independent read-only review. Neither found a way to get an authenticated response or change state without a valid device signature. Fixed:

| Severity | Finding | Fix |
| --- | --- | --- |
| Medium | No cap on concurrent connections. Through Serve (one backend connection per request; HTTP/2 lets one client hold about 250 streams with unsent bodies), any tailnet peer could use up the app's 256 file descriptors and stall hooks and file writes. Reproduced against the server with `ulimit -n 256`. | `HTTPServer.maxConnections` (32 on the tailnet door) and `requestTimeout` (10 s there). Self-test: connections past the cap are refused, and idle ones are dropped at the deadline. |
| Low | `NSAlert.runModal()` inside `DispatchQueue.main.async` blocked every other main-queue block (hook events, the API, push) for up to 2 minutes, and withdrawing the prompt never ran. | Non-modal floating alert with targeted buttons; `withdrawAll()` when remote access turns off; the pairing completes only if the door is still running. |
| Low | Anyone (or a DNS-rebinding page) could keep pairing in cool-down. | Per-login failure buckets; signed traffic is never blocked; a 429 that says what to do. |
| Low | Quadratic main-thread cost of the failure counter under a flood (6.4 s CPU for 60,000 failures a minute). | Bounded list, constant work per failure. Self-test: 200,000 failures in under 2 s. |
| Low | "Default" mode passed no flag, so `permissions.defaultMode` from settings (even `bypassPermissions`) could apply. | `--permission-mode` is always passed and quoted; `newDetachedTmux` re-checks the mode. |
| Hardening | `URL.host` decodes percent escapes, so `https://127.0.0.1%00.push.apple.com/` passed the allowlist. URLSession refused it, so it wasn't exploitable. | The host must be plain `[a-z0-9.-]` as written; the URL used is the one validated; redirects aren't followed. |
| Hardening | Replay at exactly +120 s for a request stamped +60 s. | The window is 125 s. |
| Hardening | Other Serve mounts on Relay's port share the page's origin and could use the stored key. | Such ports count as shared; Relay moves off them. |
| Hardening | No Host check (DNS rebinding from a browser on the Mac). | Only `*.ts.net` hosts are answered (421 otherwise). |
| Hardening | The login was shown unsanitized in the prompt (a bare `\n` could restyle it). | Logins with control characters are refused; display text is sanitized. |
| Hardening | When someone else used the code first, the phone's error dropped its fingerprint. | The error says to Deny any prompt whose code isn't this phone's, and shows it. |
| Hardening | Pushes queued offline kept their content after Hide content was turned on. | Hide content is applied when a push goes out. |

Checked and fine:
- **Routes.** Only `GET /`, `/pair`, `/pair.webmanifest`, the four PWA files and `POST /api/pair` are open.
- **Signatures and routing.** The signature covers method, the raw request target, the timestamp and the body hash, and routing derives from the same target. `Transfer-Encoding` gets a 400; one request per connection, so no request smuggling.
- **Pairing codes.** Single use, consumed before the prompt, constant-time compare. The owner is enforced.
- **tmux.** Checked against upstream source: no shell, no format expansion of the command, no `-c`, and the script never ends in `;`.
- **XSS.** Every server string is escaped; the markdown renderer escapes first and allows only http(s) links; no inline handlers remain.
- **Files.** 0600 throughout. An unreadable devices.json fails closed, and a stored device without a `revoked` field counts as revoked.
- **LAN door.** The token check still runs first, and control, push and device routes are 404 there.
- **Revoked devices** get no pushes.

## Manual iPhone test checklist

Prerequisites:
- Tailscale on the Mac and the iPhone, signed in to the same tailnet.
- MagicDNS and HTTPS certificates on (admin console → DNS).
- `brew install tmux` on the Mac.
- `scripts/build.sh --install`, then open Relay.

Turn on and pair:
1. Settings → Phone → Allow phone access over Tailscale. All four steps check, and the `https://…ts.net` address appears. `tailscale serve status` shows 443 → `http://127.0.0.1:47902`.
   - [ ] With something else already served on 443, Relay uses 8443 and leaves 443 alone.
   - [ ] With HTTPS certificates off, the message links to the page that turns them on.
2. Pair a device, then scan with the iPhone Camera, with Wi-Fi off so it goes over cellular.
   - [ ] Safari shows "Install Relay, then pair". Share → Add to Home Screen → open Relay from the Home Screen.
   - [ ] The app shows "Pair this iPhone". If it opened without the code, Copy pairing link in Safari and paste it in the app.
   - [ ] The Mac asks "Pair “iPhone” with Relay?" with your Tailscale login and the same code the phone shows. Allow. The phone opens the inbox.

Notifications:

3. [ ] Tap Enable notifications and allow it. The device sheet says On, and Send test push arrives.
4. [ ] Lock the phone and step away from the Mac for more than 60 s, or lock the Mac. Have an agent ask for a permission. The push arrives. Tapping it opens that card; Yes lets the agent continue. The next time the app opens, that notification is gone.
5. [ ] At the Mac: answer within 45 s and no push arrives. Leave it unanswered and the push arrives after 45 s.
6. [ ] Turn on Hide content. The push reads "Relay / An agent needs you".

Start, read and stop agents:

7. [ ] The Agents tab shows heat badges ("312% CPU") and last activity.
8. [ ] Tap +, pick a workspace and a pinned or recent folder, type a prompt with quotes, `;` and `$()`, choose Plan, and Start.
   - "Starting…" appears and turns into the agent within seconds.
   - `tmux ls` on the Mac shows `relay-<id>`.
   - The agent runs in plan mode with the exact prompt.
9. [ ] Start an agent with a one-word prompt such as `update`. It becomes the prompt; claude does not run `claude update`.
10. [ ] Open the agent, then Terminal: its pane shows read-only and refreshes. Send a message from the box and it reaches the agent.
11. [ ] Stop → confirm → Undo within 2 s keeps the agent. Stop again: the agent ends and the Mac shows "iPhone stopped @…".
12. [ ] Without tmux, the New agent sheet explains how to install it. With a workspace that isn't signed in, the row turns into an error with the pane's text after 30 s.

Losing and removing access:

13. [ ] Revoke the device on the Mac. The phone shows "Not paired anymore". Pair again.
14. [ ] Forget this device on the phone; it disappears from the Mac's list.
15. [ ] Turn off remote access. `tailscale serve status` no longer lists Relay. The phone shows "Can't reach the Mac. Is Tailscale on?" with the last update time.

Other checks:

16. [ ] Keep the Mac awake on: while an agent works, `pmset -g assertions` lists "Relay: agents are working"; it's gone when the agent is done.
17. [ ] LAN regression: the old Wi‑Fi QR code still works, and Stop and New agent aren't offered there.
18. [ ] Optional: set the phone's clock 2 minutes off. Requests still work, because the page follows the Mac's clock from the Date header.

## Open items and risks

- **Not tested here:** real tmux, real Tailscale (Serve's Host and identity headers, HTTP/2 behaviour, the "enable HTTPS" CLI flow) and a real iPhone (Web Push, Home Screen storage, `getNotifications`, the clipboard paste). They're built from upstream source and documentation and covered by stand-ins; the checklist above is what remains.
- **Claude Code CLI assumptions** to confirm on the first real launch:
  - `--permission-mode default` overrides `permissions.defaultMode` from settings.
  - Nothing after `--` is read as an option. The prompt never starts with `-` anyway.
- **iOS install flow:** whether iOS keeps the `#c=` fragment when it installs from `/pair` without `start_url` isn't documented. If it drops it, the app falls back to "paste the pairing link".
- **Address changes:** if the Mac's tailnet name or Relay's port changes (for example, moved off a shared 443), the installed app's origin changes and the phone has to pair again.
- **Accepted by design:**
  - A phone that's paired and unlocked has full control.
  - A process on the Mac running as the user can reach the loopback port. It still can't sign without a phone's key, but it could do worse directly.
  - The push service sees ciphertext, size, timing, urgency (blocked pushes are urgent) and Relay's VAPID key.
  - The phone's Approve options are the ones Claude Code offers. If Claude Code offers "switch to bypass mode" in a permission prompt, the phone shows it, as the Mac card does.
- **Live working directories as known folders:** a live agent's current folder counts as known. Starting there still goes through Claude Code's trust prompt for folders it hasn't seen.
