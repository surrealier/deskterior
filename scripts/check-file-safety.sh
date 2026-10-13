#!/usr/bin/env bash
# File-safety lint (docs/DESIGN.md §3.7). Portable to macOS's bash 3.2.
#
# Deskterior promises it never moves, renames or deletes user files on its own. This lint makes the
# promise mechanical:
#   - destructive file APIs (trash, move, rename, delete, link, attributes, tags, flags) appear only in the
#     file-operation files; writing APIs only there and in our own writers (state, cache, artifacts, tools);
#   - nothing shells out, writes other apps' preferences (`defaults write`, `killall`) or talks to the network;
#   - ExplicitIntent is minted only in EffectRunner.swift, and only DesktopLocator.swift names the Desktop path.
# Tests are checked for the Desktop path, shelling out and the network; scripts for killall, defaults write,
# osascript and the Desktop path. Patterns allow whitespace before "(" and module-qualified C calls.
# The compiler is the stronger guard: keep ExplicitIntent's initializer private to DeskFiles (M11).
#
# Usage: scripts/check-file-safety.sh [SOURCES_DIR [TESTS_DIR [SCRIPTS_DIR]]]
#        scripts/check-file-safety.sh --self-test
#   No arguments: a self-test of the patterns, then <repo>/Sources, <repo>/Tests and <repo>/scripts. With
#   SOURCES_DIR only, only it is checked.
# Exit 0 = clean, 1 = violations found (or the self-test failed), 2 = bad usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/scripts/$(basename "${BASH_SOURCE[0]}")"

