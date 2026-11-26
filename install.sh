#!/usr/bin/env bash
# install.sh — build and install atmos-control from a clean checkout.
#
# Idempotent: safe to run repeatedly (also used for updates after `git pull`).
#
# Usage:
#   ./install.sh                 build + install the app into /Applications
#   ./install.sh --with-driver   also build AND install the 12-channel audio driver
#                                 (privileged; needed only for the two loopback modes)
#
# Environment overrides (for testing without touching system locations):
#   PREFIX=/some/dir   install the app into $PREFIX instead of /Applications
#   DRY_RUN=1          print every privileged command instead of running it
#
# This script never changes your default output device, never changes system
# volume, and — without --with-driver — never touches system locations at all.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

PREFIX="${PREFIX:-/Applications}"
DRY_RUN="${DRY_RUN:-0}"
WITH_DRIVER=0

APP_NAME="atmos-control.app"
DIST_APP="$REPO_ROOT/dist/$APP_NAME"
DRIVER_SRC="$REPO_ROOT/Driver/.build/atmos-control.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
DRIVER_DEST="$HAL_DIR/atmos-control.driver"

for arg in "$@"; do
    case "$arg" in
        --with-driver) WITH_DRIVER=1 ;;
        -h|--help)
            sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
    esac
done

info()  { printf '==> %s\n' "$*"; }
warn()  { printf 'WARNING: %s\n' "$*" >&2; }
fail()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Run a privileged command, or print it under DRY_RUN=1.
priv() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '    [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# ── (a) Preflight ───────────────────────────────────────────────────────────
info "Preflight checks"

if [ "$(uname -s)" != "Darwin" ]; then
    fail "atmos-control only runs on macOS."
fi

if [ "$(uname -m)" != "arm64" ]; then
    fail "atmos-control requires an Apple Silicon Mac (arm64). Detected: $(uname -m)."
fi

OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$OS_MAJOR" -lt 26 ] 2>/dev/null; then
    fail "atmos-control requires macOS 26 (Tahoe) or newer. Detected: $(sw_vers -productVersion)."
fi

if ! xcode-select -p >/dev/null 2>&1; then
    fail "Xcode command line tools not found. Install them with: xcode-select --install"
fi

if ! command -v swift >/dev/null 2>&1; then
    fail "'swift' not found on PATH. Install the Xcode command line tools: xcode-select --install"
fi

# The UI is Rust (Rune): cargo builds it. rustup's ~/.cargo/bin may be missing from PATH in a
# non-login shell, so look there too.
if ! command -v cargo >/dev/null 2>&1 && [ -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" ]; then
    PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"; export PATH
fi
if ! command -v cargo >/dev/null 2>&1; then
    fail "'cargo' not found. atmos-control's UI is written in Rust. Install Rust with rustup:
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  (see https://rustup.rs), then open a new terminal (or run: . \"\$HOME/.cargo/env\") and run ./install.sh again.
  The exact toolchain is pinned in rust-toolchain.toml; rustup downloads it on the first build."
fi

info "OK: Apple Silicon, macOS $(sw_vers -productVersion), swift and cargo present"

# ── (b)+(c) Build the engine (Swift) and the UI (Rust), assemble dist/ ─────
# App/build-app.sh runs `swift build -c release --product AtmosCore` (the engine dylib) and
# `cargo build --release` (the UI binary), then assembles and signs the bundle.
info "Building and assembling the app bundle (App/build-app.sh)"
bash "$REPO_ROOT/App/build-app.sh" release
[ -d "$DIST_APP" ] || fail "expected bundle not found: $DIST_APP"

# ── (d) Install the app into PREFIX ─────────────────────────────────────────
info "Installing $APP_NAME into $PREFIX"
mkdir -p "$PREFIX"
DEST_APP="$PREFIX/$APP_NAME"
if [ -e "$DEST_APP" ]; then
    info "Replacing existing $DEST_APP"
    rm -rf "$DEST_APP"
fi
cp -R "$DIST_APP" "$DEST_APP"
info "Installed: $DEST_APP"

# ── (e) Driver (optional, privileged) ───────────────────────────────────────
echo
info "Audio driver (loopback capture modes)"
cat <<'EOT'
    The driver is ONLY needed for the 'Surround 7.1.4' and 'Stereo (virtual device)'
    capture modes. The default 'Personalized (headphones)' mode needs NO driver.
EOT

# Always build the driver (building is safe and touches nothing privileged).
info "Building the driver (Driver/build.sh)"
bash "$REPO_ROOT/Driver/build.sh" >/dev/null 2>&1 || warn "driver build reported issues; see Driver/build.sh output"
if [ ! -d "$DRIVER_SRC" ]; then
    warn "driver bundle not found at $DRIVER_SRC — skipping driver install steps."
else
    if [ "$WITH_DRIVER" = "1" ]; then
        echo
        warn "Installing the audio driver requires administrator (sudo) rights."
        warn "When coreaudiod restarts, your audio devices will blink out for about a second — this is expected."
        info "Installing driver into $HAL_DIR"
        priv sudo mkdir -p "$HAL_DIR"
        if [ -e "$DRIVER_DEST" ]; then
            priv sudo rm -rf "$DRIVER_DEST"
        fi
        priv sudo cp -R "$DRIVER_SRC" "$DRIVER_DEST"
        priv sudo chown -R root:wheel "$DRIVER_DEST"
        priv sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
        info "Driver installed."
    else
        cat <<EOT

    Driver NOT installed (run again with --with-driver to install it automatically).
    To install it by hand later, run these privileged commands:

        sudo cp -R "$DRIVER_SRC" "$DRIVER_DEST"
        sudo chown -R root:wheel "$DRIVER_DEST"
        sudo launchctl kickstart -k system/com.apple.audio.coreaudiod

    (coreaudiod restart makes audio devices blink for about a second.)
EOT
    fi
fi

# ── (f) Final message ───────────────────────────────────────────────────────
echo
info "Done."
cat <<EOT

    Launch:   open "$DEST_APP"
              (atmos-control is a menu-bar app — look for its glyph at the top-right.)

    On first engine start, macOS will ask for the audio-capture (microphone/TCC)
    permission. Grant it — atmos-control needs it to read the system audio it spatializes.
EOT
