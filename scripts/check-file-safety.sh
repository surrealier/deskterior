#!/usr/bin/env bash
# File-safety lint (docs/DESIGN.md §3.7). Portable to macOS's bash 3.2.
#
# Deskterior promises it never moves, renames or deletes user files on its own. This lint makes the
# promise mechanical: file-mutating APIs may appear only in an allowlist of files, ExplicitIntent may
# only be minted in EffectRunner.swift, and only DesktopLocator.swift may construct the Desktop path.
#
# Usage: scripts/check-file-safety.sh [SOURCES_DIR]   (default: <repo>/Sources)
# Exit 0 = clean, 1 = violations found, 2 = bad usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/Sources}"

if [ ! -d "$SRC" ]; then
  echo "file-safety: sources dir not found: $SRC" >&2
  exit 2
fi
SRC="$(cd "$SRC" && pwd)"

# Allowlists: space-separated paths relative to SRC. A trailing "/" allows a whole directory.
MUTATION_ALLOW="DeskFiles/FileOperator.swift DeskFiles/Trasher.swift DeskFiles/StateStore.swift DeskFiles/IconCache.swift DeskFiles/OperationLog.swift DeskFiles/ArtifactWriter.swift DeskAssetTool/"
INTENT_ALLOW="DeskteriorApp/EffectRunner.swift"
DESKTOP_PATH_ALLOW="DeskFiles/DesktopLocator.swift"

# Extended regexes (grep -E), one per line.
MUTATION_PATTERNS='\brecycle\(
trashItem\(
(^|[^A-Za-z])moveItem\(
copyItem\(
replaceItem(At)?\(
renamex_np
(^|[^A-Za-z_.])rename\(
\bunlink\(
\bcopyfile\(
removeItem\(
unmountAndEjectDevice
\.write\(to:
createFile\(atPath
createDirectory\(
FileHandle\(forWritingTo
fopen\('
INTENT_PATTERNS='ExplicitIntent\('
DESKTOP_PATH_PATTERNS='\.desktopDirectory
"Desktop"
"~/Desktop'

violations=0

is_allowed() { # $1 = relative path, $2 = allowlist string
  local rel="$1" entry
  for entry in $2; do
    case "$entry" in
      */) case "$rel" in "$entry"*) return 0 ;; esac ;;
      *) [ "$rel" = "$entry" ] && return 0 ;;
    esac
  done
  return 1
}

check() { # $1 = label, $2 = newline-separated patterns, $3 = allowlist
  local label="$1" patterns="$2" allow="$3" pat hit file rel rest code
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      file="${hit%%:*}"
      rest="${hit#*:}"      # "<line>:<code>"
      code="${rest#*:}"
      rel="${file#"$SRC"/}"
      # Ignore whole-line comments.
      if printf '%s' "$code" | grep -qE '^[[:space:]]*//'; then continue; fi
      if ! is_allowed "$rel" "$allow"; then
        echo "file-safety: [$label] /$pat/ not allowed in $rel:${rest%%:*}: $(printf '%s' "$code" | sed 's/^[[:space:]]*//')" >&2
        violations=$((violations + 1))
      fi
    done <<EOF
$(grep -rnE --include='*.swift' -e "$pat" "$SRC" 2>/dev/null || true)
EOF
  done <<EOF
$patterns
EOF
}

check "mutation" "$MUTATION_PATTERNS" "$MUTATION_ALLOW"
check "intent" "$INTENT_PATTERNS" "$INTENT_ALLOW"
check "desktop-path" "$DESKTOP_PATH_PATTERNS" "$DESKTOP_PATH_ALLOW"

if [ "$violations" -gt 0 ]; then
  echo "file-safety: $violations violation(s)" >&2
  exit 1
fi
echo "file-safety: OK"
