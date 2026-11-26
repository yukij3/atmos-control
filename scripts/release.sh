#!/usr/bin/env bash
# scripts/release.sh — build, sign, verify and package an atmos-control release.
#
# Usage:
#   scripts/release.sh <X.Y.Z>             build + package into dist/release/<X.Y.Z>/ (no network)
#   scripts/release.sh <X.Y.Z> --publish   same, then tag v<X.Y.Z>, push the tag and create a
#                                          GitHub pre-release with the zips + SHA256SUMS.txt
#
# Options:
#   --publish        tag, push and create the GitHub release (asks for confirmation first)
#   --not-prerelease publish as a regular release instead of a pre-release
#
# Environment:
#   SIGN_IDENTITY    signing identity (default: dmitrijtretakov, the self-signed project cert;
#                    "-" = ad hoc). Apple-issued identities are refused. No notarization.
#   ALLOW_DIRTY=1    allow building from a dirty tree (refused together with --publish)
#
# Output (dist/release/<X.Y.Z>/):
#   atmos-control-<X.Y.Z>-macos-arm64.zip   the app
#   atmos-control-driver-<X.Y.Z>.zip        driver + install-driver.sh + UNINSTALL.txt
#   SHA256SUMS.txt                          checksums of both zips
#   NOTES.md                                release notes (used as the GitHub release body)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
. scripts/lib/signing.sh

info() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { atmos_die "$@"; }

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

VERSION=""
PUBLISH=0
PRERELEASE=1
for arg in "$@"; do
    case "$arg" in
        --publish)        PUBLISH=1 ;;
        --not-prerelease) PRERELEASE=0 ;;
        -h|--help)        usage; exit 0 ;;
        -*)               die "unknown option '$arg' (try --help)" ;;
        *)  [ -z "$VERSION" ] || die "version given twice"; VERSION="$arg" ;;
    esac
done
[ -n "$VERSION" ] || { usage; exit 2; }
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z (got '$VERSION')"
TAG="v$VERSION"

export SIGN_IDENTITY="${SIGN_IDENTITY-dmitrijtretakov}"
export ATMOS_VERSION="$VERSION"
export ATMOS_BUILD="$VERSION"

OUT="dist/release/$VERSION"
APP_ZIP="atmos-control-$VERSION-macos-arm64.zip"
DRIVER_DIR="atmos-control-driver-$VERSION"
DRIVER_ZIP="$DRIVER_DIR.zip"
APP="dist/atmos-control.app"
DRIVER="Driver/.build/atmos-control.driver"

# ── Preflight ───────────────────────────────────────────────────────────────
info "Preflight"
[ "$(uname -s)" = "Darwin" ] || die "macOS only"
[ "$(uname -m)" = "arm64" ]  || die "build on Apple Silicon (arm64); this Mac is $(uname -m)"
atmos_require_cargo
for tool in swift cargo clang codesign install_name_tool otool lipo ditto shasum plutil git; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found"
done

if [ -n "$(git status --porcelain)" ]; then
    if [ "$PUBLISH" = "1" ] || [ "${ALLOW_DIRTY:-0}" != "1" ]; then
        git status --short >&2
        die "working tree is not clean (commit or stash first; ALLOW_DIRTY=1 only for test builds)"
    fi
    warn "building from a dirty tree (ALLOW_DIRTY=1); do not publish these artifacts"
fi
COMMIT="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short=12 HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "    version $VERSION, commit $SHORT ($BRANCH)"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists locally"

