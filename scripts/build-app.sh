#!/usr/bin/env bash
# Builds, assembles and signs build/Deskterior.app (docs/DESIGN.md §6, §11). Portable to macOS's bash 3.2.
#
# Usage: scripts/build-app.sh [--version X.Y.Z] [--universal]
#
#   --version          CFBundleShortVersionString (default: latest git tag without the "v", else 0.0.0-dev)
#   --universal        shorthand for ARCHS="arm64 x86_64"
#
# Environment:
#   ARCHS              architectures to build, space-separated (default "arm64")
#   BUNDLE_ID          default io.github.<owner>.deskterior, where <owner> is the lowercased GitHub owner of
#                      the `origin` remote, else $GITHUB_REPOSITORY_OWNER, else "deskterior"
#   COPYRIGHT_OWNER    default: the holder named in LICENSE, else <owner>
#   SIGN_IDENTITY      codesign identity (default "-", ad-hoc; see docs/SIGNING.md)
#   ZIP=1              also write build/Deskterior-<version>.zip and build/Deskterior-<version>.zip.sha256
#   SWIFT_BUILD_FLAGS  extra `swift build` flags, e.g. "-j 2"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() {
  echo "build-app: $*" >&2
  exit 1
}

VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || die "--version needs a value"
      VERSION="$2"
      shift 2
      ;;
    --version=*)
      VERSION="${1#--version=}"
      shift
      ;;
    --universal)
      ARCHS="arm64 x86_64"
      shift
      ;;
    -h | --help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# --- Identity and version ------------------------------------------------------------------------------

github_owner() {
  local url re='(^|[@/])github\.com[:/]+([^/]+)/'
  url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$url" =~ $re ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
  elif [ -n "${GITHUB_REPOSITORY_OWNER:-}" ]; then
    printf '%s' "$GITHUB_REPOSITORY_OWNER"
  else
    printf 'deskterior'
  fi
}

OWNER="$(github_owner | tr '[:upper:]' '[:lower:]')"
BUNDLE_ID="${BUNDLE_ID:-io.github.$OWNER.deskterior}"
case "$BUNDLE_ID" in
  *[!A-Za-z0-9.-]* | .* | *. | *..*) die "invalid bundle id: '$BUNDLE_ID'" ;;
esac

if [ -z "${COPYRIGHT_OWNER:-}" ]; then
  COPYRIGHT_OWNER="$(sed -n 's/^Copyright (c) [0-9][0-9]*\(-[0-9][0-9]*\)\{0,1\} //p' LICENSE 2>/dev/null | head -n 1)"
  [ -n "$COPYRIGHT_OWNER" ] || COPYRIGHT_OWNER="$OWNER"
fi

if [ -z "$VERSION" ]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  [ -n "$VERSION" ] || VERSION="0.0.0-dev"
fi
VERSION="${VERSION#v}"
case "$VERSION" in
  "" | *[!0-9A-Za-z.+-]*) die "invalid version: '$VERSION'" ;;
esac

BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
IDENTITY="${SIGN_IDENTITY:--}"

ARCHS="${ARCHS:-arm64}"
for arch in $ARCHS; do
  case "$arch" in
    arm64 | x86_64) ;;
    *) die "unsupported arch '$arch' (use arm64 and/or x86_64)" ;;
  esac
done

for f in Packaging/Info.plist LICENSE THIRD_PARTY_NOTICES.md; do
  [ -f "$f" ] || die "missing $f"
done
[ -f Packaging/AppIcon.icns ] || die "missing Packaging/AppIcon.icns (run scripts/make-icon.sh)"

# --- Compile: one release build per triple, then lipo ----------------------------------------------------

