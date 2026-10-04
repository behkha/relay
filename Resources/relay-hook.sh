#!/bin/bash
# Relay hook bridge for Claude Code.
# Installed by Relay.app into each workspace's settings.json as:
#   "<path>/relay-hook" <workspace-id> <EventName>
# Forwards the hook payload (stdin) to the Relay app on localhost.
# If Relay is not running, it exits silently and Claude Code behaves normally.

# Relay's own background `claude -p` calls (agent routing) must not show up as agents.
[ -n "$RELAY_DISABLE" ] && { cat >/dev/null; exit 0; }

WS="$1"
EVENT="$2"
CONF="$HOME/Library/Application Support/Relay/server.json"
[ -r "$CONF" ] || { cat >/dev/null; exit 0; }

PORT=$(/usr/bin/plutil -extract port raw -o - "$CONF" 2>/dev/null)
TOKEN=$(/usr/bin/plutil -extract token raw -o - "$CONF" 2>/dev/null)
[ -n "$PORT" ] && [ -n "$TOKEN" ] || { cat >/dev/null; exit 0; }

# The hook runs as a child of the claude process; its tty identifies the terminal tab.
CLAUDE_PID="$PPID"
TTY=$(/bin/ps -o tty= -p "$CLAUDE_PID" 2>/dev/null | tr -d ' ')

ARGS=(
  -s -X POST
  -H "Content-Type: application/json"
  -H "Expect:"
  -H "X-Relay-Token: $TOKEN"
  -H "X-Relay-Workspace: $WS"
  -H "X-Relay-Pid: $CLAUDE_PID"
  -H "X-Relay-Tty: $TTY"
  -H "X-Relay-Term: ${TERM_PROGRAM:-}"
  -H "X-Relay-Bundle: ${__CFBundleIdentifier:-}"
  -H "X-Relay-Herdr-Pane: ${HERDR_PANE_ID:-}"
  -H "X-Relay-Herdr-Socket: ${HERDR_SOCKET_PATH:-}"
  -H "X-Relay-Tmux: ${TMUX:-}"
  -H "X-Relay-Tmux-Pane: ${TMUX_PANE:-}"
  -H "X-Relay-Iterm-Session: ${ITERM_SESSION_ID:-}"
  -H "X-Relay-Entrypoint: ${CLAUDE_CODE_ENTRYPOINT:-}"
  "http://127.0.0.1:$PORT/hook/$EVENT"
)

if [ "$EVENT" = "PermissionRequest" ]; then
  # Blocks until the user answers in Relay (or in the terminal, which kills this hook).
  # Relay prints the decision JSON; an empty reply means "let the terminal handle it".
  exec /usr/bin/curl -f --connect-timeout 1 -m 86400 --data-binary @- "${ARGS[@]}" 2>/dev/null
fi

if [ "$EVENT" = "Wait" ]; then
  # Registered as an asyncRewake Stop hook: runs in the background after each turn and waits for a
  # message you send from Relay. Exit 2 wakes the agent with the message (read from stderr).
  # Exit 0 means "nothing to deliver": you typed in the agent yourself, the session ended, or
  # Relay has been unreachable for 2 minutes. Shorter outages (a Relay restart) are retried.
  # (A background job gets /dev/null as stdin, so the payload is saved to a file first.)
  IN=$(mktemp -t relay-in) || exit 0
  OUT=$(mktemp -t relay-out) || { rm -f "$IN"; exit 0; }
  cat > "$IN"
  CURL=""
  trap '[ -n "$CURL" ] && kill $CURL 2>/dev/null; rm -f "$IN" "$OUT"; exit 0' TERM INT HUP
  FAILED_SINCE=""
  while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    PORT=$(/usr/bin/plutil -extract port raw -o - "$CONF" 2>/dev/null)
    TOKEN=$(/usr/bin/plutil -extract token raw -o - "$CONF" 2>/dev/null)
    : > "$OUT"
    /usr/bin/curl -f -s --connect-timeout 2 -m 86400 --data-binary @"$IN" -o "$OUT" \
      -H "Content-Type: application/json" -H "Expect:" \
      -H "X-Relay-Token: $TOKEN" -H "X-Relay-Workspace: $WS" -H "X-Relay-Pid: $CLAUDE_PID" \
      -H "X-Relay-Tty: $TTY" -H "X-Relay-Term: ${TERM_PROGRAM:-}" -H "X-Relay-Bundle: ${__CFBundleIdentifier:-}" \
      -H "X-Relay-Herdr-Pane: ${HERDR_PANE_ID:-}" -H "X-Relay-Herdr-Socket: ${HERDR_SOCKET_PATH:-}" \
      -H "X-Relay-Tmux: ${TMUX:-}" -H "X-Relay-Tmux-Pane: ${TMUX_PANE:-}" \
      -H "X-Relay-Iterm-Session: ${ITERM_SESSION_ID:-}" -H "X-Relay-Entrypoint: ${CLAUDE_CODE_ENTRYPOINT:-}" \
      "http://127.0.0.1:$PORT/hook/Wait" 2>/dev/null &
    CURL=$!
    wait $CURL
    STATUS=$?
    CURL=""
    if [ $STATUS -eq 0 ]; then
      if [ -s "$OUT" ]; then
        cat "$OUT" >&2
        rm -f "$IN" "$OUT"
        exit 2
      fi
      break   # Relay answered "nothing to deliver"
    fi
    NOW=$(date +%s)
    [ -z "$FAILED_SINCE" ] && FAILED_SINCE=$NOW
    [ $((NOW - FAILED_SINCE)) -ge 120 ] && break
    sleep 5
  done
  rm -f "$IN" "$OUT"
  exit 0
fi

# Everything else is fire-and-forget so Claude Code is never slowed down.
PAYLOAD=$(cat)
( printf '%s' "$PAYLOAD" | /usr/bin/curl --connect-timeout 1 -m 5 --data-binary @- "${ARGS[@]}" >/dev/null 2>&1 & ) >/dev/null 2>&1
exit 0
