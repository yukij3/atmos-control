#!/bin/bash
# install-driver.sh — install the atmos-control audio driver from this folder.
#
# Run it from Terminal (double-clicking a downloaded script is blocked by Gatekeeper):
#     bash install-driver.sh            show the plan, ask, then install
#     bash install-driver.sh --dry-run  only show the plan
#
# What it does: removes the download quarantine flag from atmos-control.driver,
# copies it to /Library/Audio/Plug-Ins/HAL (sudo), and restarts coreaudiod (sudo).
# Audio devices drop out for about a second while coreaudiod restarts.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/atmos-control.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
DEST="$HAL_DIR/atmos-control.driver"

DRY_RUN=0
case "${1:-}" in
    "") ;;
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "macOS only."
[ "$(uname -m)" = "arm64" ]  || fail "Apple Silicon (arm64) only; this Mac is $(uname -m)."
[ -d "$SRC" ] || fail "atmos-control.driver not found next to this script ($HERE)."
codesign --verify --strict "$SRC" 2>/dev/null \
    || fail "the driver's code signature does not verify; re-download the release zip."

echo "This will run:"
echo "  1. xattr -dr com.apple.quarantine \"$SRC\""
if [ -e "$DEST" ]; then
echo "  2. sudo rm -rf \"$DEST\"            (replace the installed copy)"
fi
echo "  3. sudo cp -R \"$SRC\" \"$HAL_DIR/\""
echo "  4. sudo chown -R root:wheel \"$DEST\""
echo "  5. sudo xattr -dr com.apple.quarantine \"$DEST\""
echo "  6. sudo launchctl kickstart -k system/com.apple.audio.coreaudiod"
echo
[ "$DRY_RUN" = "1" ] && { echo "(dry run, nothing changed)"; exit 0; }

printf 'Continue? [y/N] '
read -r answer
case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac

xattr -dr com.apple.quarantine "$SRC" 2>/dev/null || true
sudo mkdir -p "$HAL_DIR"
[ -e "$DEST" ] && sudo rm -rf "$DEST"
sudo cp -R "$SRC" "$HAL_DIR/"
sudo chown -R root:wheel "$DEST"
sudo xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod

echo
echo "Installed $DEST and restarted coreaudiod."
echo "Check: an output device named \"atmos-control\" should appear in"
echo "System Settings > Sound > Output (or: system_profiler SPAudioDataType | grep -i atmos)."
echo "If it does not appear, see the release notes about SIP."