if [ "$PUBLISH" = "1" ]; then
    command -v gh >/dev/null 2>&1 || die "'gh' not found (needed for --publish)"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"
    git fetch --quiet origin main --tags
    git merge-base --is-ancestor HEAD origin/main \
        || die "HEAD ($SHORT) is not on origin/main; merge and push first"
    git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 \
        && die "tag $TAG already exists on origin"
    ORIGIN_URL="$(git remote get-url origin)"
    GH_REPO="$(printf '%s\n' "$ORIGIN_URL" | sed -E 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)##; s#\.git$##')"
    [[ "$GH_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "cannot derive GitHub repo from origin '$ORIGIN_URL'"
    echo "    publishing to $GH_REPO"
else
    if git rev-parse -q --verify origin/main >/dev/null && ! git merge-base --is-ancestor HEAD origin/main; then
        warn "HEAD is not on origin/main (fine for a dry run; --publish would refuse)"
    fi
fi

atmos_resolve_identity
echo "    signing identity: $SIGN_NAME${SIGN_ARG:+ ($SIGN_ARG)}"
[ "$SIGN_ARG" = "-" ] && warn "ad-hoc signature: TCC permissions will not carry over between releases"

# ── Build ───────────────────────────────────────────────────────────────────
info "Building the app"
bash App/build-app.sh release

info "Building the driver"
bash Driver/build.sh

# ── Verify ──────────────────────────────────────────────────────────────────
check_bundle() {  # <bundle> <expected executable arch>
    local b="$1" exe v bv
    echo "  $b"
    atmos_check_signature "$b"
    v="$(plutil -extract CFBundleShortVersionString raw "$b/Contents/Info.plist")"
    bv="$(plutil -extract CFBundleVersion raw "$b/Contents/Info.plist")"
    [ "$v" = "$VERSION" ] && [ "$bv" = "$ATMOS_BUILD" ] \
        || die "$b: Info.plist version is $v ($bv), expected $VERSION ($ATMOS_BUILD)"
    exe="$b/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$b/Contents/Info.plist")"
    [ "$(lipo -archs "$exe")" = "$2" ] || die "$exe: architectures are '$(lipo -archs "$exe")', expected '$2'"
    # Nested code (the app's libAtmosCore.dylib): same arch, and no build-machine paths left.
    local code
    while IFS= read -r code; do
        [ -n "$code" ] && [ -f "$code" ] || continue
        [ "$(lipo -archs "$code")" = "$2" ] || die "$code: architectures are '$(lipo -archs "$code")', expected '$2'"
    done < <(atmos_nested_code "$b")
    if otool -l "$exe" $(atmos_nested_code "$b" | tr '\n' ' ') | grep -A2 LC_RPATH | grep -E '^ +path /(Users|private|var|tmp|Applications)/'; then
        die "$b: an rpath points into the build machine (see above)"
    fi
    echo "    version $v ($bv), arch $2"
}
info "Verifying signatures and versions"
check_bundle "$APP" arm64
check_bundle "$DRIVER" arm64

# ── Package ─────────────────────────────────────────────────────────────────
info "Packaging into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/atmos-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# --norsrc: ship no extended attributes (e.g. com.apple.provenance) from the build machine.
# Bundle signatures live in the bundle itself, so they survive.
ditto -c -k --norsrc --keepParent "$APP" "$OUT/$APP_ZIP"

mkdir -p "$STAGE/$DRIVER_DIR"
ditto --norsrc "$DRIVER" "$STAGE/$DRIVER_DIR/atmos-control.driver"
install -m 0755 scripts/release/install-driver.sh "$STAGE/$DRIVER_DIR/install-driver.sh"
install -m 0644 scripts/release/UNINSTALL-driver.txt "$STAGE/$DRIVER_DIR/UNINSTALL.txt"
ditto -c -k --norsrc --keepParent "$STAGE/$DRIVER_DIR" "$OUT/$DRIVER_ZIP"

# Re-verify what actually went into the zips.
info "Verifying the zipped bundles"
mkdir -p "$STAGE/check"
ditto -x -k "$OUT/$APP_ZIP" "$STAGE/check"
ditto -x -k "$OUT/$DRIVER_ZIP" "$STAGE/check"
atmos_check_signature "$STAGE/check/atmos-control.app" >/dev/null
atmos_check_signature "$STAGE/check/$DRIVER_DIR/atmos-control.driver" >/dev/null
[ -x "$STAGE/check/$DRIVER_DIR/install-driver.sh" ] || die "install-driver.sh lost its exec bit"
echo "    ok"

(cd "$OUT" && shasum -a 256 "$APP_ZIP" "$DRIVER_ZIP" > SHA256SUMS.txt)

# ── Release notes ───────────────────────────────────────────────────────────
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2: keep '&' literal below
NOTES="$(cat scripts/release/NOTES.md.in)"
SIGNER="$SIGN_NAME"
NOTES="${NOTES//@VERSION@/$VERSION}"
NOTES="${NOTES//@COMMIT@/$SHORT}"
NOTES="${NOTES//@APP_ZIP@/$APP_ZIP}"
NOTES="${NOTES//@DRIVER_ZIP@/$DRIVER_ZIP}"
NOTES="${NOTES//@DRIVER_DIR@/$DRIVER_DIR}"
NOTES="${NOTES//@SIGNER@/$SIGNER}"
NOTES="${NOTES//@CHECKSUMS@/$(cat "$OUT/SHA256SUMS.txt")}"
printf '%s\n' "$NOTES" > "$OUT/NOTES.md"
grep -q '@[A-Z_]*@' "$OUT/NOTES.md" && die "unreplaced placeholder in NOTES.md"

info "Artifacts"
(cd "$OUT" && ls -l "$APP_ZIP" "$DRIVER_ZIP" SHA256SUMS.txt NOTES.md && echo && cat SHA256SUMS.txt)

if [ "$PUBLISH" != "1" ]; then
    echo
    echo "Dry run complete; nothing was tagged or uploaded."
    echo "To publish:  scripts/release.sh $VERSION --publish"
    exit 0
fi

# ── Publish ─────────────────────────────────────────────────────────────────
[ -z "$(git status --porcelain)" ] || die "tree became dirty during the build; refusing to tag"
TITLE="atmos-control $VERSION"
info "About to publish"
echo "    git tag -a $TAG $SHORT -m \"$TITLE\""
echo "    git push origin $TAG"
echo "    gh release create $TAG --repo $GH_REPO $([ "$PRERELEASE" = 1 ] && echo --prerelease) --title \"$TITLE\" --notes-file $OUT/NOTES.md"
echo "        $OUT/$APP_ZIP $OUT/$DRIVER_ZIP $OUT/SHA256SUMS.txt"
printf 'Type the version (%s) to continue: ' "$VERSION"
read -r reply < /dev/tty
[ "$reply" = "$VERSION" ] || die "cancelled"

git tag -a "$TAG" "$COMMIT" -m "$TITLE"
git push origin "refs/tags/$TAG"
GH_ARGS=(release create "$TAG" --repo "$GH_REPO" --verify-tag --title "$TITLE" --notes-file "$OUT/NOTES.md")
[ "$PRERELEASE" = "1" ] && GH_ARGS+=(--prerelease)
gh "${GH_ARGS[@]}" "$OUT/$APP_ZIP" "$OUT/$DRIVER_ZIP" "$OUT/SHA256SUMS.txt"
info "Published $TAG"
