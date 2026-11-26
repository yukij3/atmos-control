#!/usr/bin/env bash
# scripts/release/bump-tap.sh — point the Homebrew casks in yukij3/homebrew-tap at a release.
#
# Usage: scripts/release/bump-tap.sh <X.Y.Z> <SHA256SUMS.txt>
#
# Sets `version` and `sha256` in Casks/atmos-control.rb and Casks/atmos-control-driver.rb,
# commits and pushes. Called by scripts/release.sh --publish after the GitHub release exists.
# Environment: TAP_REPO (default yukij3/homebrew-tap).
set -euo pipefail

[ $# -eq 2 ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
VERSION="$1"
SUMS="$2"
TAP_REPO="${TAP_REPO:-yukij3/homebrew-tap}"

sum_of() { awk -v f="$1" '$2 == f { print $1 }' "$SUMS"; }
APP_SHA="$(sum_of "atmos-control-$VERSION-macos-arm64.zip")"
DRIVER_SHA="$(sum_of "atmos-control-driver-$VERSION.zip")"
[ -n "$APP_SHA" ] && [ -n "$DRIVER_SHA" ] \
    || { echo "ERROR: $SUMS has no checksums for the $VERSION zips" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
gh repo clone "$TAP_REPO" "$TMP/tap" -- --quiet --depth 1

set_cask() { # <cask file> <sha256>
    sed -i '' -E "s/^(  version )\"[^\"]*\"/\1\"$VERSION\"/; s/^(  sha256 )\"[^\"]*\"/\1\"$2\"/" \
        "$TMP/tap/Casks/$1"
}
set_cask atmos-control.rb "$APP_SHA"
set_cask atmos-control-driver.rb "$DRIVER_SHA"

cd "$TMP/tap"
if git diff --quiet; then
    echo "$TAP_REPO already installs $VERSION"
    exit 0
fi
git commit -qam "atmos-control $VERSION"
git push -q origin HEAD
echo "$TAP_REPO now installs $VERSION"