# Every line of Bypass.swift must be reported and nothing in Clean.swift; run on a scratch copy.
self_test() {
  local tmp out n i missing=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/file-safety-selftest.XXXXXX")"
  mkdir -p "$tmp/DeskCore"
  cat > "$tmp/DeskCore/Bypass.swift" <<'SWIFT'
try FileManager.default.removeItem (at: u)
let f = FileManager.removeItem(at:)
NSWorkspace.shared.recycle([u]) { _, _ in }
var v = URLResourceValues(); v.name = "x"; try u.setResourceValues(v)
_ = Darwin.rename("a", "b")
_ = remove("/x")
_ = renameat(0, "a", 0, "b")
_ = unlinkat(0, "x", 0)
_ = truncate("/x", 0)
_ = clonefile("a", "b", 0)
_ = exchangedata("a", "b", 0)
_ = setxattr("/x", "tags", nil, 0, 0, 0)
_ = chflags("/x", 0)
try FileManager.default.setAttributes([:], ofItemAtPath: "/x")
try FileManager.default.linkItem(atPath: "a", toPath: "b")
try FileManager.default.createSymbolicLink(atPath: "a", withDestinationPath: "b")
try "x".write(toFile: "/x", atomically: true, encoding: .utf8)
_ = FileHandle(forWritingAtPath: "/x")
_ = FileHandle(forUpdatingAtPath: "/x")
_ = open("/x", O_WRONLY | O_TRUNC)
_ = OutputStream(toFileAtPath: "/x", append: false)
let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/mv")
_ = "killall Finder"
_ = "defaults write com.apple.finder CreateDesktop false"
let s = URLSession.shared
_ = NSHomeDirectory() + "/Desktop"
_ = FileManager.SearchPathDirectory(rawValue: 12)
_ = "~/Desktop/x"
let i: ExplicitIntent = .init(origin: .menu, issuedAt: .now)
let j = ExplicitIntent.init(origin: .menu, issuedAt: .now)
SWIFT
  cat > "$tmp/DeskCore/Clean.swift" <<'SWIFT'
var list = [1]; list.remove(at: 0)
func remove(_ k: Int) {}
let r = CGRect(origin: .zero, size: .zero)
let pictures = "/System/Library/Desktop Pictures"
let key = "CreateDesktop"
FileHandle.standardError.write(Data())
SWIFT
  out="$("$SELF" "$tmp" 2>&1 || true)"
  n="$(wc -l < "$tmp/DeskCore/Bypass.swift" | tr -d ' ')"
  i=1
  while [ "$i" -le "$n" ]; do
    if ! printf '%s
' "$out" | grep -q "Bypass.swift:$i:"; then
      echo "file-safety: self-test: Bypass.swift line $i was not reported: $(sed -n "${i}p" "$tmp/DeskCore/Bypass.swift")" >&2
      missing=$((missing + 1))
    fi
    i=$((i + 1))
  done
  if printf '%s
' "$out" | grep -q "Clean.swift:"; then
    echo "file-safety: self-test: false positives:" >&2
    printf '%s
' "$out" | grep "Clean.swift:" >&2
    missing=$((missing + 1))
  fi
  rm -rf "$tmp"
  [ "$missing" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
  self_test && echo "file-safety: self-test OK"
  exit $?
fi
if [ $# -eq 0 ]; then
  self_test || exit 1
  SRC="$ROOT/Sources"; TESTS="$ROOT/Tests"; SCRIPTS="$ROOT/scripts"
else
  SRC="$1"; TESTS="${2:-}"; SCRIPTS="${3:-}"
fi

for dir in "$SRC" "$TESTS" "$SCRIPTS"; do
  if [ -n "$dir" ] && [ ! -d "$dir" ]; then
    echo "file-safety: directory not found: $dir" >&2
    exit 2
  fi
done
SRC="$(cd "$SRC" && pwd)"
[ -z "$TESTS" ] || TESTS="$(cd "$TESTS" && pwd)"
[ -z "$SCRIPTS" ] || SCRIPTS="$(cd "$SCRIPTS" && pwd)"

# Allowlists: space-separated paths relative to the checked directory. A trailing "/" allows a whole directory.
DESTRUCTIVE_ALLOW="DeskFiles/FileOperator.swift DeskFiles/Trasher.swift DeskFiles/OperationLog.swift"
WRITE_ALLOW="$DESTRUCTIVE_ALLOW DeskFiles/StateStore.swift DeskFiles/IconCache.swift DeskFiles/ArtifactWriter.swift DeskAssetTool/"
INTENT_ALLOW="DeskteriorApp/EffectRunner.swift"
DESKTOP_PATH_ALLOW="DeskFiles/DesktopLocator.swift"
TEST_DESKTOP_PATH_ALLOW="DeskFilesTests/SafetyGuardTests.swift"
SCRIPT_DESKTOP_PATH_ALLOW="make-fixture-desktop.sh"
NOWHERE=""

# Extended regexes (grep -E), one per line. "PATTERN !! EXCLUDE" skips hits whose code matches EXCLUDE.
C_MUTATORS='remove|rename|renameat|renamex_np|renameatx_np|unlink|unlinkat|rmdir|truncate|ftruncate|link|linkat|symlink|symlinkat|chmod|fchmod|lchmod|chown|fchown|lchown|chflags|fchflags|lchflags|setxattr|fsetxattr|removexattr|fremovexattr|exchangedata|clonefile|clonefileat|fclonefileat|copyfile|fcopyfile|open|openat|creat|mkdir|mkdirat|system|popen'
DESTRUCTIVE_PATTERNS='\brecycle[[:space:]]*\(
\btrashItem\b
\bmoveItem\b
\bcopyItem\b
\bremoveItem\b
\breplaceItem(At)?\b
\brenamex?_np\b
\brenameatx?_np\b
\brenameat\b
(^|[^.A-Za-z0-9_])rename[[:space:]]*\( !! func[[:space:]]+rename
\b(Darwin|Glibc|Foundation)\.('"$C_MUTATORS"')[[:space:]]*\(
\bunlink(at)?\b
(^|[^.A-Za-z0-9_])remove[[:space:]]*\( !! func[[:space:]]+remove
\brmdir\b
\bf?truncate[[:space:]]*\(
\bf?copyfile\b
\bf?clonefile(at)?\b
\bexchangedata\b
\bf?(set|remove)xattr\b
\b[fl]?chflags\b
\b[fl]?chmod\b
\b[fl]?chown\b
\bsetAttributes\b
\blinkItem\b
\bcreateSymbolicLink\b
(^|[^.A-Za-z0-9_])(sym)?link(at)?[[:space:]]*\( !! func[[:space:]]+(sym)?link
\bsetResourceValues?\b
\bunmountAndEjectDevice\b
\bunmount[[:space:]]*\(
\bDADisk(Unmount|Eject|Rename)\b
\bperformFileOperation\b'
WRITE_PATTERNS='\bwrite[[:space:]]*\([[:space:]]*(to|toFile|toURL)[[:space:]]*:
\bwriteTo(File|URL)\b
\bcreateFile\b
\bcreateDirectory\b
\bFileHandle[[:space:]]*(\.init)?[[:space:]]*\([[:space:]]*for(Writing|Updating)
\bOutputStream\b
\bO_(WRONLY|RDWR|CREAT|TRUNC|APPEND)\b
\bf(re|d)?open\b
\bcreat[[:space:]]*\(
(^|[^.A-Za-z0-9_])mkdir(at)?[[:space:]]*\( !! func[[:space:]]+mkdir
\bmk[sd]temps?\b
\barchiveRootObject\b
\bCGImageDestinationCreateWithURL\b
\bCGPDFContextCreateWithURL\b
\bCGDataConsumer[[:space:]]*\([[:space:]]*url:'
SHELL_PATTERNS='\bProcess[[:space:]]*(\.init)?[[:space:]]*\(
\bNSTask\b
\bposix_spawnp?\b
(^|[^.A-Za-z0-9_])system[[:space:]]*\( !! func[[:space:]]+system
\bpopen\b
\bexecv[pe]?[[:space:]]*\(
\bNSAppleScript\b
\bOSAScript\b
\bNSUserScriptTask\b
killall
defaults[[:space:]]+write
\bCFPreferencesSet(App)?Value\b
\bCFPreferencesSetMultiple\b
suiteName:[[:space:]]*"com\.apple\.'
NETWORK_PATTERNS='\bURLSession\b
\bNSURLConnection\b
\bNWConnection\b
\bNWListener\b
^[[:space:]]*import[[:space:]]+Network\b
\bCFSocketCreate
\bCFStreamCreatePairWithSocket
contentsOf:[[:space:]]*URL[[:space:]]*\([[:space:]]*string:'
INTENT_PATTERNS='\bExplicitIntent[[:space:]]*(\.init)?[[:space:]]*\(
\bExplicitIntent[!?]?[[:space:]]*=[[:space:]]*\.init\b
\.init[[:space:]]*\([[:space:]]*origin:[[:space:]]*\.'
DESKTOP_PATH_PATTERNS='\.desktopDirectory\b
SearchPathDirectory[[:space:]]*(\.init)?[[:space:]]*\(
"Desktop["/]
/Desktop["/]
"~/Desktop'
SCRIPT_PATTERNS='killall
defaults[[:space:]]+write
osascript'
SCRIPT_DESKTOP_PATTERNS='(\$HOME|\$\{HOME\}|~)/Desktop'

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

# $1 = label, $2 = directory, $3 = file glob, $4 = newline-separated patterns, $5 = allowlist
check() {
  local label="$1" dir="$2" glob="$3" patterns="$4" allow="$5" line pat exclude hit file rel rest code
  [ -n "$dir" ] || return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    pat="${line%% !! *}"
    exclude=""
    [ "$pat" != "$line" ] && exclude="${line#* !! }"
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      file="${hit%%:*}"
      rest="${hit#*:}"      # "<line>:<code>"
      code="${rest#*:}"
      rel="${file#"$dir"/}"
      # Ignore whole-line comments (Swift // and shell #).
      if printf '%s' "$code" | grep -qE '^[[:space:]]*(//|#)'; then continue; fi
      if [ -n "$exclude" ] && printf '%s' "$code" | grep -qE -e "$exclude"; then continue; fi
      if ! is_allowed "$rel" "$allow"; then
        echo "file-safety: [$label] /$pat/ not allowed in $rel:${rest%%:*}: $(printf '%s' "$code" | sed 's/^[[:space:]]*//')" >&2
        violations=$((violations + 1))
      fi
    done <<EOF
$(grep -rnE --include="$glob" -e "$pat" "$dir" 2>/dev/null | grep -v '/check-file-safety\.sh:' || true)
EOF
  done <<EOF
$patterns
EOF
}

check "destructive" "$SRC" '*.swift' "$DESTRUCTIVE_PATTERNS" "$DESTRUCTIVE_ALLOW"
check "write" "$SRC" '*.swift' "$WRITE_PATTERNS" "$WRITE_ALLOW"
check "shell" "$SRC" '*.swift' "$SHELL_PATTERNS" "$NOWHERE"
check "network" "$SRC" '*.swift' "$NETWORK_PATTERNS" "$NOWHERE"
check "intent" "$SRC" '*.swift' "$INTENT_PATTERNS" "$INTENT_ALLOW"
check "desktop-path" "$SRC" '*.swift' "$DESKTOP_PATH_PATTERNS" "$DESKTOP_PATH_ALLOW"
check "test-shell" "$TESTS" '*.swift' "$SHELL_PATTERNS" "$NOWHERE"
check "test-network" "$TESTS" '*.swift' "$NETWORK_PATTERNS" "$NOWHERE"
check "test-desktop-path" "$TESTS" '*.swift' '\.desktopDirectory\b
SearchPathDirectory[[:space:]]*(\.init)?[[:space:]]*\(
(NSHomeDirectory|homeDirectoryForCurrentUser|"HOME"|"~/).*Desktop' "$TEST_DESKTOP_PATH_ALLOW"
check "script" "$SCRIPTS" '*.sh' "$SCRIPT_PATTERNS" "$NOWHERE"
check "script-desktop-path" "$SCRIPTS" '*.sh' "$SCRIPT_DESKTOP_PATTERNS" "$SCRIPT_DESKTOP_PATH_ALLOW"

if [ "$violations" -gt 0 ]; then
  echo "file-safety: $violations violation(s)" >&2
  exit 1
fi
echo "file-safety: OK"
