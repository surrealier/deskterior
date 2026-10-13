#!/usr/bin/env bash
# Imports the optional self-signed Code Signing identity (docs/SIGNING.md) into a throwaway keychain on CI
# and exports SIGN_IDENTITY for scripts/build-app.sh. Portable to macOS's bash 3.2.
#
# Usage: scripts/ci-import-identity.sh           import from $SIGNING_P12_BASE64 / $SIGNING_P12_PASSWORD
#        scripts/ci-import-identity.sh cleanup   delete the throwaway keychain (safe to run when absent)
#
# Environment:
#   SIGNING_P12_BASE64    base64 of the .p12 (identity + private key); empty = stay ad-hoc and exit 0
#   SIGNING_P12_PASSWORD  the .p12 export password (must be non-empty)
#   CI_KEYCHAIN           keychain path (default $RUNNER_TEMP/deskterior-signing.keychain-db)
#   GITHUB_ENV            when set (GitHub Actions), SIGN_IDENTITY is appended there for later steps
#
# It edits the user keychain search list, so outside CI (CI != true) it refuses unless ALLOW_LOCAL=1.
set -euo pipefail

die() {
  echo "ci-import-identity: $*" >&2
  exit 1
}

KEYCHAIN="${CI_KEYCHAIN:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/deskterior-signing.keychain-db}"

case "${1:-import}" in
  cleanup)
    if security delete-keychain "$KEYCHAIN" 2>/dev/null; then
      echo "ci-import-identity: deleted $KEYCHAIN"
    else
      echo "ci-import-identity: no keychain at $KEYCHAIN"
    fi
    exit 0
    ;;
  import) ;;
  *) die "usage: $0 [import|cleanup]" ;;
esac

if [ "${CI:-}" != "true" ] && [ "${ALLOW_LOCAL:-}" != "1" ]; then
  die "refusing to edit the keychain search list outside CI (set ALLOW_LOCAL=1 to override)"
fi
if [ -z "${SIGNING_P12_BASE64:-}" ]; then
  echo "ci-import-identity: SIGNING_P12_BASE64 is empty; the build stays ad-hoc signed"
  exit 0
fi
[ -n "${SIGNING_P12_PASSWORD:-}" ] || die "SIGNING_P12_PASSWORD is empty (export the .p12 with a password)"

KEYCHAIN_PASSWORD="$(uuidgen)"
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$KEYCHAIN_PASSWORD"; fi

P12="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/deskterior-signing.XXXXXX")"
trap 'rm -f "$P12"' EXIT
printf '%s' "$SIGNING_P12_BASE64" | base64 --decode > "$P12" || die "SIGNING_P12_BASE64 is not valid base64"

security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -f pkcs12 -P "$SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# Put the throwaway keychain first in the user search list so codesign finds the identity.
SEARCH=("$KEYCHAIN")
while IFS= read -r entry; do
  entry="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  if [ -n "$entry" ] && [ "$entry" != "$KEYCHAIN" ]; then SEARCH+=("$entry"); fi
done <<EOF
$(security list-keychains -d user)
EOF
security list-keychains -d user -s "${SEARCH[@]}"

# Self-signed certificates are untrusted, so look at all identities (no -v); codesign accepts the SHA-1.
IDENTITIES="$(security find-identity -p codesigning "$KEYCHAIN")"
HASH="$(printf '%s\n' "$IDENTITIES" | awk '/^[[:space:]]*[0-9]+\)/ && !h { h = $2 } END { print h }')"
NAME="$(printf '%s\n' "$IDENTITIES" | awk -F'"' '/^[[:space:]]*[0-9]+\)/ && !n { n = $2 } END { print n }')"
[ -n "$HASH" ] || die "the .p12 holds no code signing identity"

echo "ci-import-identity: imported \"$NAME\" ($HASH) into $KEYCHAIN"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "SIGN_IDENTITY=$HASH" >> "$GITHUB_ENV"
else
  echo "export SIGN_IDENTITY=$HASH"
fi
