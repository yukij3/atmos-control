#!/bin/bash
# build-app.sh — bundle the SwiftPM AtmosControlApp binary into atmos-control.app
# (CLT-only, no Xcode). Menu-bar agent (LSUIElement). Ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="atmos-control"
BUNDLE_ID="dev.atmoscontrol.app"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> swift build -c $CONFIG --product AtmosControlApp"
swift build -c "$CONFIG" --product AtmosControlApp
BIN=".build/$CONFIG/AtmosControlApp"
[ -f "$BIN" ] || { echo "binary not found: $BIN"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>     <string>atmos-control</string>
  <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>15.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSAudioCaptureUsageDescription</key>
  <string>atmos-control captures system audio locally to render spatial audio through your headphones.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>atmos-control reads system audio from the virtual output device in order to spatialize it.</string>
  <key>NSMotionUsageDescription</key>
  <string>atmos-control uses AirPods head-motion to visualize and track your head position for spatial audio.</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"

echo "==> done: $APP"
echo "    launch:  open \"$APP\"      (menu-bar glyph appears top-right)"
echo "    preview: ATMOS_PREVIEW=1 open -n \"$APP\"   (opens the panel in a window)"
