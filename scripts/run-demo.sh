#!/usr/bin/env bash
# Runs scripted demos headless against a fresh fixture desktop (docs/DESIGN.md §8.2, docs/DEMOS.md). Portable to
# macOS's bash 3.2.
#
# Usage: scripts/run-demo.sh [--out DIR] [--scale N] [--count N] [--record N] [--release] NAME|FILE [NAME|FILE ...]
#   NAME runs Demos/NAME.json. Each demo gets a new mktemp fixture (scripts/make-fixture-desktop.sh, about 40
#   items; --count N, or the script's "fixtureCount", for more) and a new mktemp state folder, then runs
#     Deskterior --headless --demo FILE --desktop-folder FIXTURE --state-dir STATE --seed 1
#                --snapshot-dir OUT/NAME --snapshot-scale N
#   OUT defaults to .build/demo-out. Env: SWIFT_SCRATCH_PATH (build folder, e.g. .build-w4-core), SWIFT_JOBS
#   (default 3), DESKTERIOR_BIN (a built Deskterior; skips the build), DESKTERIOR_RESOURCES (default Resources/).
#   --record N also writes every Nth scene frame (art px, the pointer drawn in) to OUT/NAME/frames/frame-NNNNN.png
#   (--demo-record; a script's "record" steps say when), for scripts/make-gif.sh.
#
# The real desktop is never used: fixture and state folders come from mktemp, make-fixture-desktop.sh refuses
# targets inside the real desktop, this script refuses an --out folder inside (or containing) it before touching
# anything, and the app refuses (exit 64) a mirrored, state or snapshot folder that is the real desktop or inside
# it. The demo's fs steps (touch, mkdir, mv, rm) are performed here, inside the fixture only: the app asks on
# stdout ("DEMO-FS<TAB>op<TAB>name[<TAB>name]") and waits for "ok" on its stdin, so these changes are the harness's,
# not the app's (the app changes files only through its explicit file actions, into the FakeTrash). Names are single
# plain components without control characters; symlinks are never followed (the fixture holds links to /Applications
# and the like), and mv never replaces anything. Each demo also gets an empty mktemp "source" folder beside the
# fixture (DESKTERIOR_DEMO_SOURCE) that files are dropped in from: `source`/`sourceDir` steps create items there, a
# `sourceApp` step copies an app of /System/Applications there with ditto, or cp -R (so a drop never takes an
# installed app from where it is; Erratum 29), and `ls desk|source|trash` prints `ls -li` of the fixture, the source folder or the
# FakeTrash (<state>/FakeTrash, where the app's file actions trash to in demos) into the log.
# Exit: 0 when every demo passes, else the first failing demo's code (1 expectation, 2 script error, 64 guard).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="$ROOT/.build/demo-out"
SCALE=3
COUNT=0
RECORD=0
CONFIG=debug
NAMES=()

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || usage; OUT_ROOT="$2"; shift 2 ;;
    --scale) [ $# -ge 2 ] || usage; SCALE="$2"; shift 2 ;;
    --count) [ $# -ge 2 ] || usage; COUNT="$2"; shift 2 ;;
    --record) [ $# -ge 2 ] || usage; RECORD="$2"; shift 2 ;;
    --release) CONFIG=release; shift ;;
    -h|--help) usage ;;
    -*) echo "run-demo: unknown option $1" >&2; usage ;;
    *) NAMES+=("$1"); shift ;;
  esac
done
[ "${#NAMES[@]}" -gt 0 ] || usage
case "$RECORD" in ''|*[!0-9]*) echo "run-demo: --record needs a number" >&2; exit 2 ;; esac

# Snapshots go under --out (old PNGs there are deleted): never inside, or above, the real desktop.
"$ROOT/scripts/make-fixture-desktop.sh" --check "$OUT_ROOT" || exit $?

# Build (or use DESKTERIOR_BIN).
if [ -n "${DESKTERIOR_BIN:-}" ]; then
  BIN_DIR="$(cd "$(dirname "$DESKTERIOR_BIN")" && pwd)"
else
  BUILD=(swift build -c "$CONFIG" -j "${SWIFT_JOBS:-3}")
  [ -z "${SWIFT_SCRATCH_PATH:-}" ] || BUILD+=(--scratch-path "$SWIFT_SCRATCH_PATH")
  (cd "$ROOT" && "${BUILD[@]}" --product Deskterior >&2 && "${BUILD[@]}" --product deskterior-assets >&2)
  BIN_DIR="$(cd "$ROOT" && "${BUILD[@]}" --show-bin-path)"
fi
APP="${DESKTERIOR_BIN:-$BIN_DIR/Deskterior}"
[ -x "$APP" ] || { echo "run-demo: no Deskterior binary at $APP" >&2; exit 2; }
if [ -x "$BIN_DIR/deskterior-assets" ]; then export DESKTERIOR_ASSETS="$BIN_DIR/deskterior-assets"; fi
# A release binary finds no fonts by itself (no source paths): the repo's Resources.
export DESKTERIOR_RESOURCES="${DESKTERIOR_RESOURCES:-$ROOT/Resources}"

