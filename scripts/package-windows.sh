#!/usr/bin/env bash
# Packages the Windows build (docs/WINDOWS.md WP8) into one folder that runs on its own:
#   <out>/Deskterior.exe, the Swift runtime DLLs (and the MSVC runtime when found), Resources/Fonts/Galmuri9.glyphs,
#   the font's licence and README.txt. Run after `swift build -c release --product Deskterior` on Windows (Git Bash).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/dist/Deskterior}"
BIN="$ROOT/.build/release/Deskterior.exe"
[ -f "$BIN" ] || { echo "package-windows: build first: swift build -c release --product Deskterior" >&2; exit 1; }

mkdir -p "$OUT/Resources/Fonts"
cp "$BIN" "$OUT/"
cp "$ROOT/Resources/Fonts/Galmuri9.glyphs" "$ROOT/Resources/Fonts/OFL-Galmuri.txt" "$OUT/Resources/Fonts/"

# The Swift runtime: every DLL beside swiftCore.dll (Foundation, ICU data, dispatch, concurrency…).
core="$(where.exe swiftCore.dll 2>/dev/null | head -n1 | tr -d '\r')"
[ -n "$core" ] || { echo "package-windows: swiftCore.dll is not on PATH" >&2; exit 1; }
runtime="$(dirname "$(cygpath -u "$core")")"
cp "$runtime"/*.dll "$OUT/"

# The MSVC runtime the Swift runtime links against (app-local, for machines without the redistributable).
for dll in vcruntime140.dll vcruntime140_1.dll msvcp140.dll; do
  if [ -f "/c/Windows/System32/$dll" ]; then cp "/c/Windows/System32/$dll" "$OUT/"; fi
done

cat > "$OUT/README.txt" <<'TXT'
Deskterior for Windows (preview)

Run Deskterior.exe. It mirrors your Desktop folder as a pixel-art desk in its own window: items appear on the
monitor, can be arranged, opened (double-click) and revealed in File Explorer. Your layout is kept in
%APPDATA%\Deskterior. This preview changes no files: Recycle Bin, drop-in, eject and Save as Text File are refused.

Options:
  --desktop-folder <path>   mirror another folder
  --language ko             Korean
  --snapshot <out.png>      render the desk to a PNG without a window

Galmuri9 font: SIL Open Font License (Resources/Fonts/OFL-Galmuri.txt).
TXT

echo "package-windows: $(ls "$OUT" | wc -l) files in $OUT"
