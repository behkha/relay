# Remote anywhere: full control of Relay from the phone, over Tailscale

Status: design approved in brainstorming, spec awaiting review
Date: 2026-10-05

## Problem

The phone inbox only works on the Mac's own Wi‑Fi. `RemoteServer.isLocalNetwork` deliberately rejects public and VPN-routed addresses, so once you leave the house the agents block and nothing tells you. There is also no way to start or stop agents from the phone.

## Goals

- From anywhere, the phone can: get notified, answer questions and permission prompts, reply and message agents, read transcripts, see heat, start new agents and kill agents.
- Traffic travels only over the user's own Tailscale tailnet. No public endpoint, no third-party relay server.
- Real lock-screen notifications through Web Push to the existing page installed as a Home Screen app. No native iPhone app.
- Each phone is paired once and can be revoked individually.
- Relay keeps zero package dependencies (system frameworks and the `tailscale` / `tmux` CLIs only).

## Non-goals

- Tailscale Funnel or any public exposure.
- A native iOS app, APNs, CloudKit.
- Interactive terminal input from the phone (the terminal view is read-only; replies go through the message box).
- Free-form folder paths or `bypassPermissions` launches from the phone.
- Server-sent events or websockets. Polling stays.

## Architecture

```text
 iPhone PWA (Home Screen)                  Mac
 ┌───────────────────────┐ tailnet HTTPS  ┌─────────────────────┐ proxy  ┌───────────────────────┐
 │ remote.html + sw.js   │ ─────────────▶ │ tailscaled (serve)  │ ─────▶ │ Relay 127.0.0.1:47902 │
 │ device key (IndexedDB)│                │ adds Tailscale-User │        │ RemoteAPI (shared     │
 └──────────▲────────────┘                └─────────────────────┘        │ with LAN :47901)      │
            │ Web Push (aes128gcm, VAPID)                                └──────────┬────────────┘
            └── web.push.apple.com ◀────────────────────────────────────────────────┘
```