# A single path component: not empty, not . or .., no slash, no control characters.
plain() {
  case "$1" in ""|.|..|*/*|*[[:cntrl:]]*) return 1 ;; esac
  return 0
}

# Performs one fs request inside the fixture $DESK (or the drop source $SOURCE): op, name, [name]. Symlinks are
# never followed: touch sets a link's own times, mkdir and mv refuse a link (or anything) already at the target, rm
# removes a link, not what it points to.
fs_op() {
  local op="$1" a="$2" b="${3:-}"
  plain "$a" || return 1
  case "$op" in
    source) [ ! -e "$SOURCE/$a" ] && [ ! -L "$SOURCE/$a" ] || return 1; printf 'dropped in: %s\n' "$a" > "$SOURCE/$a" ;;
    sourceDir)
      [ ! -e "$SOURCE/$a" ] && [ ! -L "$SOURCE/$a" ] || return 1
      mkdir "$SOURCE/$a" && printf 'inside %s\n' "$a" > "$SOURCE/$a/inside.txt"
      ;;
    sourceApp)
      # A copy of a system app (read only there) in the drop source: "Calculator.app".
      case "$a" in *.app) ;; *) return 1 ;; esac
      [ -d "/System/Applications/$a" ] && [ ! -L "/System/Applications/$a" ] || return 1
      [ ! -e "$SOURCE/$a" ] && [ ! -L "$SOURCE/$a" ] || return 1
      # ditto stops on the system's own `restricted` flag (SIP), which no copy may carry: then a plain cp -R.
      ditto "/System/Applications/$a" "$SOURCE/$a" >/dev/null 2>&1 \
        || { rm -rf "${SOURCE:?}/$a" && cp -R "/System/Applications/$a" "$SOURCE/$a"; }
      ;;
    ls)
      case "$a" in
        desk) echo "ls -li fixture ($DESK):" ; ls -li "$DESK" ;;
        source) echo "ls -li source ($SOURCE):" ; ls -li "$SOURCE" ;;
        trash) echo "ls -li FakeTrash ($STATE/FakeTrash):"; if [ -d "$STATE/FakeTrash" ]; then ls -li "$STATE/FakeTrash"; else echo "(none yet)"; fi ;;
        *) return 1 ;;
      esac
      ;;
    touch) if [ -L "$DESK/$a" ]; then touch -h "$DESK/$a"; else touch "$DESK/$a"; fi ;;
    mkdir) [ ! -e "$DESK/$a" ] && [ ! -L "$DESK/$a" ] || return 1; mkdir "$DESK/$a" ;;
    rm) rm -rf "${DESK:?}/$a" ;;
    mv)
      plain "$b" || return 1
      { [ -e "$DESK/$a" ] || [ -L "$DESK/$a" ]; } || return 1
      [ ! -e "$DESK/$b" ] && [ ! -L "$DESK/$b" ] || return 1
      mv -n "$DESK/$a" "$DESK/$b"
      ;;
    *) return 1 ;;
  esac
}

run_one() {
  local name="$1" script code line tag op a b
  case "$name" in
    *.json) script="$name"; name="$(basename "$name" .json)" ;;
    *) script="$ROOT/Demos/$name.json" ;;
  esac
  [ -f "$script" ] || { echo "run-demo: no demo $script" >&2; return 2; }
  local tmp out
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/deskterior-demo.XXXXXX")" || tmp=""
  [ -n "$tmp" ] && [ -d "$tmp" ] || { echo "run-demo: mktemp failed" >&2; return 2; }
  DESK="$tmp/desk"
  STATE="$tmp/state"
  SOURCE="$tmp/source"
  local state="$STATE"
  out="$OUT_ROOT/$name"
  mkdir -p "$state" "$SOURCE" "$out" || return 2
  rm -f "$out"/*.png
  local record=()
  if [ "$RECORD" -gt 0 ]; then
    mkdir -p "$out/frames" || return 2
    rm -f "$out/frames"/*.png
    record=(--demo-record "$out/frames" --demo-record-every "$RECORD")
  fi
  # --count wins over the script's own "fixtureCount" (11-overflow-500).
  local count="$COUNT"
  if [ "$count" -eq 0 ]; then
    count="$(sed -n 's/.*"fixtureCount"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$script" | head -n 1)"
    [ -n "$count" ] || count=0
  fi
  if [ "$count" -gt 0 ]; then
    "$ROOT/scripts/make-fixture-desktop.sh" --count "$count" "$DESK" >&2 || return 2
  else
    "$ROOT/scripts/make-fixture-desktop.sh" "$DESK" >&2 || return 2
  fi
  mkfifo "$tmp/to-app" "$tmp/from-app" || return 2
  echo "run-demo: $name (fixture $DESK)" >&2
  DESKTERIOR_DEMO_FS=stdio DESKTERIOR_DEMO_SOURCE="$SOURCE" "$APP" --headless --demo "$script" --desktop-folder "$DESK" --state-dir "$state" \
    --seed 1 --snapshot-dir "$out" --snapshot-scale "$SCALE" ${record[@]+"${record[@]}"} <"$tmp/to-app" >"$tmp/from-app" &
  local pid=$!
  exec 3>"$tmp/to-app"
  exec 4<"$tmp/from-app"
  while IFS= read -r line <&4; do
    case "$line" in
      DEMO-FS*)
        IFS="$(printf '\t')" read -r tag op a b <<EOF
$line
EOF
        if fs_op "$op" "$a" "$b"; then printf 'ok\n' >&3; else printf 'refused\n' >&3; fi
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
  exec 3>&- 4<&-
  # The caller turns errexit back on once it has the code (a failing demo must not stop the others).
  set +e
  wait "$pid"
  code=$?
  rm -rf "$tmp"
  echo "run-demo: $name exit $code; snapshots in $out" >&2
  return "$code"
}

status=0
for n in "${NAMES[@]}"; do
  set +e
  run_one "$n"
  code=$?
  set -e
  if [ "$code" -ne 0 ] && [ "$status" -eq 0 ]; then status=$code; fi
done
exit "$status"
