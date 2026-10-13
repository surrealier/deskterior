#!/usr/bin/env bash
# Regenerates the app icon from Sources/DeskCore/Art/AppIconArt.swift (docs/DESIGN.md §6): renders the
# iconset with `deskterior-assets icon`, packs it with iconutil, and refreshes the committed
# Packaging/AppIcon.icns and Packaging/AppIcon-master.png. Portable to macOS's bash 3.2.
#
# Usage: scripts/make-icon.sh [--all-sizes]   (flags go to `deskterior-assets icon`; see AppIconArt for
#        why the 16/32-px slots are left out by default)
# Env:   ICON_WORK_DIR      where the iconset and preview are rendered (default build/icon)
#        SCRATCH_PATH       SwiftPM scratch path for the asset tool (default .build)
#        SWIFT_BUILD_FLAGS  extra build flags, e.g. "-j 2"
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORK="${ICON_WORK_DIR:-build/icon}"
SCRATCH="${SCRATCH_PATH:-.build}"

rm -rf "$WORK/AppIcon.iconset"
# shellcheck disable=SC2086 # SWIFT_BUILD_FLAGS is a word list
swift run --scratch-path "$SCRATCH" ${SWIFT_BUILD_FLAGS:-} deskterior-assets icon --out "$WORK" "$@"

mkdir -p Packaging
iconutil -c icns "$WORK/AppIcon.iconset" -o Packaging/AppIcon.icns
cp "$WORK/AppIcon-master.png" Packaging/AppIcon-master.png

echo "make-icon: Packaging/AppIcon.icns ($(wc -c < Packaging/AppIcon.icns | tr -d ' ') bytes)," \
  "Packaging/AppIcon-master.png; preview at $WORK/AppIcon-preview.png"
