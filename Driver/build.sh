#!/usr/bin/env bash
# Driver/build.sh — build, assemble, and sign atmos-control.driver
# Uses only CLT clang; no Xcode required.
#
# Environment (see scripts/lib/signing.sh):
#   ATMOS_VERSION=X.Y.Z   stamped into the bundle's Info.plist (default: latest vX.Y.Z tag, else 0.0.0)
#   ATMOS_BUILD=N         CFBundleVersion (default: ATMOS_VERSION)
#   SIGN_IDENTITY=name    exact code-signing identity name; unset or "-" = ad hoc (default)
#
# Loading: this bundle has only been tested on a Mac with SIP disabled. The HAL plug-in host
# (Core-Audio-Driver-Service) runs with library validation disabled, so a self-signed or
# ad-hoc signature is expected to load with SIP on as well, but that is not verified yet.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../scripts/lib/signing.sh"
atmos_resolve_version
atmos_resolve_identity

SOURCES="$SCRIPT_DIR/Sources/AtmosDriver.c"
INFO_PLIST="$SCRIPT_DIR/Info.plist"

BUILD_DIR="$SCRIPT_DIR/.build"
BUNDLE_DIR="$BUILD_DIR/atmos-control.driver"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
BINARY="$MACOS_DIR/atmos-control"

SDK=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")

echo "==> SDK: $SDK"
echo "==> Building atmos-control.driver …"

# ── 1. Compile & link as a bundle ──────────────────────────────────────────
rm -rf "$BUNDLE_DIR"   # start clean so no stale files end up inside the signed bundle
mkdir -p "$MACOS_DIR"

clang \
    -arch arm64 \
    -mmacosx-version-min=12.0 \
    -isysroot "$SDK" \
    -bundle \
    -o "$BINARY" \
    "$SOURCES" \
    -framework CoreAudio \
    -framework CoreFoundation \
    -framework AudioToolbox \
    -Wall \
    -Wextra \
    -Wno-unused-parameter \
    -O2

echo "==> Binary:  $BINARY"

# ── 2. Copy Info.plist, stamp the version ──────────────────────────────────
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleShortVersionString -string "$ATMOS_VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$ATMOS_BUILD" "$CONTENTS_DIR/Info.plist"
echo "==> Info.plist copied (version $ATMOS_VERSION, build $ATMOS_BUILD)."

# ── 3. Code sign ───────────────────────────────────────────────────────────
atmos_sign "$BUNDLE_DIR"
echo "==> Bundle signed ($SIGN_NAME)."

# ── 4. Verify ──────────────────────────────────────────────────────────────
echo ""
echo "=== codesign verify ==="
atmos_check_signature "$BUNDLE_DIR"

echo ""
echo "=== Bundle layout ==="
find "$BUNDLE_DIR" -not -type d | sort

echo ""
echo "✓  Done: $BUNDLE_DIR"
