#!/bin/bash
# Builds Relay.app (release) into ./build. Needs only the Xcode Command Line Tools.
#   scripts/build.sh            build
#   scripts/build.sh --install  build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/build/Relay.app"
VERSION="1.0.0"

echo "==> Compiling (release)"
set +e
swift build -c release --arch arm64 2>&1 | grep -vE "search path .* not found"
STATUS=${PIPESTATUS[0]}
set -e
[ "$STATUS" -eq 0 ] || { echo "build failed (swift build exit $STATUS)"; exit 1; }
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Relay"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Relay"
cp Resources/relay-hook.sh Resources/remote.html "$APP/Contents/Resources/"

if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  echo "==> Drawing icon"
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset 2>&1 | grep -vE "search path" || true
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Relay</string>
  <key>CFBundleDisplayName</key><string>Relay</string>
  <key>CFBundleIdentifier</key><string>com.behkha.relay</string>
  <key>CFBundleExecutable</key><string>Relay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Relay listens only while you hold a voice message for your agents.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Relay turns your voice message into text for your agents.</string>
  <key>NSAppleEventsUsageDescription</key><string>Relay types your answers into the terminal tab where the agent is running.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Relay serves the inbox to your phone on this network.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - --entitlements /dev/stdin "$APP" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT
codesign --verify --strict "$APP" && echo "    signature ok"

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications"
  pkill -x Relay 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Relay.app
  cp -R "$APP" /Applications/
  echo "    /Applications/Relay.app"
fi
echo "Done: $APP"
