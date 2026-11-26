#!/bin/bash
# build-app.sh — bundle the SwiftPM AtmosControlApp binary into atmos-control.app
# (CLT-only, no Xcode). Menu-bar agent (LSUIElement).
#
# Usage: App/build-app.sh [release|debug]
# Environment (see scripts/lib/signing.sh):
#   ATMOS_VERSION=X.Y.Z   CFBundleShortVersionString (default: latest vX.Y.Z tag, else 0.0.0)
#   ATMOS_BUILD=N         CFBundleVersion (default: ATMOS_VERSION)
#   SIGN_IDENTITY=name    exact code-signing identity name; unset or "-" = ad hoc (default)
#
# No hardened runtime and no entitlements: the app is not notarized, and the TCC prompts it
# needs (audio capture, microphone, motion) only require the usage strings below.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/signing.sh
atmos_resolve_version
atmos_resolve_identity

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

# LSMinimumSystemVersion 26.0 is the supported floor that install.sh enforces and the README
# states. Package.swift's deployment target (macOS 15.0) only says the code compiles that far
# back; nothing below macOS 26 has been tested.
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
  <key>CFBundleShortVersionString</key> <string>$ATMOS_VERSION</string>
  <key>CFBundleVersion</key>         <string>$ATMOS_BUILD</string>
  <key>LSMinimumSystemVersion</key>  <string>26.0</string>
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

plutil -lint -s "$APP/Contents/Info.plist"

# The bundle contains a single executable and no nested code, so no --deep is needed.
echo "==> codesign ($SIGN_NAME)"
atmos_sign "$APP"
atmos_check_signature "$APP"

echo "==> done: $APP  (version $ATMOS_VERSION, build $ATMOS_BUILD)"
echo "    launch:  open \"$APP\"      (menu-bar glyph appears top-right)"
echo "    preview: ATMOS_PREVIEW=1 open -n \"$APP\"   (opens the panel in a window)"
