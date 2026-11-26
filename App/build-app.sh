#!/bin/bash
# build-app.sh — build atmos-control.app (CLT + Rust, no Xcode project). Menu-bar agent
# (LSUIElement).
#
#   Contents/MacOS/atmos-control             the Rust (Rune) UI: owns the main thread and the
#                                            NSApplication run loop          (crates/atmos-app)
#   Contents/Frameworks/libAtmosCore.dylib   the Swift engine behind a C ABI (SwiftPM AtmosCore,
#                                            Sources/AtmosCoreABI/include/atmos_core.h)
#
# One process, one bundle, one TCC identity: the dylib runs inside the app's process.
#
# Usage: App/build-app.sh [release|debug]   (Swift configuration; the Rust binary is always
#                                            cargo --release)
# Environment (see scripts/lib/signing.sh):
#   ATMOS_VERSION=X.Y.Z   CFBundleShortVersionString (default: latest vX.Y.Z tag, else 0.0.0)
#   ATMOS_BUILD=N         CFBundleVersion (default: ATMOS_VERSION)
#   SIGN_IDENTITY=name    exact code-signing identity name; unset or "-" = ad hoc (default)
#
# No hardened runtime and no entitlements: the app is not notarized, and the TCC prompts it
# needs (audio capture, microphone, motion) only require the usage strings below. Without the
# hardened runtime there is no library validation, so the nested dylib only has to carry a
# valid signature of its own (signed first, with the same identity as the bundle).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/signing.sh
atmos_resolve_version
atmos_resolve_identity
atmos_require_cargo

CONFIG="${1:-release}"
case "$CONFIG" in release|debug) ;; *) atmos_die "usage: App/build-app.sh [release|debug]" ;; esac
APP_NAME="atmos-control"
BUNDLE_ID="dev.atmoscontrol.app"
DIST="dist"
APP="$DIST/$APP_NAME.app"
LIB_NAME="libAtmosCore.dylib"

echo "==> swift build -c $CONFIG --product AtmosCore"
swift build -c "$CONFIG" --product AtmosCore
LIB=".build/$CONFIG/$LIB_NAME"
[ -f "$LIB" ] || atmos_die "library not found: $LIB"

echo "==> cargo build --release --locked -p atmos-app"
# Link against the Swift configuration just built (the default lookup matches cargo's profile).
if [ "$CONFIG" = "release" ]; then
    cargo build --release --locked -p atmos-app
else
    ATMOS_CORE_LIB_DIR="$PWD/.build/$CONFIG" cargo build --release --locked -p atmos-app
fi
BIN="target/release/$APP_NAME"
[ -f "$BIN" ] || atmos_die "binary not found: $BIN"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$LIB" "$APP/Contents/Frameworks/$LIB_NAME"
chmod 0755 "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/Frameworks/$LIB_NAME"

# Drop the build machine's paths. The binary keeps @executable_path/../Frameworks (and loses
# the .build/<config> rpath cargo adds for running it in place); the dylib keeps
# /usr/lib/swift and @loader_path (and loses the toolchain directories SwiftPM adds). Both
# signatures are (re)made below, after this.
atmos_strip_rpaths() {  # <mach-o> <regex of rpaths to keep>
    local file="$1" keep="$2" rpath out
    while IFS= read -r rpath; do
        [ -n "$rpath" ] || continue
        printf '%s\n' "$rpath" | grep -Eq "$keep" && continue
        # (Its only output on success is the "will invalidate the code signature" warning.)
        if ! out="$(install_name_tool -delete_rpath "$rpath" "$file" 2>&1)"; then
            printf '%s\n' "$out" >&2
            atmos_die "install_name_tool -delete_rpath $rpath $file failed"
        fi
    done < <(otool -l "$file" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')
}
atmos_strip_rpaths "$APP/Contents/MacOS/$APP_NAME" '^@executable_path/\.\./Frameworks$'
atmos_strip_rpaths "$APP/Contents/Frameworks/$LIB_NAME" '^(/usr/lib/swift|@loader_path)$'
otool -l "$APP/Contents/MacOS/$APP_NAME" | grep -q '@executable_path/../Frameworks' \
    || atmos_die "$APP_NAME lost its @executable_path/../Frameworks rpath"
[ "$(otool -D "$APP/Contents/Frameworks/$LIB_NAME" | tail -1)" = "@rpath/$LIB_NAME" ] \
    || atmos_die "$LIB_NAME install name is not @rpath/$LIB_NAME"

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

# Nested code first (Contents/Frameworks), then the bundle; never --deep.
echo "==> codesign ($SIGN_NAME)"
atmos_sign_app "$APP"
atmos_check_signature "$APP"

echo "==> done: $APP  (version $ATMOS_VERSION, build $ATMOS_BUILD)"
echo "    launch:  open \"$APP\"      (menu-bar glyph appears top-right)"
echo "    mock:    target/release/$APP_NAME --mock   (the real UI on the mock engine)"
echo "    render:  target/release/$APP_NAME --snap panel.png --scale 2 --at 1.5"
