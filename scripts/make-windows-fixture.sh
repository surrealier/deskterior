#!/usr/bin/env bash
# A scratch folder with ten desktop items for the Windows smoke tests (never the real Desktop): files of each kind,
# Korean and emoji names, a folder, a hidden file and desktop.ini (both left out by the scanner).
set -euo pipefail
DIR="${1:?usage: make-windows-fixture.sh <dir>}"
mkdir -p "$DIR/Project folder"
cd "$DIR"
for name in notes.txt Report.pdf "사진 2026.png" "Screenshot 2026-11-11 101010.png" budget.xlsx song.mp3 archive.zip \
            script.py "여행 계획 🧳.docx"; do
  printf 'x' > "$name"
done
printf '[.ShellClassInfo]\n' > desktop.ini
printf 'secret' > hidden.txt
if command -v attrib.exe >/dev/null 2>&1; then
  attrib.exe +h +s desktop.ini >/dev/null
  attrib.exe +h hidden.txt >/dev/null
else
  mv hidden.txt .hidden.txt
fi
