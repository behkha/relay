#!/bin/bash
# Records the animated mascot for the README from Relay's mascot recording mode.
# Only the mascot's own transparent window is recorded; nothing else starts (no hook server,
# hotkeys or settings), so it can run while Relay itself is running.
# Needs macOS 14+, ffmpeg, and Screen Recording permission for the terminal you run it from.
# Writes an animated WebP with transparency (cwebp and webpmux, from `brew install webp`), or an
# APNG when those are missing. Both keep alpha and GitHub shows both in <img>; the WebP is a
# fraction of the size.
#   scripts/record-mascot.sh [idle|reel|busy] [output path]   (default: idle, docs/mascot.webp)
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo "ffmpeg is required (brew install ffmpeg)"; exit 1; }

SCENE="${1:-idle}"
OUT="${2:-}"
# The glow is soft, so 384 px still looks sharp at 192-256 pt; with 16 fps that keeps a
# six-second loop near 1.5 MB. Alpha below quality 80 shows rings in the glow.
SIZE="${MASCOT_SIZE:-384}"
FPS="${MASCOT_FPS:-16}"
QUALITY="${MASCOT_QUALITY:-50}"
ALPHA_QUALITY="${MASCOT_ALPHA_QUALITY:-80}"
# The window leaves room for droplets and marks that idle never shows; 0.72 keeps only the
# middle of it (the faintest glow included) so the cloud fills the picture. Use 1 for reel and busy.
CROP="${MASCOT_CROP:-$([ "$SCENE" = idle ] && echo 0.72 || echo 1)}"
if command -v cwebp >/dev/null && command -v webpmux >/dev/null; then FORMAT=webp; else FORMAT=apng; fi
[ -n "$OUT" ] || OUT="docs/mascot.$([ "$FORMAT" = webp ] && echo webp || echo png)"
case "$OUT" in *.webp) FORMAT=webp ;; *.png|*.apng) FORMAT=apng ;; esac
if [ "$FORMAT" = webp ] && ! { command -v cwebp && command -v webpmux; } >/dev/null; then
  echo "cwebp and webpmux are required for .webp output (brew install webp)"; exit 1
fi

echo "==> Compiling (release)"
swift build -c release --arch arm64 2>&1 | grep -vE "search path .* not found" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Relay"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "==> Recording the \"$SCENE\" scene (a few seconds; a cloud appears at the bottom right)"
RELAY_MASCOT="$SCENE" RELAY_MASCOT_OUT="$TMP/raw" "$BIN"
[ -s "$TMP/raw/f00000.png" ] || { echo "recording failed"; exit 1; }

LEN=$(sed -n 's/^length=//p' "$TMP/raw/info.txt")
TAIL=$(sed -n 's/^tail=//p' "$TMP/raw/info.txt")
RAWFPS=$(sed -n 's/^fps=//p' "$TMP/raw/info.txt")
echo "==> Encoding ${LEN}s at ${FPS} fps, ${SIZE} px"
# The last `tail` seconds are faded over the first ones, so the end runs into the start
# without a jump. Everything stays RGBA with straight alpha.
mkdir -p "$TMP/out"
ffmpeg -y -v error -framerate "$RAWFPS" -i "$TMP/raw/f%05d.png" -filter_complex "
  [0:v]format=rgba,fps=$FPS,crop=iw*$CROP:ih*$CROP,scale=$SIZE:$SIZE:flags=lanczos,split=3[a][b][c];
  [a]trim=start=0:end=$TAIL,setpts=PTS-STARTPTS[head];
  [b]trim=start=$TAIL:end=$LEN,setpts=PTS-STARTPTS[body];
  [c]trim=start=$LEN,setpts=PTS-STARTPTS[tail];
  [tail][head]xfade=transition=fade:duration=$TAIL:offset=0,format=rgba[seam];
  [seam][body]concat=n=2:v=1,format=rgba[v]" \
  -map "[v]" -start_number 0 "$TMP/out/f%05d.png"

mkdir -p "$(dirname "$OUT")"
if [ "$FORMAT" = webp ]; then
  # Each frame on its own, so the soft glow's alpha can be lossy too (img2webp keeps alpha
  # lossless, which triples the size), then stitched into one looping animation.
  DELAY=$((1000 / FPS))
  ls "$TMP"/out/f*.png | xargs -P "$(sysctl -n hw.ncpu)" -I{} \
    cwebp -quiet -q "$QUALITY" -m 6 -alpha_q "$ALPHA_QUALITY" -alpha_filter best {} -o {}.webp
  ARGS=()
  for f in "$TMP"/out/f*.png.webp; do ARGS+=(-frame "$f" "+$DELAY+0+0+0-b"); done
  webpmux "${ARGS[@]}" -loop 0 -bgcolor 0,0,0,0 -o "$OUT" >/dev/null
else
  ffmpeg -y -v error -framerate "$FPS" -i "$TMP/out/f%05d.png" -plays 0 -f apng "$OUT"
fi
echo "Done: $OUT ($(( $(stat -f %z "$OUT") / 1024 )) KB, $(ls "$TMP"/out/f*.png | wc -l | tr -d ' ') frames)"
if [ -n "${MASCOT_FRAMES:-}" ]; then mkdir -p "$MASCOT_FRAMES"; cp "$TMP"/out/f*.png "$MASCOT_FRAMES"/; fi