BINS=()
for arch in $ARCHS; do
  triple="$arch-apple-macosx14.0"
  scratch=".build-release-$arch"
  echo "build-app: swift build -c release --triple $triple"
  # shellcheck disable=SC2086 # SWIFT_BUILD_FLAGS is a word list
  swift build -c release --product Deskterior --triple "$triple" --scratch-path "$scratch" ${SWIFT_BUILD_FLAGS:-}
  bin="$(swift build -c release --triple "$triple" --scratch-path "$scratch" --show-bin-path)/Deskterior"
  [ -x "$bin" ] || die "no executable at $bin"
  BINS+=("$bin")
done
[ ${#BINS[@]} -gt 0 ] || die "ARCHS is empty"

# --- Assemble ---------------------------------------------------------------------------------------------

APP="build/Deskterior.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Fonts"

if [ ${#BINS[@]} -eq 1 ]; then
  cp "${BINS[0]}" "$CONTENTS/MacOS/Deskterior"
else
  lipo -create -output "$CONTENTS/MacOS/Deskterior" "${BINS[@]}"
fi
# Drop debug symbols and the debug map (it records build-machine object paths); keeps exported symbols.
strip -S -x "$CONTENTS/MacOS/Deskterior"

PLIST="$CONTENTS/Info.plist"
cp Packaging/Info.plist "$PLIST"
fill() { # <key> <placeholder> <value>: substitutes the placeholder inside the key's template string
  local current
  current="$(plutil -extract "$1" raw -o - "$PLIST")"
  plutil -replace "$1" -string "${current//$2/$3}" "$PLIST"
}
fill CFBundleIdentifier __BUNDLE_ID__ "$BUNDLE_ID"
fill CFBundleShortVersionString __VERSION__ "$VERSION"
fill CFBundleVersion __BUILD__ "$BUILD"
fill NSHumanReadableCopyright __COPYRIGHT_OWNER__ "$COPYRIGHT_OWNER"
if grep -q '__[A-Z_]*__' "$PLIST"; then die "unfilled placeholder left in $PLIST"; fi
plutil -lint "$PLIST" >/dev/null

cp Packaging/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
cp Resources/Fonts/* "$CONTENTS/Resources/Fonts/"
cp LICENSE THIRD_PARTY_NOTICES.md "$CONTENTS/Resources/"
for lproj in Packaging/*.lproj; do
  if [ -d "$lproj" ]; then cp -R "$lproj" "$CONTENTS/Resources/"; fi
done

# Finder metadata and extended attributes make codesign refuse the bundle.
find "$APP" -name .DS_Store -delete
xattr -cr "$APP"

# --- Sign last (no --deep: the bundle has one executable), then verify -------------------------------------

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d -r - "$APP"

# --- Zip ---------------------------------------------------------------------------------------------------

ZIP_NAME=""
if [ "${ZIP:-0}" = "1" ]; then
  ZIP_NAME="Deskterior-$VERSION.zip"
  rm -f "build/$ZIP_NAME" "build/$ZIP_NAME.sha256"
  # No resource forks, extended attributes, quarantine or ACLs: they would add __MACOSX/ entries (the
  # signature lives in _CodeSignature, not in xattrs).
  ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$APP" "build/$ZIP_NAME"
  if unzip -Z1 "build/$ZIP_NAME" | grep -q '^__MACOSX/'; then die "zip contains __MACOSX entries"; fi
  (cd build && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
fi

SIGNATURE="$(codesign -d --verbose=2 "$APP" 2>&1 | awk -F= '/^(Authority|Signature)=/ && !s { print $2; s = 1 }')"
echo
echo "build-app: $APP"
echo "  version     $VERSION (build $BUILD)"
echo "  bundle id   $BUNDLE_ID"
echo "  archs       $(lipo -archs "$CONTENTS/MacOS/Deskterior")"
echo "  signature   ${SIGNATURE:-unknown}"
echo "  size        $(du -sh "$APP" | cut -f1 | tr -d ' ')"
if [ -n "$ZIP_NAME" ]; then
  echo "  zip         build/$ZIP_NAME"
  echo "  sha256      $(cut -d ' ' -f 1 "build/$ZIP_NAME.sha256")"
fi
