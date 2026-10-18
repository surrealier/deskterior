#!/usr/bin/env bash
# File-safety lint (docs/DESIGN.md §3.7). Portable to macOS's bash 3.2.
#
# Deskterior promises it never moves, renames or deletes user files on its own. This lint makes the
# promise mechanical:
#   - destructive file APIs (trash, move, rename, delete, link, attributes, tags, flags, times, iCloud
#     eviction, icons), including C functions passed or bound as values, appear only in the file-operation
#     files; writing APIs only there and in our own writers (state, cache, artifacts, tools); Finder alias
#     (bookmark) files are written only by FileOperator (a drop-in alias, Erratum 29);
#   - nothing shells out, calls by name (@_silgen_name, @_extern, dlsym, string selectors), writes other apps'
#     preferences (`defaults write`, `killall`) or talks to the network, and Sources hold no C/ObjC files;
#   - ExplicitIntent's initializer is SPI: `@_spi(IntentMinting) import DeskFiles` is allowed only in
#     DeskteriorApp/Store/EffectRunner.swift (in tests, only in DeskFilesTests), and `@testable` imports are
#     not allowed in Sources at all (debug builds would open DeskFiles' internals). The SPI token cannot be
#     split across lines, so this holds for every spelling of a call; the one-line `ExplicitIntent(` patterns
#     below are a second net. FileOperator also refuses intents its ledger never issued or already spent;
#   - only DesktopLocator.swift names the Desktop path;
#   - file requests (Move to Trash, Empty Wastebasket, Eject, drop-in, Save as Text File) are built only in the
#     reducer, the menus and the drop-in and drag-out controllers, and only gesture handlers name the gesture a
#     request came from (`withOrigin`, `perform(…, from: .menuItem)`): EffectRunner mints an intent only for a
#     named gesture.
# Tests are checked for the Desktop path, minting intents, SPI imports, shelling out and the network; scripts
# for killall, defaults write, osascript and the Desktop path. Patterns allow whitespace before "(" and
# module-qualified C calls. A whole-line comment is skipped (`//` in Swift, `#` in shell scripts; a Swift line
# starting with `#` is code: #expect, #selector). "PATTERN !! EXCLUDE" removes the text EXCLUDE matches (a
# declaration such as `func remove`) and checks the rest of the line again.
# The compiler adds a guard of its own: DeskCore and DeskScene cannot import DeskFiles, so they cannot name
# ExplicitIntent at all.
# Tests/DeskFilesTests/FileSafetyLintTests.swift reads the variables and `check` lines below and runs the same
# scan in Swift: keep every pattern and allowlist in a variable, and every `check` call on one line.
#
# Usage: scripts/check-file-safety.sh [SOURCES_DIR [TESTS_DIR [SCRIPTS_DIR]]]
#        scripts/check-file-safety.sh --self-test
#   No arguments: a self-test of the patterns, then <repo>/Sources, <repo>/Tests and <repo>/scripts. With
#   SOURCES_DIR only, only it is checked.
# Exit 0 = clean, 1 = violations found (or the self-test failed), 2 = bad usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/scripts/$(basename "${BASH_SOURCE[0]}")"

