#!/usr/bin/env bash
# Idle CPU after an interaction burst (docs/DESIGN.md §5; M7 accept: ≤ 0.3%). Portable to macOS's bash 3.2.
#
# Usage: scripts/measure-idle.sh [--debug] [--limit PCT] [--exit-after SECONDS]
#   Builds Deskterior (release unless --debug), makes a fresh mktemp fixture (scripts/make-fixture-desktop.sh) and
#   state folder, and runs
#     Deskterior --windowed 1470x956@2 --desktop-folder FIXTURE --state-dir STATE --icons kind --clock 10:00
#                --burst --exit-after SECONDS            (default 10, a quick check: about 4 one-second samples;
#                                                         DESIGN §5's 60-s average needs --exit-after 70 or more)
#   --burst plays a short scripted interaction (a pile set down, a fling, a drop into the basket, a desk knock) once
#   the fixture is on the monitor and prints "burst: done". After a settle period the script samples the process's
#   CPU with `top` (one-second interval samples, precise to 0.1%) and with `ps` (accumulated CPU time over the same
#   tail: `ps -o time` is the only `ps` field that is not a minute-long decaying average), prints both averages, and
#   fails (exit 1) when the `top` average is above the limit (default 0.3).
#   Env: SWIFT_SCRATCH_PATH (build folder), SWIFT_JOBS (default 3), DESKTERIOR_BIN (a built Deskterior; no build),
#   DESKTERIOR_RESOURCES (default Resources/: a release binary needs it for the font, so tooltips and toasts draw).
#
# Safety: the window is a normal titled window over a throwaway fixture; the real desktop and the real Trash are
# never touched (the app refuses, exit 64, a mirrored or state folder that is, or is inside, the real desktop), and
# --exit-after bounds the run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=release
LIMIT=0.3
SETTLE=${MEASURE_IDLE_SETTLE:-2.5}
EXIT_AFTER=10

usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIG=debug; shift ;;
    --limit) [ $# -ge 2 ] || usage; LIMIT="$2"; shift 2 ;;
    --exit-after) [ $# -ge 2 ] && [ "$2" -ge 8 ] 2>/dev/null || usage; EXIT_AFTER="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "measure-idle: unknown option $1" >&2; usage ;;
  esac
done

if [ -n "${DESKTERIOR_BIN:-}" ]; then
  APP="$DESKTERIOR_BIN"
else
  BUILD=(swift build -c "$CONFIG" -j "${SWIFT_JOBS:-3}")
  [ -z "${SWIFT_SCRATCH_PATH:-}" ] || BUILD+=(--scratch-path "$SWIFT_SCRATCH_PATH")
  (cd "$ROOT" && "${BUILD[@]}" --product Deskterior >&2 && "${BUILD[@]}" --product deskterior-assets >&2)
  BIN_DIR="$(cd "$ROOT" && "${BUILD[@]}" --show-bin-path)"
  APP="$BIN_DIR/Deskterior"
  if [ -x "$BIN_DIR/deskterior-assets" ]; then export DESKTERIOR_ASSETS="$BIN_DIR/deskterior-assets"; fi
fi
[ -x "$APP" ] || { echo "measure-idle: no Deskterior binary at $APP" >&2; exit 2; }
export DESKTERIOR_RESOURCES="${DESKTERIOR_RESOURCES:-$ROOT/Resources}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deskterior-idle.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
"$ROOT/scripts/make-fixture-desktop.sh" "$TMP/desk" >&2
mkdir -p "$TMP/state"

# CPU seconds (user + system) of a process from `ps -o time` ([[dd-]hh:]mm:ss.cc); empty once it has exited.
cpu_seconds() {
  { ps -o time= -p "$1" 2>/dev/null || true; } | awk '{
    n = split($1, a, /[-:]/); s = 0
    for (i = 1; i <= n; i++) s = s * 60 + a[i]
    printf "%.2f", s }'
}

"$APP" --windowed 1470x956@2 --desktop-folder "$TMP/desk" --state-dir "$TMP/state" --icons kind --clock 10:00 \
  --burst --exit-after "$EXIT_AFTER" >"$TMP/out.log" 2>&1 &
PID=$!
START=$(date +%s)

# Wait for the burst to finish (at most 8 s), then let the motion settle and the loop go to sleep.
while ! grep -q "burst: done" "$TMP/out.log" 2>/dev/null; do
  if ! kill -0 "$PID" 2>/dev/null || [ $(( $(date +%s) - START )) -ge 8 ]; then
    cat "$TMP/out.log" >&2
    echo "measure-idle: the burst did not finish" >&2
    wait "$PID" 2>/dev/null || true
    exit 2
  fi
  sleep 0.1
done
echo "measure-idle: burst done $(( $(date +%s) - START )) s after launch" >&2
sleep "$SETTLE"

ELAPSED=$(( $(date +%s) - START ))
# Sampling ends 2 s before the app quits (`date +%s` is whole seconds), so the final `ps` still finds it.
SAMPLES=$(( EXIT_AFTER - 3 - ELAPSED ))
[ "$SAMPLES" -ge 2 ] || SAMPLES=2
CPU0="$(cpu_seconds "$PID")"
T0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
# top's first sample has no interval; the rest are one-second averages.
TOP="$({ top -l $(( SAMPLES + 1 )) -s 1 -pid "$PID" -stats pid,cpu 2>/dev/null || true; } \
  | awk -v pid="$PID" '$1 == pid { print $2 }' | tail -n "$SAMPLES")"
CPU1="$(cpu_seconds "$PID")"
T1="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
wait "$PID" 2>/dev/null || true

echo "measure-idle: top samples (%): $(echo $TOP)"
TOP_AVG="$(echo "$TOP" | awk '{ s += $1; n++ } END { if (n) printf "%.2f", s / n; else print "nan" }')"
if [ -n "$CPU0" ] && [ -n "$CPU1" ]; then
  PS_AVG="$(awk -v a="$CPU0" -v b="$CPU1" -v t0="$T0" -v t1="$T1" 'BEGIN { printf "%.2f%%", (b - a) / (t1 - t0) * 100 }')"
else
  PS_AVG="n/a (the app had exited)"
fi
echo "measure-idle: idle tail average: top ${TOP_AVG}%, ps cpu time ${PS_AVG} (±$(awk -v t0="$T0" -v t1="$T1" 'BEGIN { printf "%.2f", 1 / (t1 - t0) }')%) over $(awk -v t0="$T0" -v t1="$T1" 'BEGIN { printf "%.1f", t1 - t0 }') s; limit ${LIMIT}%"
if awk -v v="$TOP_AVG" -v l="$LIMIT" 'BEGIN { exit !(v == "nan" || v + 0 > l + 0) }'; then
  echo "measure-idle: FAIL" >&2
  exit 1
fi
echo "measure-idle: pass"
