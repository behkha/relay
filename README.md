# Relay

A Mac app that answers your Claude Code agents for you to see: every question, permission prompt and finished task lands in one inbox on the edge of your screen, and your answer goes straight back to the right terminal. It's a re-creation of [One](https://getone.one) with one addition: **workspaces**, so several Claude accounts (different Gmail logins) run side by side and stay separate.

## Install

```bash
scripts/build.sh --install
```

This builds a release binary with the Xcode Command Line Tools (full Xcode isn't needed), assembles `Relay.app`, signs it ad hoc and copies it to `/Applications`. Then open Relay from Applications. It lives in the menu bar and on the right edge of the screen.

The first launch opens the Workspaces window and connects your default Claude Code account (`~/.claude`). Claude Code sessions that were already running pick up Relay after a restart (`/exit`, then `claude --resume`).

## What it does

- **Edge pill**: a thin sliver on the right edge of the screen with one glyph per agent (spinning blue = working, amber = needs you, green = done). Hover it to open the column: **inbox** (dot = something waiting), **agents**, **workspaces**, **talk**, **talk with a screenshot**, and **settings** (`…`). Hover any button for its label.
- **Inbox card** (glass, like One): opens by itself when an agent asks something. The header shows the session's title, `1 of N` and the keyboard hints; under it the agent's status and project, the instruction it started from (blue bubble) and a one-line summary of what it did (`Explored · Read cart.js · Ran · npm`). It handles:
  - `AskUserQuestion`: single, multi-select and several questions with step chips (`● Limit by ○ On limit ○ Submit`) and a review step before sending.
  - Permission prompts: the exact options Claude Code offers (Yes / Yes, and don't ask again for `<rule>` / Yes, and switch to `<mode>` / No). You can also type or say it: "yes" or "go ahead" approves, "no" declines, and anything else declines and tells Claude what to do instead.
  - Finished turns: the reply rendered as Markdown, a reply box, **Kill agent** (terminal agents) and **Discard**, plus **Next steps**: two likely follow-ups suggested by Claude Haiku on that agent's own account when you open the card (click to send, ⤢ to edit first). The helper runs with no tools, none of your hooks or plugins, and treats the agent's text as data.
- **Undo**: every answer, message, discard or kill runs after a two-second "esc to undo" bar.
- **Agents list**: click the agent glyphs in the pill to see every agent, grouped by account (or by project). Each row shows the session's name (the one you gave it with `/rename` or in the Claude app, else Claude Code's own title), its status, project, terminal, last instruction and when it last did something. Click one to open its session; the mic talks to just that agent.
- **Session viewer**: the live conversation, rendered as Markdown (your prompts, Claude's replies, every tool call with its output), or the **Terminal** tab mirroring its herdr, tmux, Terminal or iTerm tab. Message the agent from the bottom.
- **Keyboard** (card focused with `⌃⌥Space`): `1`–`9` answer, `J`/`K` (or `←`/`→`) move, `space` reply (or just start typing), `S` attach a screenshot, `V` talk, `E` discard, `⇧X` kill agent, `O` open the session, `T` open the terminal, `esc` undo → close. Shortcuts follow the physical keys, so they work with any keyboard layout.
- **Talk**: double-tap `Option` (or click the mic). A small bar opens next to the pill and listens; your words appear as you speak, and you can type or edit too. `⏎` (or another double-tap) sends, `⇧⏎` adds a line, `esc` discards. It goes to the agent on the card, the agent you picked, or the one it's clearly meant for (by name, project folder, or Claude Haiku).
- **Settings** (`…`): Accounts, which account to show, Phone, **Look & sound** (Dark or Black theme, pill size, text size, sounds), Advanced, Hide for 2 hours, Quit.
- **Phone**: the Phone tab serves the inbox to any phone browser on the same Wi‑Fi. Scan the QR code and add the page to your Home Screen. Tap an agent there to read its conversation and message it.
- **Answer anywhere**: if you answer in the terminal instead, the card disappears on its own.

## Workspaces (several Claude accounts)

Each workspace is its own `CLAUDE_CONFIG_DIR`, so it has its own login, settings, history and hooks.

1. Open **Workspaces** and click **Add a Claude account**.
2. Give it a name (e.g. *Work*), optionally the Gmail address and a shell command name (e.g. `claude-work`).
3. Relay creates `~/.claude-workspaces/<name>`, installs its hooks there and opens a terminal running `claude auth login` for that folder. Finish the sign-in in the browser with that Gmail account.
4. Start agents for that account with **New Claude Code session…**, with `claude-work` in any new terminal, or with `CLAUDE_CONFIG_DIR=~/.claude-workspaces/work claude`.

With more than one account, every card shows which workspace (and so which account) the agent belongs to, and the agents list is grouped by account. **Settings → Showing** (or the menu bar icon) shows all accounts or just one.

## How it works

- Relay installs a small hook script (`~/Library/Application Support/Relay/bin/relay-hook`) into each workspace's `settings.json` for `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification` and `Stop` (plus the background message hook described below). Your other settings and hooks are kept, and a one-time backup is written to `settings.json.relay-backup`.
- The script posts each event to Relay on `127.0.0.1` with a random token (`server.json`, readable only by you). If Relay isn't running, the script exits immediately and Claude Code behaves as usual.
- Permission prompts and questions are answered through the `PermissionRequest` hook's decision, so the answer goes to the exact agent even when its window is buried. The terminal prompt stays usable at the same time.
- Free-text replies are typed into the agent's terminal: through **herdr** (`herdr pane send-text`), **tmux** (`send-keys`), **Terminal.app** and **iTerm2** (AppleScript, matched by the tab's tty). For other terminals (Ghostty, Warp, VS Code…), Relay can't target the exact tab, so it never types blindly: it copies your message and brings that app forward for you to paste.
- Agents inside the **Claude desktop app** have no terminal, so Relay reaches them through a background `Stop` hook (`asyncRewake`) that waits after each turn. Sending a message wakes the agent right away. If it's busy, the message is queued (shown as a dashed bubble you can cancel) and delivered the moment it finishes its turn. The agent sees it as a message from you, sent from Relay. Relay also refuses to type into a tab whose agent has exited or been suspended, so a reply can never run as a shell command.

## Permissions macOS will ask for

| Permission | Why |
| --- | --- |
| Automation (Terminal / iTerm) | Type replies into the right tab |
| Accessibility | Double-tap Option in every app |
| Microphone + Speech Recognition | Voice messages (on-device when your Mac supports it) |
| Screen Recording | Only if you turn on screenshots for voice messages |
| Notifications | Alerts when the card isn't open |

The app is signed ad hoc, so macOS may ask again for some permissions after you rebuild it.

## Uninstall

Remove each workspace in Relay (this removes its hooks), quit Relay and delete `/Applications/Relay.app` and `~/Library/Application Support/Relay`.

## Differences from One

- The phone side is a web page on your local network. There's no native iPhone app, push notifications or cloud relay, so it only works while your phone is on the same network as the Mac.
- It supports Claude Code only. Codex, OpenCode and Pi aren't supported, and neither are agents on other machines.
- Agent routing for voice and next-step suggestions use Claude Haiku through your own Claude Code login (no tools).
- Messages Relay can't be sure about are never used to answer a prompt: a guessed or typed message to an agent that is asking something opens that prompt instead.
