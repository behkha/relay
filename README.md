<div align="center">

<!-- Re-record with scripts/record-mascot.sh idle. -->
<img src="docs/mascot.webp" alt="Relay's mascot: a pastel cloud in a ring of liquid light, breathing, blinking and glancing around" width="256" height="256">

# Relay

**`stdin` for your Claude Code swarm.**

A native macOS inbox that sits on the edge of your screen and answers your agents for you,
so you can stop `⌘-Tab`-ing through 14 terminal tabs like it's 1997.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Third-party dependencies: 0](https://img.shields.io/badge/third--party_dependencies-0-brightgreen)
![Lines of Swift: ~13k](https://img.shields.io/badge/lines_of_Swift-~13k-blue)
![Electron: no](https://img.shields.io/badge/Electron-nope-lightgrey)

<br><br>

<!-- Re-record with scripts/record-demo.sh (scripted demo mode, mock data only). -->
<img src="docs/demo.gif" alt="Relay demo: an agent asks a question and 'Agent needs you' slides out of the pill with the mascot, the inbox card opens, two prompts are answered from the keyboard, a reply goes to a finished turn, a spoken message is routed to an agent, the agents list lights up as agents finish, and the empty inbox says nothing needs you" width="880">

</div>

```text
$ relay --explain
  You run N Claude Code agents. Each one blocks on a question, a permission
  prompt, or a finished turn. Each one lives in a different terminal tab.
  Your attention is a single-threaded scheduler with a terrible context-switch cost.

  Relay is the interrupt controller.
```

Every question, permission prompt and finished task from every agent lands in **one inbox**. You answer once, and the answer is routed back to the exact process that asked, even when its window is buried six Spaces deep.

It started as a re-creation of [One](https://getone.one) and then grew one feature that I needed and nobody shipped: **workspaces**, so several Claude accounts (different Gmail logins) run side by side and never cross the streams.

> [!NOTE]
> Relay is pure Swift + SwiftUI + AppKit. No Electron, no Node runtime, no Homebrew tap, no package manifest with 400 transitive dependencies. `Package.swift` declares exactly one target and one dependency: [NimbiKit](https://github.com/behkha/nimbi-kit), the shared cloud and design system behind every nimbi app, which itself has zero dependencies. The HTTP server is hand-rolled on top of `Network.framework`'s `NWListener`, because pulling in a web framework to parse three headers felt wrong.

## Table of contents

- [Features](#features)
- [Install](#install)
- [Quick start](#quick-start)
- [Keyboard map](#keyboard-map)
- [Workspaces: multi-account without the pain](#workspaces-multi-account-without-the-pain)
- [Phone, anywhere (Tailscale)](#phone-anywhere-tailscale)
- [Architecture](#architecture)
- [Permissions macOS will ask for](#permissions-macos-will-ask-for)
- [Uninstall](#uninstall)
- [Relay vs. One](#relay-vs-one)

## Features

### The edge pill

A thin black tab that flares into the right edge of the screen (or the left, or [under the notch](#right-left-or-the-notch)), one glyph per agent. Think of it as `htop` for your attention:

| Glyph | State |
| --- | --- |
| Spinning blue | Working |
| Amber | Blocked on you |
| Green | Done |

A glyph pops when its agent changes state, so you see an agent finish out of the corner of your eye. Hover to expand the column of glossy black buttons: **inbox** (a dot means something is waiting), **agents**, **workspaces** (the mascot), **talk**, **talk with a screenshot**, and **settings** (`…`). While you talk the mic turns into live red level bars. Every button has a tooltip, because hidden UI without labels is a crime. Tooltips and hover work even while another app is in front; turn them off in **Look & sound** if you know the buttons by heart.

When an agent asks something, **Agent needs you** slides out of the pill and the mascot (a pastel cloud whose mood follows your agents) drops out from behind it, then both tuck back in as the card opens.

### Right, left, or the notch

**Settings → Inbox → Pill** (or **Position** in the pill's **Look & sound**) puts Relay where your eyes already are:

- **Right** (default): the edge pill described above. **Pill position** slides it up or down the edge.
- **Left**: the same pill, mirrored. The card, panels, talk bar and session viewer open toward the middle of the screen.
- **Notch**: a black island around the camera housing, like the Dynamic Island you didn't know your Mac had. Collapsed, it shows the mascot on one side of the notch and a dot per agent on the other. Rest the pointer on it for a moment (passing over doesn't count) and it opens into a dashboard: the buttons, a bigger mascot, what your agents are doing, and a chip per agent. The card, agents list, settings and talk bar hang from the island as one black piece. Clicks beside the island go to the menu bar as usual. On a Mac without a notch the island sits at the top centre of the menu bar.

  The notch is shared by every [nimbi](https://github.com/behkha/nimbi) app, one at a time. If you give it to another one (say [Skyline](https://github.com/behkha/nimbi-skyline), from its settings), Relay's pill waits at the right edge, and settings show "Notch is used by Skyline" with a **Use for Relay** button to take it back. Either way the switch is live.

Switching takes effect at once; nothing to restart.

### The inbox card

A solid black card that grows out of the pill the moment an agent asks something. The header shows the session title, page dots, and `‹ J` `› K` `?` `× esc`; `?` (or the `?` key) shows every shortcut. Below that, the agent's status and project, the instruction it started from (blue bubble on the right) and what the agent said right before it asked (grey bubble on the left). It speaks every interrupt type Claude Code emits:

- **`AskUserQuestion`**: single-select, multi-select and multi-question flows with step chips (`● Limit by ○ On limit ○ Submit`) and a review step before you commit.
- **Permission prompts**: the exact option set Claude Code offers (Yes / Yes, and don't ask again for `<rule>` / Yes, and switch to `<mode>` / No). Or just type or say it: "yes" and "go ahead" approve, "no" declines, and anything else declines *and* tells Claude what to do instead.
- **Finished turns**: the reply in a grey bubble (rendered as Markdown when it's long), a reply box, then **Next steps** with **Kill agent** (terminal agents) and **Discard** on the same line: two likely follow-ups predicted by Claude Haiku on that agent's own account. Click to send, `⤢` to edit first. The helper runs with no tools, none of your hooks or plugins, and treats the agent's text strictly as data.

When both kinds are waiting, filter chips on top, **All · Asking · Done**, each with a count, pick what the card pages through: *Asking* is questions, permission prompts and MCP input requests; *Done* is finished turns and idle agents. The pill's badge still counts everything waiting on you, and a new question that the filter would hide flips it back to All, so nothing blocks in silence.

Nothing waiting? The card says so: "Nothing needs you. Suspiciously quiet."

### Undo, because humans are non-deterministic

Every answer, message, discard or kill runs after a two-second `esc to undo` bar with a draining blue line (a message shows its own words: `✓ push to prod`). It's a write-ahead log for your bad decisions.

### Agents list

Click the glyphs in the pill to see every agent, grouped by account (or by project), one compact line each: status glyph, session name (the one you set with `/rename` or in the Claude app, else Claude Code's own title), background tasks (`⑂ 2`), and a mic and `×` always at hand. Rows cascade in as the list opens; when an agent finishes, its dot pops green and its row glows for a moment. Hover a row for status, project, terminal, load and last instruction. Click to open the session; the mic talks to just that agent.

### Heat: a thermal profiler for your agents

Relay samples the CPU of each agent's **entire process tree** every 2.5 s: the `claude` process plus every build, test run and dev server it spawned, including children that already exited. It cross-references that with macOS's thermal state.

- More than ~2 cores busy, or the top consumer while macOS reports the Mac is hot: the agent **catches fire**. Its row burns at the edges, its glyph becomes a flickering ember (in the pill and the list), its load (`312% CPU`) shows on hover and in the main window, and a toast names the culprit.
- Above ~1 core it **smolders** instead.
- Thresholds have hysteresis, so flags don't flap. (Yes, it's a Schmitt trigger. Yes, I'm proud of it.)

### Session viewer

The live conversation rendered as Markdown: your prompts, Claude's replies, every tool call with its output. Or flip to the **Terminal** tab to mirror the agent's herdr, tmux, Terminal or iTerm tab. Message the agent from the bottom.

### Talk

Double-tap `Option` (or click the mic). A black bar opens level with the pill's mic and fills with your words as you speak; you can type or edit too. `⏎` (or another double-tap) sends, `⇧⏎` adds a line, `esc` discards. The `To` chip at the top of the bar shows which agent gets it; click it to pick another from the list. The message goes to the agent on the card or the one you picked. Otherwise Relay suggests the one it's obviously meant for, resolved by name, project folder, or a Claude Haiku router as the fallback, and sends nothing until you approve the suggestion with `⏎` (or pick another agent). The bar then tells you where it went (`✓ Sent to @claude-5 · ledger-db`) before it gets out of the way.

### Phone

The **Phone** tab serves the inbox to any browser on the same Wi‑Fi. Scan the QR code, add it to your Home Screen, approve `rm -rf node_modules` from the couch. Tap an agent to read its conversation and message it. The inbox has the same **All · Asking · Done** filters as the card, a **Clear** button on every card, and **Clear N done** to sweep finished turns in one tap. Clearing an open question only takes it off the list (the phone asks first); the agent keeps waiting for an answer in its terminal.

Leaving the house? Turn on [Anywhere, over Tailscale](#phone-anywhere-tailscale): the same page over your own tailnet, with lock-screen notifications, and it can start and stop agents too.

### Answer anywhere

Answered in the terminal or the Claude app instead? The card (and the phone's copy) notices and disappears on its own. Relay is eventually consistent with your keyboard.

### Settings

`…` opens Accounts, which account to show, Phone, **Look & sound** (Dark or Black theme, pill position, pill size, text size, tooltips, sounds), Advanced, Hide for 2 hours, and Quit.

## Install

> [!IMPORTANT]
> Requires macOS 13 Ventura or later on Apple silicon (the build targets `arm64`), the **Xcode Command Line Tools** (full Xcode is not needed), and [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

```bash
git clone https://github.com/behkha/relay.git
```

```bash
cd relay && scripts/build.sh --install
```

What `build.sh` does, in order:

1. `swift build -c release --arch arm64`
2. Assembles `Relay.app` by hand (yes, it writes its own `Info.plist`, no `.xcodeproj` anywhere)
3. Draws the app icon procedurally with `scripts/make-icon.swift` and packs it with `iconutil`
4. Signs it ad hoc with `codesign`
5. With `--install`, copies it to `/Applications`

Drop `--install` to just build into `./build/Relay.app`. `scripts/selftest.sh` runs the built-in checks (crypto test vectors, signed requests, Tailscale parsing, launch quoting) without starting the app.

## Quick start

1. Open Relay from Applications. It lives in the menu bar and on the right edge of the screen (`LSUIElement`, so no Dock icon cluttering your life). Prefer the left edge or the notch? See [Right, left, or the notch](#right-left-or-the-notch).
2. The first launch opens the **Workspaces** window and connects your default Claude Code account (`~/.claude`).
3. Start a Claude Code agent. Ask it something hard. Watch the card appear.

> [!TIP]
> Sessions that were already running pick up Relay after a restart: `/exit`, then `claude --resume`.

## Keyboard map

Focus the card with `⌃⌥Space`, then:

| Key | Action |
| --- | --- |
| `1`–`9` | Pick an answer |
| `J` / `K` or `←` / `→` | Previous / next card (vim users, you're welcome) |
| `space` | Reply (or just start typing) |
| `S` | Attach a screenshot |
| `V` | Talk |
| `E` | Discard |
| `⇧X` | Kill agent |
| `?` | Show these shortcuts on the card |
| `O` | Open the session |
| `T` | Open the terminal |
| `esc` | Undo, then close |

Shortcuts are bound to **physical key codes**, not characters, so they work on any layout: Dvorak, Colemak, AZERTY, Persian, whatever you daily-drive.

## Workspaces: multi-account without the pain

Each workspace is its own `CLAUDE_CONFIG_DIR`, so it gets its own login, settings, history and hooks. Full isolation, no shared mutable state.

1. Open **Workspaces** and click **Add a Claude account**.
2. Name it (e.g. *Work*), optionally add the Gmail address and a shell command name (e.g. `claude-work`).
3. Relay creates `~/.claude-workspaces/<name>`, installs its hooks there and opens a terminal running `claude auth login` for that folder. Finish the sign-in in the browser with that account.
4. Start agents for that account with **New Claude Code session…**, with `claude-work` in any new terminal, or explicitly:

```bash
CLAUDE_CONFIG_DIR=~/.claude-workspaces/work claude
```

With more than one account, every card shows which workspace the agent belongs to, and the agents list is grouped by account. **Settings → Showing** (or the menu bar icon) filters to all accounts or just one.

## Phone, anywhere (Tailscale)

The LAN page stops working the moment you leave your Wi‑Fi. Turn on **Anywhere, over Tailscale** and the phone reaches Relay through your own [Tailscale](https://tailscale.com) tailnet from any network. Nothing is exposed to the public internet, and there is no third-party relay server.

From anywhere, the phone can:

- get **lock-screen notifications** (Web Push to the Home Screen app) when an agent asks something, finishes, or catches fire, tap one and land on that card;
- answer questions and permission prompts, reply to and message agents, read their conversations;
- **start a new agent** (in a detached tmux session) in a folder Relay already knows, in Default, Plan or Accept edits mode, and **stop** agents;
- see heat and last activity, and read a tmux agent's terminal (read-only).

### Requirements

- Tailscale on the Mac and the phone, signed in to the same tailnet.
- **MagicDNS** and **HTTPS certificates** turned on for the tailnet (Tailscale admin console → DNS).
- `tmux` on the Mac to start agents from the phone (`brew install tmux`).
- iOS 16.4 or later for notifications: iOS delivers Web Push only to apps on the Home Screen.

### Setup

1. **Settings → Phone → Allow phone access over Tailscale.** Relay checks each step and says what to fix. It runs `tailscale serve --bg --https=443 http://127.0.0.1:47902` (8443 when 443 already serves something else; it never overwrites another Serve entry), and turning it off removes only that entry.
2. **Pair a device** shows a QR code. Scan it with the iPhone Camera.
3. On the page that opens: **Share → Add to Home Screen**, then open Relay from the Home Screen. It pairs there, and your Mac asks you to **Allow** it. Check that both screens show the same code.
4. In the app, tap **Enable notifications**.

Optionally pin the folders the phone may start agents in, and turn on **Keep the Mac awake while agents work** (holds off idle sleep only while an agent works or waits on you).

> [!NOTE]
> iOS keeps a Home Screen app's storage separate from Safari's, so the installed app pairs itself. If it opens without the pairing link, copy the link (from the Safari page, or from the Mac's pairing sheet over Universal Clipboard) and paste it into the app.

### Security model

- **Only your tailnet.** `tailscale serve` terminates TLS with your tailnet's `*.ts.net` certificate and proxies to Relay on `127.0.0.1:47902`: loopback only, a fixed port with no fallback. Relay refuses Funnel traffic and any request not addressed to a `*.ts.net` name (so a web page that rebinds its domain to `127.0.0.1` gets nothing), and holds at most 32 connections at once, each with 10 s to send its request.
- **Every request is signed.** Each device holds a non-extractable ECDSA P-256 key (WebCrypto, in IndexedDB) and signs method, path and query, a timestamp and the body hash. Relay checks, in order: a paired, unrevoked device; a timestamp within 60 s; the signature; a replay cache (120 s, keyed by the signed message, since an ECDSA signature can be rewritten into a second valid one); and that Tailscale Serve vouched for the same Tailscale login that paired the device. Any local process can reach the port and forge headers, so the login is a second factor; the signature is what grants access. Failures get a bare `401`. More than 20 a minute from one Tailscale account pauses pairing for that account for 60 s; nobody can lock you out of a phone that's already paired.
- **Pairing needs you at the Mac.** The QR carries a single-use 256-bit code, valid five minutes, in the URL fragment so it never reaches a proxy log. Then the Mac asks **Allow / Deny** (Deny is the default) in a floating window that never holds up the rest of Relay. The first pairing fixes the Tailscale account; later pairings must come from it until every device is revoked.
- **Starting agents is fenced in.** Only in folders Relay already knows for that workspace (where its agents started, plus folders you pinned), only in Default, Plan or Accept edits mode (never `bypassPermissions` or `--dangerously-skip-permissions`; the mode is always passed, Default included, so a `defaultMode` in a settings file can't change it), with the prompt passed as one quoted argument after `--` that never starts with `-`. tmux runs `/bin/sh -c` directly, so neither tmux format expansion nor your login shell's quoting ever sees the prompt or the folder.
- **The page runs only its own code.** It's served with a Content-Security-Policy that allows its one script by hash, and it can't be framed. Relay only serves on a port it has to itself: other Serve mounts on the same origin could use the phone's key, so Relay moves off a port it would share.
- **Revocable.** Settings → Phone lists paired devices with **Revoke** and **Revoke all**; a phone can also forget itself. `devices.json` and `vapid.json` are written with mode `0600`.

### Push privacy

Payloads are encrypted for the phone (RFC 8291, `aes128gcm`, CryptoKit). Apple's, Google's or Mozilla's push service sees only ciphertext, its size and timing, Relay's VAPID public key and a contact URL (this repository, not your address). **Hide content in notifications** sends only "An agent needs you". Relay posts only to those three push services, and never follows redirects. When you're at the Mac, a push waits 45 s and is dropped if you answered meanwhile; iOS doesn't allow silent pushes, so the app closes notifications for items you already answered the next time it opens.

## Architecture

```text
 ┌──────────────┐  hook event (JSON on stdin)   ┌──────────────┐
 │ Claude Code  │ ────────────────────────────▶ │ relay-hook   │  bash, ~100 lines
 │  (agent N)   │                               └──────┬───────┘
 └──────▲───────┘                                      │ POST 127.0.0.1 + token
        │                                              ▼
        │  PermissionRequest decision          ┌──────────────┐
        ├───────────────────────────────────── │  Relay.app   │  NWListener HTTP/1.1
        │  send-keys / AppleScript / herdr     │  (SwiftUI)   │
        └───────────────────────────────────── └──────┬───────┘
                                                      │ LAN :47901, token link
                                                      │ tailnet: Tailscale Serve → 127.0.0.1:47902,
                                                      │ requests signed by a paired device
                                                      ▼
                                               📱 remote.html + Web Push
```

### Hooks

Relay installs a small hook script (`~/Library/Application Support/Relay/bin/relay-hook`) into each workspace's `settings.json` for `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification` and `Stop` (plus the background message hook below). Your other settings and hooks are preserved, and a one-time backup goes to `settings.json.relay-backup`.

The script posts each event to Relay on `127.0.0.1` with a random token from `server.json` (mode readable only by you). If Relay isn't running, the script exits immediately and Claude Code behaves exactly as if Relay never existed. Fail-open, zero latency tax.

### Answering

- **Permission prompts and questions** are answered through the `PermissionRequest` hook's decision, so the answer reaches the exact agent no matter how buried its window is. The terminal prompt stays usable at the same time; whoever answers first wins. Answered outside Relay, the card closes when Claude Code ends the waiting hook, or at the latest when that tool's `PostToolUse` arrives (Claude Code doesn't always end the hook); parallel prompts for the same tool are told apart by their input.
- **Free-text replies** are typed into the agent's terminal through **herdr** (`herdr pane send-text`), **tmux** (`send-keys`), and **Terminal.app** / **iTerm2** (AppleScript, matched by the tab's tty).
- **Other terminals** (Ghostty, Warp, VS Code…) don't expose a way to target the exact tab, so Relay never types blindly: it copies your message and brings that app forward for you to paste.
- **Claude desktop app agents** have no terminal, so Relay reaches them via a background `Stop` hook using `asyncRewake` that parks after each turn. Sending a message wakes the agent immediately. If it's busy, the message is queued (a dashed bubble you can cancel) and delivered the instant the turn ends.

> [!WARNING]
> Relay refuses to type into a tab whose agent has exited or been suspended. A reply meant for Claude must never land in a bare shell prompt and execute as a command. Messages Relay can't attribute with certainty are never used to answer a prompt either: a guessed or typed message to an agent that's asking something opens that prompt instead.

### Source map

| File | What lives there |
| --- | --- |
| `Store.swift` | Central state, event ingestion, hook delivery queue |
| `HTTPServer.swift` | Minimal HTTP/1.1 server on `NWListener` |
| `HookInstaller.swift` | Idempotent `settings.json` surgery |
| `TerminalBridge.swift` | tmux / herdr / AppleScript keystroke injection |
| `Heat.swift` | Process-tree CPU sampler + thermal state + hysteresis |
| `Voice.swift` | On-device speech recognition and routing |
| `RemoteServer.swift` | LAN phone door: token link, QR code |
| `RemoteAPI.swift` | The phone API both doors share, gated by capability (read, answer, control) |
| `TailnetServer.swift` | Loopback door for Tailscale Serve, pairing, the on/off controller |
| `Devices.swift` | Paired devices, pairing codes, signed-request verification |
| `Tailscale.swift` | `tailscale` CLI: status, Serve on and off |
| `WebPush.swift` | VAPID, RFC 8291 encryption, delivery rules, when to push |
| `PowerAssertion.swift` | Keeps the Mac awake while agents work |
| `SelfTest.swift` | `Relay --self-test`, run by `scripts/selftest.sh` |
| `CardView.swift`, `PillView.swift`, `Panels.swift` | The UI you actually look at |
| `Cloud.swift`, `Mood.swift` | The cloud mascot, and the mood it works out from your agents and your attention |
| `Mascot.swift` | "Agent needs you", and the pill's chrome, level bars and status pops |
| `MascotRecording.swift` | Records the mascot alone for the README (`scripts/record-mascot.sh`) |
| `Dock.swift`, `NotchView.swift` | Where the pill docks (right, left, notch) and the notch island |
| `Pointer.swift` | Hover and tooltips that work while another app is in front |
| `Markdown.swift` | A Markdown renderer, because of course |
| `Resources/relay-hook.sh` | The bridge Claude Code calls |
| `Resources/remote.html`, `sw.js`, `manifest.webmanifest` | The phone page and its Home Screen app files |

## Permissions macOS will ask for

| Permission | Why |
| --- | --- |
| Automation (Terminal / iTerm) | Type replies into the right tab |
| Accessibility | Double-tap `Option` in every app |
| Microphone + Speech Recognition | Voice messages (on-device when your Mac supports it) |
| Screen Recording | Only if you turn on screenshots for voice messages |
| Notifications | Alerts when the card isn't open |

> [!NOTE]
> The app is signed ad hoc, so macOS may re-ask for some permissions after a rebuild. TCC keys on the code signature, and an ad hoc signature changes every build.

## Uninstall

1. Remove each workspace in Relay (this removes its hooks cleanly).
2. If you used Tailscale access, turn it off in Settings → Phone (this removes Relay's `tailscale serve` entry).
3. Quit Relay.
4. Delete the app and its support folder:

```bash
rm -rf /Applications/Relay.app ~/Library/Application\ Support/Relay
```

## Relay vs. One

- **Phone**: a web page you add to the Home Screen, not a native iPhone app. On your Wi‑Fi it works with a token link; from anywhere it works over your own Tailscale tailnet, with paired devices, Web Push notifications, and starting and stopping agents. No cloud relay either way.
- **Scope**: Claude Code only. Codex, OpenCode and Pi aren't supported, and neither are agents on other machines.
- **AI helpers**: voice routing and next-step suggestions use Claude Haiku through your own Claude Code login, with no tools.
- **Workspaces**: multiple Claude accounts, fully isolated. This is the reason Relay exists.
- **Look**: the same black pill, card, talk bar and animations, plus a cloud mascot of Relay's own whose mood follows your agents: asleep, busy, asking, impatient, happy.

---

<div align="center">
<sub>Built in Swift, zero third-party dependencies, for people who run more agents than they have monitors.<br>
<code>exit 0</code></sub>
</div>
