#!/usr/bin/env bash
# uninstall.sh — remove atmos-control.
#
# Usage:
#   ./uninstall.sh                 remove the app from /Applications
#   ./uninstall.sh --with-driver   also remove the audio driver (privileged)
#
# Environment overrides (for testing without touching system locations):
#   PREFIX=/some/dir   remove the app from $PREFIX instead of /Applications
#   DRY_RUN=1          print every privileged command instead of running it
#
# This script never changes your default output device and never changes system volume.

set -euo pipefail

PREFIX="${PREFIX:-/Applications}"
DRY_RUN="${DRY_RUN:-0}"
WITH_DRIVER=0

APP_NAME="atmos-control.app"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
DRIVER_DEST="$HAL_DIR/atmos-control.driver"

for arg in "$@"; do
    case "$arg" in
        --with-driver) WITH_DRIVER=1 ;;
        -h|--help)
            sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
    esac
done

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

priv() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '    [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# ── App ─────────────────────────────────────────────────────────────────────
DEST_APP="$PREFIX/$APP_NAME"
if [ -e "$DEST_APP" ]; then
    info "Removing $DEST_APP"
    rm -rf "$DEST_APP"
else
    info "App not present at $DEST_APP — nothing to remove."
fi

# ── Driver (optional, privileged) ───────────────────────────────────────────
echo
if [ "$WITH_DRIVER" = "1" ]; then
    warn "Removing the audio driver requires administrator (sudo) rights."
    warn "When coreaudiod restarts, your audio devices will blink out for about a second — this is expected."
    info "Removing driver from $HAL_DIR"
    priv sudo rm -rf "$DRIVER_DEST"
    # kickstart is refused with SIP on (macOS 14.4+); coreaudiod is KeepAlive, so a kill makes
    # launchd restart it.
    priv sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null \
        || priv sudo killall coreaudiod \
        || warn "coreaudiod could not be restarted: the driver is gone after the next restart of the Mac."
    info "Driver removed."
else
    cat <<EOT
    Driver left in place (run again with --with-driver to remove it automatically).
    To remove it by hand, run these privileged commands:

        sudo rm -rf "$DRIVER_DEST"
        sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
        (if that is refused, as with SIP on: sudo killall coreaudiod)

    (coreaudiod restart makes audio devices blink for about a second.)
EOT
fi

# ── Leftovers ───────────────────────────────────────────────────────────────
echo
info "Done."
cat <<'EOT'

    Nothing else is left behind: atmos-control installs no LaunchAgents or LaunchDaemons
    and writes no preferences of its own (it only reads Apple Music's Dolby Atmos setting
    while running, and never modifies it). There is no defaults domain to clean up.
EOT
