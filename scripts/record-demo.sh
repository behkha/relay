#!/bin/bash
# Records the README demo GIF (docs/demo.gif) from Relay's scripted demo mode.
# Everything on screen is mock data; only Relay's own windows are recorded.
# Needs macOS 15+, ffmpeg, and Screen Recording permission for the terminal you run it from.
#   scripts/record-demo.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo "ffmpeg is required (brew install ffmpeg)"; exit 1; }

echo "==> Compiling (release)"
swift build -c release --arch arm64 2>&1 | grep -vE "search path .* not found" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Relay"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "==> Recording (about 30 seconds; keep the mouse away from the right edge)"
RELAY_DEMO=1 RELAY_DEMO_OUT="$TMP/demo.mov" "$BIN"
[ -s "$TMP/demo.mov" ] || { echo "recording failed"; exit 1; }

echo "==> Encoding docs/demo.gif"
ffmpeg -y -v error -i "$TMP/demo.mov" -vf "fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" -loop 0 docs/demo.gif
echo "Done: docs/demo.gif ($(du -h docs/demo.gif | cut -f1))"
