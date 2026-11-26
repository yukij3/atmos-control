# scripts/lib/signing.sh — shared version + code-signing helpers.
# Sourced (not executed) by App/build-app.sh, Driver/build.sh and scripts/release.sh.
#
# Environment:
#   SIGN_IDENTITY   code-signing identity. Unset, empty or "-" = ad hoc (local dev default).
#                   Otherwise the EXACT certificate common name (or its SHA-1) of an identity
#                   in your keychain, e.g. SIGN_IDENTITY=dmitrijtretakov (self-signed).
#                   Apple-issued identities (Developer ID, Apple Development, ...) are refused:
#                   this project is signed self-signed or ad hoc only, never notarized.
#   ATMOS_VERSION   marketing version X.Y.Z written into the bundles' Info.plist.
#                   Default: latest vX.Y.Z git tag, else 0.0.0.
#   ATMOS_BUILD     CFBundleVersion. Default: same as ATMOS_VERSION.

# Never sign with Apple-issued identities, not even as a fallback. The explicit entries
# cover an identity that lives in this keychain but must not be used for this project.
ATMOS_DENIED_IDENTITY_RE='Developer ID|Apple Development|Apple Distribution|Mac Developer|Mac App Distribution|3rd Party Mac|iPhone (Developer|Distribution)|Konstantin Arefev|5ZJZWZ4U22|5F931AB63C44157980A4DD3987EE661156E66B65'

atmos_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

atmos_default_version() {
    local repo tag
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    tag="$(git -C "$repo" describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
    if [ -n "$tag" ]; then printf '%s\n' "${tag#v}"; else printf '0.0.0\n'; fi
}

# Sets ATMOS_VERSION / ATMOS_BUILD (validated).
atmos_resolve_version() {
    ATMOS_VERSION="${ATMOS_VERSION:-$(atmos_default_version)}"
    ATMOS_BUILD="${ATMOS_BUILD:-$ATMOS_VERSION}"
    [[ "$ATMOS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || atmos_die "ATMOS_VERSION must be X.Y.Z (got '$ATMOS_VERSION')"
    [[ "$ATMOS_BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
        || atmos_die "ATMOS_BUILD must be up to three dot-separated integers (got '$ATMOS_BUILD')"
}

# Resolves SIGN_IDENTITY to an exact keychain identity.
# Sets SIGN_NAME (certificate common name, or "ad hoc") and SIGN_ARG (value for codesign --sign:
# the SHA-1 hash, so codesign never does its own substring matching, or "-").
atmos_resolve_identity() {
    local want="${SIGN_IDENTITY:-}"
    if [ -z "$want" ] || [ "$want" = "-" ]; then
        SIGN_NAME="ad hoc"; SIGN_ARG="-"; return 0
    fi
    if printf '%s' "$want" | grep -Eqi "$ATMOS_DENIED_IDENTITY_RE"; then
        atmos_die "refusing to sign with '$want': Apple-issued identities are not used for this project"
    fi
    # Not -v: a self-signed certificate is listed as CSSMERR_TP_NOT_TRUSTED, which is
    # expected and does not stop codesign from using it.
    local matches
    matches="$(security find-identity -p codesigning 2>/dev/null \
        | sed -nE 's/^[[:space:]]+[0-9]+\) ([0-9A-F]{40}) "(.*)".*$/\1	\2/p' \
        | awk -F '\t' -v w="$want" '($2 == w || toupper($1) == toupper(w)) && !seen[$1]++')"
    local n
    n="$(printf '%s' "$matches" | grep -c . || true)"
    [ "$n" = "1" ] || atmos_die "expected exactly one code-signing identity named '$want' in the keychain, found $n (see: security find-identity -p codesigning)"
    SIGN_ARG="$(printf '%s' "$matches" | cut -f1)"
    SIGN_NAME="$(printf '%s' "$matches" | cut -f2)"
    if printf '%s %s' "$SIGN_NAME" "$SIGN_ARG" | grep -Eqi "$ATMOS_DENIED_IDENTITY_RE"; then
        atmos_die "refusing to sign with '$SIGN_NAME': Apple-issued identities are not used for this project"
    fi
}

# atmos_sign <bundle>  — sign with the resolved identity (no hardened runtime, no timestamp).
atmos_sign() {
    codesign --force --sign "$SIGN_ARG" --timestamp=none "$1"
}

# atmos_check_signature <bundle>  — strict verify, then confirm the signing authority is
# exactly the resolved identity (or ad hoc) and that no Apple certificate is in the chain.
atmos_check_signature() {
    local path="$1" info out
    if ! out="$(codesign --verify --deep --strict --verbose=2 "$path" 2>&1)"; then
        printf '%s\n' "$out" >&2
        atmos_die "codesign --verify --deep --strict failed for $path"
    fi
    printf '%s\n' "$out" | sed 's/^/    /'
    info="$(codesign -dvv "$path" 2>&1)"
    if [ "$SIGN_ARG" = "-" ]; then
        printf '%s\n' "$info" | grep -q '^Signature=adhoc$' || atmos_die "$path is not ad-hoc signed"
    else
        local auth
        auth="$(printf '%s\n' "$info" | sed -n 's/^Authority=//p')"
        [ "$auth" = "$SIGN_NAME" ] \
            || atmos_die "$path: unexpected signing authority chain: $(printf '%s' "$auth" | tr '\n' '|')"
    fi
    if printf '%s\n' "$info" | grep '^Authority=' | grep -Eqi "Apple|$ATMOS_DENIED_IDENTITY_RE"; then
        atmos_die "$path carries an Apple-issued signature; refusing"
    fi
    printf '%s\n' "$info" | grep -E '^(Identifier|Authority|Signature|TeamIdentifier)=' | sed 's/^/    /'
}
