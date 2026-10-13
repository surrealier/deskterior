#!/usr/bin/env bash
# Runs scripted demos headless against a fresh fixture desktop (docs/DESIGN.md §8.2, docs/DEMOS.md). Portable to
# macOS's bash 3.2.
#
# Usage: scripts/run-demo.sh [--out DIR] [--scale N] [--count N] [--release] NAME|FILE [NAME|FILE ...]
#   NAME runs Demos/NAME.json. Each demo gets a new mktemp fixture (scripts/make-fixture-desktop.sh, about 40
#   items; --count N for more) and a new mktemp state folder, then runs
#     Deskterior --headless --demo FILE --desktop-folder FIXTURE --state-dir STATE --seed 1
#                --snapshot-dir OUT/NAME --snapshot-scale N
#   OUT defaults to .build/demo-out. Env: SWIFT_SCRATCH_PATH (build folder, e.g. .build-w4-core), SWIFT_JOBS
#   (default 3), DESKTERIOR_BIN (a built Deskterior; skips the build).
#
# The real desktop is never used: fixture and state folders come from mktemp, make-fixture-desktop.sh refuses
# targets inside the real desktop, and the app refuses (exit 64) a mirrored, state or snapshot folder that is the
# real desktop or inside it. The demo's fs steps (touch, mkdir, mv, rm) are performed here, inside the fixture
# only: the app asks on stdout ("DEMO-FS<TAB>op<TAB>name[<TAB>name]") and waits for "ok" on its stdin, so the app
# itself never changes a file.
# Exit: 0 when every demo passes, else the first failing demo's code (1 expectation, 2 script error, 64 guard).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="$ROOT/.build/demo-out"
SCALE=3
COUNT=0
CONFIG=debug
NAMES=()

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || usage; OUT_ROOT="$2"; shift 2 ;;
    --scale) [ $# -ge 2 ] || usage; SCALE="$2"; shift 2 ;;
    --count) [ $# -ge 2 ] || usage; COUNT="$2"; shift 2 ;;
    --release) CONFIG=release; shift ;;
    -h|--help) usage ;;
    -*) echo "run-demo: unknown option $1" >&2; usage ;;
    *) NAMES+=("$1"); shift ;;
  esac
done
[ "${#NAMES[@]}" -gt 0 ] || usage

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

plain() { case "$1" in ""|.|..|*/*) return 1 ;; esac; return 0; }

# Performs one fs request inside the fixture $DESK: op, name, [name].
fs_op() {
  local op="$1" a="$2" b="${3:-}"
  plain "$a" || return 1
  case "$op" in
    touch) touch "$DESK/$a" ;;
    mkdir) mkdir -p "$DESK/$a" ;;
    rm) rm -rf "$DESK/$a" ;;
    mv) plain "$b" || return 1; mv "$DESK/$a" "$DESK/$b" ;;
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
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/deskterior-demo.XXXXXX")"
  DESK="$tmp/desk"
  local state="$tmp/state"
  out="$OUT_ROOT/$name"
  mkdir -p "$state" "$out"
  rm -f "$out"/*.png
  if [ "$COUNT" -gt 0 ]; then
    "$ROOT/scripts/make-fixture-desktop.sh" --count "$COUNT" "$DESK" >&2
  else
    "$ROOT/scripts/make-fixture-desktop.sh" "$DESK" >&2
  fi
  mkfifo "$tmp/to-app" "$tmp/from-app"
  echo "run-demo: $name (fixture $DESK)" >&2
  DESKTERIOR_DEMO_FS=stdio "$APP" --headless --demo "$script" --desktop-folder "$DESK" --state-dir "$state" \
    --seed 1 --snapshot-dir "$out" --snapshot-scale "$SCALE" <"$tmp/to-app" >"$tmp/from-app" &
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
  set +e
  wait "$pid"
  code=$?
  set -e
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
