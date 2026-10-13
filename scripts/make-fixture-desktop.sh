#!/usr/bin/env bash
# Builds a fake desktop folder for demos, mirror-dump and manual checks (docs/DESIGN.md §8.2). Portable to
# macOS's bash 3.2. It never writes under the real desktop folder: targets inside $HOME/Desktop (or above it)
# are refused before anything is created.
#
# Usage: scripts/make-fixture-desktop.sh [--count N] DIR
#   Default: about 40 visible items — NFD Korean names, emoji, an 80-character name, folders, an .rtfd package,
#   png/pdf/txt/zip and friends, screenshot-named pngs — plus hidden dot-files.
#   --count N  adds bulk files until DIR holds N visible items (performance fixture, e.g. --count 500).
# DIR must be empty, missing, or a previous fixture (it carries a .deskterior-fixture marker).
# PNG/PDF files come from `deskterior-assets fixture`: set DESKTERIOR_ASSETS to a built binary, else the
# script runs `swift run deskterior-assets` (with --scratch-path $SWIFT_SCRATCH_PATH when set).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COUNT=0
TARGET=""

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --count) [ $# -ge 2 ] || usage; COUNT="$2"; shift 2 ;;
    --count=*) COUNT="${1#--count=}"; shift ;;
    -h|--help) usage ;;
    -*) echo "make-fixture-desktop: unknown option $1" >&2; usage ;;
    *) [ -z "$TARGET" ] || usage; TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || usage
case "$COUNT" in ''|*[!0-9]*) echo "make-fixture-desktop: --count needs a number" >&2; exit 2 ;; esac

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Physical path of $1, resolving through its deepest existing ancestor (nothing is created).
canonical() {
  local head="$1" tail=""
  case "$head" in /*) ;; *) head="$PWD/$head" ;; esac
  while [ ! -d "$head" ]; do
    tail="/$(basename "$head")$tail"
    head="$(dirname "$head")"
  done
  printf '%s%s' "$(cd "$head" && pwd -P)" "$tail"
}

TARGET_REAL="$(lower "$(canonical "$TARGET")")"
for desk in "$HOME/Desktop" "$(canonical "$HOME/Desktop")"; do
  DESK="$(lower "$desk")"
  case "$TARGET_REAL/" in
    "$DESK"/*) echo "make-fixture-desktop: refusing a target inside the real desktop: $TARGET" >&2; exit 64 ;;
  esac
  case "$DESK/" in
    "$TARGET_REAL"/*) echo "make-fixture-desktop: refusing a target that contains the real desktop: $TARGET" >&2; exit 64 ;;
  esac
done

if [ -d "$TARGET" ] && [ -n "$(ls -A "$TARGET")" ] && [ ! -e "$TARGET/.deskterior-fixture" ]; then
  echo "make-fixture-desktop: $TARGET is not empty and is not a fixture; pick an empty folder" >&2
  exit 1
fi
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd -P)"
: > "$TARGET/.deskterior-fixture"

# PNG and PDF sources.
ASSETS="$(mktemp -d "${TMPDIR:-/tmp}/deskterior-fixture-assets.XXXXXX")"
trap 'rm -rf "$ASSETS"' EXIT
if [ -n "${DESKTERIOR_ASSETS:-}" ]; then
  "$DESKTERIOR_ASSETS" fixture --out "$ASSETS" >/dev/null
else
  (cd "$ROOT" && swift run ${SWIFT_SCRATCH_PATH:+--scratch-path "$SWIFT_SCRATCH_PATH"} -q deskterior-assets \
    fixture --out "$ASSETS" >/dev/null)
fi

# NFD (decomposed) spelling, as older Macs and many downloads store Korean names.
nfd() {
  local out
  out="$(printf '%s' "$1" | perl -CS -MUnicode::Normalize -ne 'print NFD($_)')"
  [ -n "$out" ] || { echo "make-fixture-desktop: NFD conversion failed for '$1'" >&2; exit 1; }
  printf '%s' "$out"
}
put() { cp "$ASSETS/$1" "$TARGET/$2"; }            # asset file → fixture name
text() { printf '%s\n' "$2" > "$TARGET/$1"; }      # name, contents

# Pictures and documents.
put report.pdf "$(nfd '보고서 final.pdf')"
put slides.pdf "slides.pdf"
put report.pdf "invoice 2026.pdf"
put report.pdf "$(nfd 'Résumé.pdf')"
put photo-sunset.png "IMG_0001.png"
put photo-forest.png "IMG_0002.png"
put diagram.png "IMG_0003.png"
put photo-forest.png "🐱 cat.png"
put icon-badge.png "icon-badge.png"
put diagram.png "diagram.png"
put photo-sunset.png "Screenshot 2026-10-12 at 10.15.32.png"
put diagram.png "$(nfd '스크린샷 2026-10-12 오후 3.04.11.png')"

# Text and code.
text "$(nfd '회의록 2026-10.txt')" "회의록"
text "🎉 party plan.txt" "cake, balloons"
text "This is a deliberately long file name that goes on and on to test truncation.txt" "long"
text "todo.txt" "- mirror the desktop"
text "notes.md" "# Notes"
text "readme.txt" "fixture"
text "file 2.txt" "2"
text "file 10.txt" "10"
text "file (1).txt" "1"
text "Untitled.txt" ""
text "script.sh" "#!/bin/sh"
text "main.swift" "print(\"hi\")"
text "data.json" "{\"ok\": true}"
text "page.html" "<p>hi</p>"
text "song.mp3" "not really audio"
text "clip.mov" "not really video"
text "installer.dmg" "not really a disk image"
text "Meeting notes.docx" "not really a Word file"
text "budget.xlsx" "not really a spreadsheet"

# Folders and a package.
mkdir -p "$TARGET/Projects/site" "$TARGET/Old Stuff" "$TARGET/$(nfd '사진 모음')" "$TARGET/📦 Inbox"
text "Projects/site/index.html" "<p>inside a folder</p>"
put photo-sunset.png "$(nfd '사진 모음')/beach.png"
mkdir -p "$TARGET/Notes.rtfd" "$TARGET/$(nfd '기획안.rtfd')"
printf '{\\rtf1\\ansi Notes}\n' > "$TARGET/Notes.rtfd/TXT.rtf"
printf '{\\rtf1\\ansi Plan}\n' > "$TARGET/$(nfd '기획안.rtfd')/TXT.rtf"

# Archives.
ditto -c -k --sequesterRsrc "$TARGET/Projects" "$TARGET/archive.zip"
tar -czf "$TARGET/backup.tar.gz" -C "$TARGET" "Old Stuff"

# An alias-like item (a symlink; reading it never follows into the target).
ln -sfn /Applications "$TARGET/Applications link"

# Hidden items: never mirrored.
text ".hidden-note.txt" "hidden"
text ".DS_Store" ""
text ".localized" ""

# Bulk files for --count.
visible() { ls -1 "$TARGET" | grep -cv '^\.' || true; }
if [ "$COUNT" -gt 0 ]; then
  n="$(visible)"
  i=1
  while [ "$n" -lt "$COUNT" ]; do
    name="$(printf 'bulk-%04d' "$i")"
    case $((i % 5)) in
      0) put photo-sunset.png "$name.png" ;;
      1) put report.pdf "$name.pdf" ;;
      *) text "$name.txt" "$i" ;;
    esac
    i=$((i + 1))
    n=$((n + 1))
  done
fi

echo "fixture desktop: $TARGET ($(visible) visible items)"