- `tailscale serve --bg --https=443 http://127.0.0.1:47902` terminates TLS with the tailnet's `*.ts.net` certificate, handles renewal, and adds `Tailscale-User-Login` / `Tailscale-User-Name` headers.
- Relay gains a third listener, loopback-only, on fixed port 47902. It never falls back to a random port, because the `serve` config points at it. If the port is busy, Settings shows an error.
- The request handlers move out of `RemoteServer` into a shared `RemoteAPI`. Both doors use it:
  - LAN door, `:47901`, token link: capabilities `read`, `answer` (exactly today's behaviour).
  - Tailnet door, `:47902`, paired device: capabilities `read`, `answer`, `control`.
- New files: `WebPush.swift` (VAPID + RFC 8291 encryption, CryptoKit only), `Devices.swift` (pairing, device store, request verification), `Tailscale.swift` (CLI discovery, status, serve on/off).

## Pairing and request authentication

### Threat model

Anyone on the tailnet can reach the URL. Any local process can reach `127.0.0.1:47902` and forge headers. Therefore the Tailscale identity header is a second factor only; the device signature is what grants access.

### Pairing flow

1. Mac: Settings → Phone → **Pair a device** shows a QR for `https://<mac>.<tailnet>.ts.net/pair#c=<code>`. The code is 32 random bytes, single use, valid 5 minutes. It lives in the URL fragment so it never reaches proxy logs.
2. The phone (already on the tailnet) opens the page, generates an ECDSA P-256 key pair with WebCrypto (`extractable: false`), stores it in IndexedDB on the `ts.net` origin (the same origin the PWA is installed from), and POSTs `{code, publicKey, deviceName}` to `/api/pair`.
3. The Mac shows a confirmation: “Pair ‘<deviceName>’ (<Tailscale-User-Login> via Tailscale)? Allow / Deny”. Pairing therefore needs physical presence at the Mac; a leaked code alone is useless.
4. On Allow, Relay stores `{id, name, publicKey, ownerLogin, pairedAt, lastSeen, pushSubscription?, pushPrefs}` in `~/Library/Application Support/Relay/devices.json`, mode 0600. The first pairing fixes `ownerLogin`; later pairings must come from the same login.

### Per-request verification

Headers sent by the page:

- `X-Relay-Device: <device id>`
- `X-Relay-Ts: <unix ms>`
- `X-Relay-Sig: base64url(ECDSA-P256-SHA256(method + "\n" + path?query + "\n" + ts + "\n" + hex(sha256(body))))`

Relay checks, in order:

1. Device exists and is not revoked.
2. `|now - ts| ≤ 60 s`.
3. Signature valid (`P256.Signing.ECDSASignature(rawRepresentation:)` matches WebCrypto's raw r‖s format).
4. Signature not in the replay cache (kept for 120 s).
5. `Tailscale-User-Login` present and equal to `ownerLogin`. Missing means the request did not come through `serve` and is rejected.

Failures return a bare 401. More than 20 failures per minute puts the listener into a 60 s cool-down for unauthenticated requests.

### Capability limits

- **Start agent:** folder must be one Relay already knows for that workspace (working directories from past sessions, plus folders pinned on the Mac). Permission mode is one of default, `plan`, `acceptEdits`. `--dangerously-skip-permissions` and `bypassPermissions` are never accepted from the phone. The prompt is a single argument passed through `Shell.quote`.
- **Kill agent:** same code path as the Mac's **Kill agent**.
- Every remote start or kill shows a Mac toast (“iPhone started an agent in relay”).
- Settings → Phone lists paired devices (name, paired, last seen) with **Revoke** and **Revoke all**. Revoking deletes the device's push subscription too.

## Remote start in tmux

- New `Launcher` target `.tmuxDetached`: `tmux new-session -d -s relay-<launchId> -c <folder> '<env> RELAY_LAUNCH_ID=<launchId> claude [--permission-mode <mode>] <prompt>'`.
- Requires `tmux` on `PATH` (`Proc.which("tmux")`); the phone's **New agent** sheet explains how to install it if missing.
- `relay-hook.sh` forwards one more header, `X-Relay-Launch: ${RELAY_LAUNCH_ID:-}`, in both the normal and `Wait` request paths. `Store` uses it to turn the phone's “Starting…” placeholder into the real session exactly, without guessing by folder. Replies already reach the pane through the existing `TMUX_PANE` support in `TerminalBridge`.
- A placeholder with no `SessionStart` after 30 s turns into an error row showing the last lines of `tmux capture-pane`.

## Phone UI

`remote.html` is one page for both doors. `/api/state` adds `caps`; the page shows only what the caps allow. When a device key exists, `api()` signs requests; otherwise it falls back to the `?t=` token.

- **PWA:** `/manifest.webmanifest`, `/sw.js`, `/icon-192.png`, `/icon-512.png` (generated from the existing icon pipeline), `apple-mobile-web-app-capable`, standalone display, Black theme colour. First run on the tailnet shows three steps: Add to Home Screen → open from Home Screen → **Enable notifications** (iOS only allows the permission prompt from a tap inside the installed app).
- **Inbox tab:** today's cards. A notification tap deep-links to `/#item=<id>`.
- **Agents tab:** today's list plus heat badge (`312% CPU`, ember/flame style) and time since last activity. With `control`: **Kill** with a confirm and a 2 s undo bar on the phone.
- **New agent sheet** (`+`, `control` only): workspace, folder (recent first, pinned on top), prompt (iOS dictation works), mode (Default / Plan / Accept edits), **Start**. A “Starting…” row appears immediately.
- **Session sheet:** today's transcript view plus a **Terminal** toggle for tmux agents showing the last 60 lines of `tmux capture-pane -p`, refreshed every 2.5 s, read-only.
- **Device sheet:** device name, notification status with **Send test push**, per-event toggles (blocked / finished / on fire), **Hide content in notifications**, **Forget this device**.
- **Network:** poll every 2 s while visible, stop entirely when hidden (`visibilitychange`). If the Mac is unreachable, a banner reads “Can't reach the Mac. Is Tailscale on?” with the time of the last successful update.

## Web Push

### When to send

Hooked in next to `Notifier.notify` (`Store.swift:494`), filtered by each device's event toggles:

- Mac idle ≥ 60 s (`CGEventSource.secondsSinceLastEventType`) or screen locked: send immediately.
- Otherwise: wait 45 s and send only if the item is still unanswered. Answering at the desk never buzzes the phone.
- “On fire” pushes come from the heat monitor's existing fire transition, rate-limited to one per agent per 10 minutes.

### Payload and headers

- Encrypted with RFC 8291 `aes128gcm` (ECDH P-256 + HKDF-SHA256 + AES-128-GCM, CryptoKit). The push service only sees ciphertext.
- JSON: `{title, body (≤120 chars), itemId, sessionId, kind}`. With **Hide content**, body is “An agent needs you”.
- Headers: VAPID `Authorization: vapid t=<ES256 JWT>, k=<public key>`, `TTL: 3600`, `Urgency: high` (blocked) or `normal` (finished, fire), `Topic: <base64url(sha256(itemId))[0..31]>` so a newer push for the same item replaces the older one.

### Withdrawing

iOS does not allow silent web pushes (each push must display a notification or Safari revokes the subscription). Instead, whenever the page opens or polls, it calls `registration.getNotifications()` and closes any whose `itemId` is no longer in state.

### Keys and subscriptions

- VAPID P-256 key generated once, stored in `~/Library/Application Support/Relay/vapid.json`, mode 0600. Not the Keychain: the ad-hoc signature changes every build and would trigger Keychain prompts.
- Subscriptions are stored per device in `devices.json`. Endpoints are accepted only on known push hosts: `*.push.apple.com`, `fcm.googleapis.com`, `updates.push.services.mozilla.com`. This stops a paired device from making the Mac POST to arbitrary URLs.

### Error handling

| Response | Action |
| --- | --- |
| 201 | done |
| 404 / 410 | drop the subscription; Settings marks the device “notifications off” |
| 413 | resend once with the hidden-content body |
| 429 / 5xx | retry at 2 s, 10 s, 60 s, then log and give up |
| network down | queue up to 20 per device, flush when `NWPathMonitor` reports a path |

## Tailscale setup

**Turn on remote access** (Settings → Phone) runs these checks and stops at the first failure with a message that says what to do:

1. Find the CLI: `tailscale` on `PATH`, else `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. Missing: “Install Tailscale”.
2. `tailscale status --json`: running, MagicDNS on, read the `*.ts.net` name.
3. `tailscale serve status --json`: if 443 is already serving something else, do not overwrite it; offer 8443.
4. `tailscale serve --bg --https=<port> http://127.0.0.1:47902`. If HTTPS certificates are disabled for the tailnet, show the message with a link to the admin console setting.
5. **Turn off** removes only Relay's own `serve` entry.

## Mac sleep

Optional **Keep the Mac awake while agents work**: an `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` held only while at least one agent is working or blocked, released otherwise. A closed lid on battery still sleeps; the phone's unreachable banner covers that case.

## Testing

`Package.swift` has no test target today, and XCTest is not guaranteed with only the Command Line Tools. The checks below run through a hidden `Relay --self-test` flag driven by `scripts/selftest.sh`, which exits non-zero on failure:

- RFC 8291 payload encryption against the RFC's published test vectors.
- VAPID JWT shape and signature verification.
- Device signature verification against a fixture generated by WebCrypto.
- Replay cache and timestamp window edges (±60 s).
- Push endpoint allowlist (accepts the three hosts, rejects lookalikes such as `push.apple.com.evil.test`).
- `tailscale serve status` parsing, including the “443 already in use” case.

Manual end-to-end on a real iPhone over cellular: pair, receive push while locked, answer a permission prompt, start an agent in tmux, read its terminal, kill it, revoke the device and confirm the next request is rejected.

Demo mode (`Demo.swift`) must not send pushes or start tmux sessions.

## Open questions

- Port 443 vs 8443 when the user already serves something on 443: the spec offers 8443; confirm that is acceptable rather than a user-chosen port.
- Whether the LAN door should also accept paired devices (different origin, so a second key per phone). The spec keeps the LAN door token-only.