# Every line of each Bypass.swift must be reported and nothing in the Clean.swift files; run on a scratch copy.
self_test() {
  local tmp out missing=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/file-safety-selftest.XXXXXX")"
  mkdir -p "$tmp/Sources/DeskCore" "$tmp/Sources/DeskteriorApp/Store" "$tmp/Tests/DeskSceneTests" "$tmp/Tests/DeskFilesTests"
  cat > "$tmp/Sources/DeskCore/Bypass.swift" <<'SWIFT'
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
_ = fchmodat(AT_FDCWD, "/x", 0o777, 0)
_ = removefile("/x", nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
try FileManager.default.setAttributes([:], ofItemAtPath: "/x")
try FileManager.default.linkItem(atPath: "a", toPath: "b")
try FileManager.default.createSymbolicLink(atPath: "a", withDestinationPath: "b")
try FileManager.default.setUbiquitous(true, itemAt: u, destinationURL: d)
try FileManager.default.evictUbiquitousItem(at: u)
try NSFileVersion.removeOtherVersionsOfItem(at: u)
_ = utimes("/x", &times)
_ = setattrlist("/x", &attrs, &buf, 8, 0)
NSWorkspace.shared.setIcon(img, forFile: "/x", options: [])
NSWorkspace.shared.duplicate([u]) { _, _ in }
try URL.writeBookmarkData(data, to: u)
_ = CFURLWriteBookmarkDataToFile(data as CFData, u as CFURL, 0, nil)
_ = FSNewAlias(nil, &target, &alias)
#selector(FileManager.removeItem(at:))
let s = Selector(("removeItemAtPath:error:"))
func renameAll(_ a: String, _ b: String) -> Int32 { rename(a, b) }
func removeIt(_ p: String) -> Int32 { remove(p) }
let mv: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32 = rename
let rm: (UnsafePointer<CChar>) -> Int32 = Darwin.remove
let op = Darwin.open
let o: (UnsafePointer<CChar>, Int32) -> Int32 = open
apply(each, using: unlink)
apply(each, rename)
let ws: NSWorkspace = .shared; ws.duplicate([u]) { _, _ in }
let runner: Process? = nil
try "x".write(toFile: "/x", atomically: true, encoding: .utf8)
_ = FileHandle(forWritingAtPath: "/x")
_ = FileHandle(forUpdatingAtPath: "/x")
_ = open("/x", O_WRONLY | O_TRUNC)
_ = open("/x", 0x0001 | 0x0200 | 0x0400)
_ = OutputStream(toFileAtPath: "/x", append: false)
try d.write(
UserDefaults.standard.setPersistentDomain([:], forName: "com.apple.finder")
UserDefaults.standard.removePersistentDomain(forName: "com.apple.finder")
NSWorkspace.shared.setDesktopImageURL(u, for: screen, options: [:])
_ = mkfifo("/x", 0o600)
_ = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: u, create: true)
let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/mv")
let q = Process.self.init()
let t = try NSUserAppleScriptTask(url: u)
let up = NSUserUnixTask.self
_ = execvP(file, searchPath, argv)
_ = fork()
_ = "killall Finder"
_ = "defaults write com.apple.finder CreateDesktop false"
@_silgen_name("rename") func sneakyMove(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32
@_extern(c, "unlink") func sneakyUnlink(_ a: UnsafePointer<CChar>) -> Int32
_ = dlsym(handle, "rename")
_ = FileManager.default.perform(NSSelectorFromString("moveItemAtPath:toPath:error:"), with: a, with: b)
let s = URLSession.shared
_ = NSHomeDirectory() + "/Desktop"
_ = FileManager.SearchPathDirectory(rawValue: 12)
_ = "~/Desktop/x"
let i: ExplicitIntent = .init(origin: .menuItem)
let j = ExplicitIntent.init(origin: .menuItem)
let k = ExplicitIntent (origin: o)
let mint: (ExplicitIntent.Origin) -> ExplicitIntent = ExplicitIntent.init
let forged = unsafeBitCast(t, to: ExplicitIntent.self)
take(.init(origin: .dragToTrash))
effects.withOrigin(.drop) { }
store.dispatch(.requestTrash(keys))
store.dispatch(.requestEmptyWastebasket)
store.dispatch(.requestSaveMemoFile(.note(id)))
_ = DeskAction.importDropped(urls, at: .floor(x: 0), op: .move)
session.perform(.moveToTrash(keys), from: .inventory)
@_spi(IntentMinting) import DeskFiles
@_spiOnly import DeskFiles
@testable import DeskFiles
SWIFT
  cat > "$tmp/Sources/DeskCore/Clean.swift" <<'SWIFT'
var list = [1]; list.remove(at: 0)
func remove(_ k: Int) {}
func renameLayer(_ name: String) {}
let r = CGRect(origin: .zero, size: .zero)
let q: CGRect = .init(origin: .zero, size: .zero)
#if DEBUG
#endif
let info = ProcessInfo.processInfo
let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
let shown = drawer.open
drawInterior(&c, ArtRect(0, 0, size.w, open), wood: true)
loop?.tick(link)
let pictures = "/System/Library/Desktop Pictures"
let key = "CreateDesktop"
FileHandle.standardError.write(Data())
NSWorkspace.shared.open(url)
case let .open(urls): open(urls)
func removeItems(at offsets: IndexSet) {}
List { ForEach(items) { Text($0.name) }.onDelete(perform: remove) }
Button("Rename", action: rename)
foo() // Process every token once
let pid = ProcessInfo.processInfo.processIdentifier
func run(_ intent: ExplicitIntent) -> ExplicitIntent.Origin { intent.origin }
if case .requestTrash = action { return }
let pick = MenuCommand.emptyWastebasket
SWIFT
  cat > "$tmp/Sources/DeskCore/shim.c" <<'C'
int shim(void) { return 0; }
C
  cat > "$tmp/Sources/DeskteriorApp/Store/EffectRunner.swift" <<'SWIFT'
@_spi(IntentMinting) import DeskFiles
let intent = ExplicitIntent(origin: .menuItem)
SWIFT
  cat > "$tmp/Tests/DeskSceneTests/Bypass.swift" <<'SWIFT'
let i = ExplicitIntent(origin: .drop)
let j: ExplicitIntent = .init(origin: .drop)
#expect(ExplicitIntent(origin: .drop) != nil)
#expect(Process() != nil)
@_spi(IntentMinting) import DeskFiles
SWIFT
  cat > "$tmp/Tests/DeskFilesTests/Clean.swift" <<'SWIFT'
@_spi(IntentMinting) @testable import DeskFiles
let i = ExplicitIntent(origin: .drop, issuedAt: now, instant: t)
SWIFT
  out="$("$SELF" "$tmp/Sources" "$tmp/Tests" 2>&1 || true)"
  for rel in Sources/DeskCore/Bypass.swift Tests/DeskSceneTests/Bypass.swift; do
    expect_all_reported "$tmp" "$rel" "$out" || missing=$((missing + 1))
  done
  if ! printf '%s\n' "$out" | grep -q "DeskCore/shim\.c"; then
    echo "file-safety: self-test: Sources/DeskCore/shim.c was not reported" >&2
    missing=$((missing + 1))
  fi
  if printf '%s\n' "$out" | grep -qE "(Clean|EffectRunner)\.swift:"; then
    echo "file-safety: self-test: false positives:" >&2
    printf '%s\n' "$out" | grep -E "(Clean|EffectRunner)\.swift:" >&2
    missing=$((missing + 1))
  fi
  rm -rf "$tmp"
  [ "$missing" -eq 0 ]
}

# $1 = scratch root, $2 = file relative to it (<Sources|Tests>/<rest>), $3 = lint output. Reports use <rest>.
expect_all_reported() {
  local file="$1/$2" rest="${2#*/}" out="$3" n i bad=0
  n="$(wc -l < "$file" | tr -d ' ')"
  i=1
  while [ "$i" -le "$n" ]; do
    if ! printf '%s\n' "$out" | grep -q "$rest:$i:"; then
      echo "file-safety: self-test: $2 line $i was not reported: $(sed -n "${i}p" "$file")" >&2
      bad=1
    fi
    i=$((i + 1))
  done
  [ "$bad" -eq 0 ]
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
# Finder alias files: only the file operator writes one (Erratum 29).
BOOKMARK_ALLOW="DeskFiles/FileOperator.swift"
WRITE_ALLOW="$DESTRUCTIVE_ALLOW DeskFiles/StateStore.swift DeskFiles/IconCache.swift DeskFiles/ArtifactWriter.swift DeskAssetTool/"
INTENT_ALLOW="DeskteriorApp/Store/EffectRunner.swift"
# The SPI also appears where the initializer is declared.
SPI_ALLOW="$INTENT_ALLOW DeskFiles/ExplicitIntent.swift"
TEST_INTENT_ALLOW="DeskFilesTests/"
DESKTOP_PATH_ALLOW="DeskFiles/DesktopLocator.swift"
TEST_DESKTOP_PATH_ALLOW="DeskFilesTests/SafetyGuardTests.swift"
# Where file requests may be built or matched, and where a request's gesture may be named.
FILE_REQUEST_ALLOW="DeskCore/Logic/DeskAction.swift DeskCore/Logic/Reducer.swift DeskCore/Logic/Reducer+Files.swift DeskCore/Logic/MenuSpec.swift DeskteriorApp/Files/DropInController.swift DeskteriorApp/Files/DragOutController.swift"
ORIGIN_ALLOW="DeskteriorApp/Store/EffectRunner.swift DeskteriorApp/AppDelegate.swift DeskteriorApp/Files/DropInController.swift DeskteriorApp/Files/DragOutController.swift DeskteriorApp/Demo/DemoRunner.swift"
SCRIPT_DESKTOP_PATH_ALLOW="make-fixture-desktop.sh"
NOWHERE=""
# File extensions that may not appear under Sources (C, C++, Objective-C, assembly, module maps).
FOREIGN_EXTENSIONS="c h m mm cc cpp cxx hpp s S modulemap"

# Extended regexes (grep -E), one per line. "PATTERN !! EXCLUDE": the text EXCLUDE matches is removed and the
# rest of the line checked again (EXCLUDE may not contain "/").
# C functions that change files, run programs or look up symbols: any module-qualified mention is flagged.
C_MUTATORS='remove|rename|renameat|renamex_np|renameatx_np|unlink|unlinkat|rmdir|truncate|ftruncate|link|linkat|symlink|symlinkat|chmod|fchmod|lchmod|fchmodat|chown|fchown|lchown|fchownat|chflags|fchflags|lchflags|setxattr|fsetxattr|removexattr|fremovexattr|exchangedata|clonefile|clonefileat|fclonefileat|copyfile|fcopyfile|removefile|open|openat|creat|mkdir|mkdirat|mkfifo|mknod|system|popen|setattrlist|fsetattrlist|setattrlistat|utimes|lutimes|futimes|utimensat|futimens|utime|execv|execve|execvp|fork|vfork|posix_spawn|posix_spawnp|dlsym|dlopen'
# The ones never used as plain names here: bound or passed as a value (`= rename`, `(…, unlink)`) is flagged too
# (not after a label, so SwiftUI's `perform: remove` stays clean).
C_VALUES='remove|rename|renameat|renamex_np|renameatx_np|unlink|unlinkat|rmdir|truncate|ftruncate|linkat|symlink|symlinkat|chmod|fchmod|lchmod|fchmodat|chown|fchown|lchown|fchownat|chflags|fchflags|lchflags|setxattr|fsetxattr|removexattr|fremovexattr|exchangedata|clonefile|clonefileat|fclonefileat|copyfile|fcopyfile|removefile|openat|creat|mkdir|mkdirat|mkfifo|mknod|popen|setattrlist|fsetattrlist|setattrlistat|utimes|lutimes|futimes|utimensat|futimens'
DESTRUCTIVE_PATTERNS='\brecycle[[:space:]]*\(
\btrashItem(AtURL)?\b
\b(move|copy|remove|link)Item(At(Path|URL))?\b
\breplaceItem(At(URL)?)?\b
\bduplicate[[:space:]]*\( !! (func|case)[[:space:]]+duplicate
\brenamex?_np\b
\brenameatx?_np\b
\brenameat\b
(^|[^.A-Za-z0-9_])rename[[:space:]]*\( !! (func|case)[[:space:]]+rename
\b(Darwin|Glibc|Foundation)\.('"$C_MUTATORS"')\b
(=|\(|,|\[|\{|\breturn)[[:space:]]*('"$C_VALUES"')[[:space:]]*($|[),}]|\])
=[[:space:]]*(open|link|system)[[:space:]]*$
\bunlink(at)?\b
(^|[^.A-Za-z0-9_])remove[[:space:]]*\( !! (func|case)[[:space:]]+remove
\bremovefile\b
\brmdir\b
\bf?truncate[[:space:]]*\(
\bf?copyfile\b
\bf?clonefile(at)?\b
\bexchangedata\b
\bf?(set|remove)xattr\b
\b[fl]?chflags\b
\b[fl]?chmod(at)?\b
\b[fl]?chown(at)?\b
\bf?setattrlist(at)?\b
\b[lf]?utimes\b
\butimensat\b
\bfutimens\b
\butime[[:space:]]*\(
\bacl_set_(file|fd|link_np)\b
\bsetAttributes\b
\bcreateSymbolicLink\b
(^|[^.A-Za-z0-9_])(sym)?link(at)?[[:space:]]*\( !! (func|case)[[:space:]]+(sym)?link
\bsetResourceValues?\b
\bsetUbiquitous\b
\bevictUbiquitousItem\b
\bNSFileVersion\b
\bsetIcon\b
\bunmountAndEjectDevice\b
\bunmountVolume\b
\bunmount[[:space:]]*\(
\bDADisk(Unmount|Eject|Rename)\b
\bperformFileOperation\b'
WRITE_PATTERNS='\bwrite[[:space:]]*\([[:space:]]*(to|toFile|toURL)[[:space:]]*:
\bwrite[[:space:]]*\([[:space:]]*$
\bwriteTo(File|URL)\b
\bcreateFile\b
\bcreateDirectory\b
\bitemReplacementDirectory\b
\bFileHandle[[:space:]]*(\.init)?[[:space:]]*\([[:space:]]*for(Writing|Updating)
\bOutputStream\b
\bO_(WRONLY|RDWR|CREAT|TRUNC|APPEND)\b
(^|[^.A-Za-z0-9_])open(at)?[[:space:]]*\([^)]*, !! (func|case)[[:space:]]+open
\bf(re|d)?open\b
\bcreat[[:space:]]*\(
(^|[^.A-Za-z0-9_])mkdir(at)?[[:space:]]*\( !! (func|case)[[:space:]]+mkdir
\bmk(fifo|nod)\b
\bmk[sd]temps?\b
\barchiveRootObject\b
\bCGImageDestinationCreateWithURL\b
\bCGPDFContextCreateWithURL\b
\bCGDataConsumer[[:space:]]*\([[:space:]]*url:
\bwriteBookmarkData\b
\bCFURLWriteBookmarkDataToFile\b
\bFS(New|Update)Alias'
# Bookmark (alias) files written: a write as above, and allowed only in the file operator.
BOOKMARK_PATTERNS='\bwriteBookmarkData\b
\bCFURLWriteBookmarkDataToFile\b
\bFS(New|Update)Alias'
SHELL_PATTERNS='\bProcess[[:space:]]*(\(|\.|\?|!|>|\)|,|\]|$)
(:|=|<|\bas[!?]?|\bis)[[:space:]]*\[?Process\b
\bNSTask\b
\bposix_spawnp?\b
(^|[^.A-Za-z0-9_])system[[:space:]]*\( !! (func|case)[[:space:]]+system
\bpopen\b
\bexec(l|le|lp|v|ve|vp|vP|t)\b
\bv?fork[[:space:]]*\(
\bNSAppleScript\b
\bOSAScript\b
\bNSUser[A-Za-z]*Task\b
\bAuthorizationExecuteWithPrivileges\b
killall
defaults[[:space:]]+write
\bCFPreferencesSet(App)?Value\b
\bCFPreferencesSetMultiple\b
\b(set|remove)(Persistent|Volatile)Domain\b
\bsetDesktopImageURL\b
suiteName:[[:space:]]*"com\.apple\.'
# Calls by name, around every pattern above.
DYNAMIC_PATTERNS='@_silgen_name
@_extern\b
\bdl(sym|open)\b
\bNSSelectorFromString\b
\bNSClassFromString\b
\bobjc_msgSend
\b(class_getMethodImplementation|class_replaceMethod|method_getImplementation|method_setImplementation|method_exchangeImplementations)\b
\bSelector[[:space:]]*\(+[[:space:]]*"[^"]*([Rr]emove|[Mm]ove|[Cc]opy|[Tt]rash|[Rr]ename|[Ll]ink|[Rr]eplace|[Ww]rite|[Uu]nmount|[Ee]ject|[Dd]elete|[Rr]ecycle|[Aa]ttribute|[Cc]reate|[Dd]uplicate|[Ii]con|[Ll]aunch|[Ee]xec)'
NETWORK_PATTERNS='\bURLSession\b
\bNSURLConnection\b
\bNWConnection\b
\bNWListener\b
^[[:space:]]*import[[:space:]]+Network\b
\bCFSocketCreate
\bCFStreamCreatePairWithSocket
contentsOf:[[:space:]]*URL[[:space:]]*\([[:space:]]*string:'
# One-line spellings of minting an intent; the SPI check below covers every spelling.
INTENT_PATTERNS='\bExplicitIntent[[:space:]]*(\.init)?[[:space:]]*\(
\bExplicitIntent[!?]?[[:space:]]*=[[:space:]]*\.init\b
\bExplicitIntent[[:space:]]*\.[[:space:]]*(init|self)\b
\.init[[:space:]]*\([[:space:]]*origin:[[:space:]]*\.(menuItem|sheetConfirm|drop|dragToTrash|undo|inventory)\b'
# File requests built (or bound in a pattern) and gestures named.
FILE_REQUEST_PATTERNS='\.(requestTrash|requestEject|requestDropIn|importDropped|requestSaveMemoFile)[[:space:]]*\(
\.requestEmptyWastebasket\b'
ORIGIN_PATTERNS='\bwithOrigin[[:space:]]*\(
\bfrom:[[:space:]]*\.(menuItem|sheetConfirm|drop|dragToTrash|undo|inventory)\b'
# `@_spi(…)` and `@_spiOnly` imports or declarations.
SPI_PATTERNS='(^|[^A-Za-z0-9_])_spi'
TESTABLE_PATTERNS='@testable\b'
DESKTOP_PATH_PATTERNS='\.desktopDirectory\b
SearchPathDirectory[[:space:]]*(\.init)?[[:space:]]*\(
"Desktop["/]
/Desktop["/]
"~/Desktop'
TEST_DESKTOP_PATH_PATTERNS='\.desktopDirectory\b
SearchPathDirectory[[:space:]]*(\.init)?[[:space:]]*\(
(NSHomeDirectory|homeDirectoryForCurrentUser|"HOME"|"~/).*Desktop'
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
  local label="$1" dir="$2" glob="$3" patterns="$4" allow="$5" line pat exclude hit file rel rest code comment
  [ -n "$dir" ] || return 0
  # Whole-line comments: `#` in shell scripts, `//` in Swift (where a line starting with `#` is code).
  case "$glob" in
    *.sh) comment='^[[:space:]]*#' ;;
    *) comment='^[[:space:]]*//' ;;
  esac
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
      if printf '%s\n' "$code" | grep -qE -e "$comment"; then continue; fi
      if [ -n "$exclude" ] && ! printf '%s\n' "$code" | sed -E "s/$exclude//g" | grep -qE -e "$pat"; then continue; fi
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

# $1 = directory: Swift only, so that no C or Objective-C file can call what the patterns forbid.
check_foreign() {
  local dir="$1" ext f
  [ -n "$dir" ] || return 0
  set --
  for ext in $FOREIGN_EXTENSIONS; do set -- "$@" -o -name "*.$ext"; done
  shift
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    echo "file-safety: [foreign-source] not allowed in ${f#"$dir"/}: Sources hold Swift only" >&2
    violations=$((violations + 1))
  done <<EOF
$(find "$dir" -type f \( "$@" \) 2>/dev/null)
EOF
}

check "destructive" "$SRC" '*.swift' "$DESTRUCTIVE_PATTERNS" "$DESTRUCTIVE_ALLOW"
check "write" "$SRC" '*.swift' "$WRITE_PATTERNS" "$WRITE_ALLOW"
check "bookmark" "$SRC" '*.swift' "$BOOKMARK_PATTERNS" "$BOOKMARK_ALLOW"
check "shell" "$SRC" '*.swift' "$SHELL_PATTERNS" "$NOWHERE"
check "dynamic" "$SRC" '*.swift' "$DYNAMIC_PATTERNS" "$NOWHERE"
check "network" "$SRC" '*.swift' "$NETWORK_PATTERNS" "$NOWHERE"
check "intent" "$SRC" '*.swift' "$INTENT_PATTERNS" "$INTENT_ALLOW"
check "intent-spi" "$SRC" '*.swift' "$SPI_PATTERNS" "$SPI_ALLOW"
check "testable" "$SRC" '*.swift' "$TESTABLE_PATTERNS" "$NOWHERE"
check "desktop-path" "$SRC" '*.swift' "$DESKTOP_PATH_PATTERNS" "$DESKTOP_PATH_ALLOW"
check "file-request" "$SRC" '*.swift' "$FILE_REQUEST_PATTERNS" "$FILE_REQUEST_ALLOW"
check "origin" "$SRC" '*.swift' "$ORIGIN_PATTERNS" "$ORIGIN_ALLOW"
check "test-shell" "$TESTS" '*.swift' "$SHELL_PATTERNS" "$NOWHERE"
check "test-network" "$TESTS" '*.swift' "$NETWORK_PATTERNS" "$NOWHERE"
check "test-desktop-path" "$TESTS" '*.swift' "$TEST_DESKTOP_PATH_PATTERNS" "$TEST_DESKTOP_PATH_ALLOW"
check "test-intent" "$TESTS" '*.swift' "$INTENT_PATTERNS" "$TEST_INTENT_ALLOW"
check "test-intent-spi" "$TESTS" '*.swift' "$SPI_PATTERNS" "$TEST_INTENT_ALLOW"
check "script" "$SCRIPTS" '*.sh' "$SCRIPT_PATTERNS" "$NOWHERE"
check "script-desktop-path" "$SCRIPTS" '*.sh' "$SCRIPT_DESKTOP_PATTERNS" "$SCRIPT_DESKTOP_PATH_ALLOW"
check_foreign "$SRC"

if [ "$violations" -gt 0 ]; then
  echo "file-safety: $violations violation(s)" >&2
  exit 1
fi
echo "file-safety: OK"
