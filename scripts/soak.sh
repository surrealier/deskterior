#!/usr/bin/env bash
# Memory soak (docs/DESIGN.md §5: < 10 MB RSS growth over a 1-hour soak; M12). Portable to macOS's bash 3.2.
#
# Usage: scripts/soak.sh [--minutes N] [--limit MB] [--interval S] [--release]
#   Writes a demo script into a mktemp folder that repeats one cycle — a file appears in the fixture, is renamed,
#   carried into the left riser drawer, taken back out, the monitor goes off and on, the lights go to night and back,
#   and the file is removed — and runs it headless through scripts/run-demo.sh (a fresh mktemp fixture and state
#   folder; the fs churn is done by the harness, never by the app). While it runs, the app's resident memory is
#   sampled with `ps` every --interval seconds (default 10). After --minutes (default 60) the app is stopped if it is
#   still running. The growth is the median of the last three samples minus the median of the three samples after
#   warm-up (the first fifth of the run, at least two samples); it fails (exit 1) above --limit (default 10 MB).
#   A failing expectation inside the cycle is reported but only memory decides the result. A run that does not last
#   the whole --minutes (the app exited: a script error or a crash) is not a soak and fails with exit 2.
#   The soak is headless (the scene, the mirror, the store and the renderer, not the AppKit windows).
#   Env: SWIFT_SCRATCH_PATH (build folder), SWIFT_JOBS, DESKTERIOR_BIN (a built Deskterior; no build).
#
# Safety: everything runs headless on a throwaway fixture; the real desktop and the real Trash are never touched
# (run-demo.sh and the app both refuse a real-desktop path, exit 64), and the run is bounded by --minutes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINUTES=60
LIMIT=10
INTERVAL=10
RELEASE=()

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) [ $# -ge 2 ] || usage; MINUTES="$2"; shift 2 ;;
    --limit) [ $# -ge 2 ] || usage; LIMIT="$2"; shift 2 ;;
    --interval) [ $# -ge 2 ] || usage; INTERVAL="$2"; shift 2 ;;
    --release) RELEASE=(--release); shift ;;
    -h|--help) usage ;;
    *) echo "soak: unknown option $1" >&2; usage ;;
  esac
done
case "$MINUTES$INTERVAL" in *[!0-9]*) echo "soak: --minutes and --interval take whole numbers" >&2; exit 2 ;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deskterior-soak.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SCRIPT="$TMP/soak.json"
OUT="$TMP/out"

# One cycle takes about 3 s of real time (the watcher's batching dominates); write more than the run can use (one a
# second; the app is stopped at the time limit, and running out of cycles early counts as exiting early).
CYCLES=$(( MINUTES * 60 + 4 ))
{
  printf '{\n  "name": "soak",\n  "display": "1470x956@2",\n  "clock": "10:00",\n  "seed": 1,\n  "steps": [\n'
  printf '    { "waitIdle": 15 },\n'
  printf '    { "expect": { "access": "connected" } },\n'
  i=1
  while [ "$i" -le "$CYCLES" ]; do
    n="soak-$i.txt"
    m="soak-$i-renamed.txt"
    printf '    { "comment": "cycle %d" },\n' "$i"
    printf '    { "fs": { "touch": "%s" } },\n' "$n"
    printf '    { "waitFor": { "expect": { "token:%s": "screen" }, "within": 5 } },\n' "$n"
    printf '    { "fs": { "mv": ["%s", "%s"] } },\n' "$n" "$m"
    printf '    { "waitFor": { "expect": { "token:%s": "screen" }, "within": 5 } },\n' "$m"
    printf '    { "waitIdle": 2 },\n'
    printf '    { "drag": { "from": "token:%s", "to": "riser.drawerL.front", "duration": 0.3 } },\n' "$m"
    printf '    { "waitIdle": 2 },\n'
    printf '    { "menu": { "at": "riser.drawerL.front", "item": "takeAllOut" } },\n'
    printf '    { "waitIdle": 3 },\n'
    printf '    { "action": "powerOff" },\n    { "waitIdle": 2 },\n    { "action": "powerOn" },\n    { "waitIdle": 2 },\n'
    printf '    { "action": "lights:night" },\n    { "waitIdle": 1 },\n    { "action": "lights:auto" },\n'
    printf '    { "fs": { "rm": "%s" } },\n' "$m"
    printf '    { "waitFor": { "expect": { "token:%s": "missing" }, "within": 5 } },\n' "$m"
    printf '    { "waitIdle": 2 },\n'
    i=$((i + 1))
  done
  printf '    { "comment": "done" }\n  ]\n}\n'
} > "$SCRIPT"

# The build happens before the clock starts.
if [ -z "${DESKTERIOR_BIN:-}" ]; then
  BUILD=(swift build -j "${SWIFT_JOBS:-3}")
  [ "${#RELEASE[@]}" -eq 0 ] || BUILD+=(-c release)
  [ -z "${SWIFT_SCRATCH_PATH:-}" ] || BUILD+=(--scratch-path "$SWIFT_SCRATCH_PATH")
  (cd "$ROOT" && "${BUILD[@]}" --product Deskterior >&2 && "${BUILD[@]}" --product deskterior-assets >&2)
  export DESKTERIOR_BIN="$(cd "$ROOT" && "${BUILD[@]}" --show-bin-path)/Deskterior"
fi

echo "soak: $MINUTES min, $CYCLES cycles written, sampling every $INTERVAL s, limit $LIMIT MB" >&2
"$ROOT/scripts/run-demo.sh" --out "$OUT" --scale 1 ${RELEASE[@]+"${RELEASE[@]}"} "$SCRIPT" >"$TMP/run.log" 2>&1 &
RUNNER=$!

# The app's PID: the process running this demo script.
PID=""
for _ in $(seq 1 300); do
  PID="$(pgrep -f -- "--demo $SCRIPT" | head -n 1 || true)"
  [ -n "$PID" ] && break
  kill -0 "$RUNNER" 2>/dev/null || break
  sleep 0.2
done
if [ -z "$PID" ]; then
  cat "$TMP/run.log" >&2
  echo "soak: the app did not start" >&2
  exit 2
fi

START=$(date +%s)
END=$(( START + MINUTES * 60 ))
SAMPLES=()
while kill -0 "$PID" 2>/dev/null && [ "$(date +%s)" -lt "$END" ]; do
  RSS_KB="$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ' || true)"
  if [ -n "$RSS_KB" ]; then
    SAMPLES+=("$RSS_KB")
    printf 'soak: %4d s  rss %6.1f MB  (%s)\n' "$(( $(date +%s) - START ))" "$(awk -v k="$RSS_KB" 'BEGIN { print k / 1024 }')" \
      "$(grep -c '^demo soak: # cycle' "$TMP/run.log" 2>/dev/null || true) cycles"
  fi
  sleep "$INTERVAL"
done
STOPPED=0
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID" 2>/dev/null || true
  STOPPED=1
fi
wait "$RUNNER" 2>/dev/null || true

FAILS="$(grep -c 'demo soak: FAIL' "$TMP/run.log" || true)"
CYCLES_RUN="$(grep -c '^demo soak: # cycle' "$TMP/run.log" || true)"
N=${#SAMPLES[@]}
if [ "$STOPPED" -eq 0 ]; then
  tail -n 20 "$TMP/run.log" >&2
  echo "soak: the app exited after $(( $(date +%s) - START )) s of $(( MINUTES * 60 )) s ($CYCLES_RUN cycles): not a soak" >&2
  exit 2
fi
if [ "$N" -lt 6 ]; then
  tail -n 20 "$TMP/run.log" >&2
  echo "soak: too few samples ($N); run longer or sample more often" >&2
  exit 2
fi
WARM=$(( N / 5 ))
[ "$WARM" -ge 2 ] || WARM=2
median3() { printf '%s\n' "$@" | sort -n | sed -n '2p'; }
BASE="$(median3 "${SAMPLES[$WARM]}" "${SAMPLES[$((WARM + 1))]}" "${SAMPLES[$((WARM + 2))]}")"
LAST="$(median3 "${SAMPLES[$((N - 3))]}" "${SAMPLES[$((N - 2))]}" "${SAMPLES[$((N - 1))]}")"
GROWTH="$(awk -v a="$BASE" -v b="$LAST" 'BEGIN { printf "%.2f", (b - a) / 1024 }')"
PEAK="$(printf '%s\n' "${SAMPLES[@]}" | sort -n | tail -n 1)"
echo "soak: $CYCLES_RUN cycles in $(( $(date +%s) - START )) s$([ "$STOPPED" -eq 1 ] && echo ' (stopped at the time limit)'); $FAILS failed expectations"
echo "soak: rss after warm-up $(awk -v k="$BASE" 'BEGIN { printf "%.1f", k / 1024 }') MB, at the end $(awk -v k="$LAST" 'BEGIN { printf "%.1f", k / 1024 }') MB, peak $(awk -v k="$PEAK" 'BEGIN { printf "%.1f", k / 1024 }') MB; growth $GROWTH MB (limit $LIMIT MB)"
[ "$FAILS" -eq 0 ] || grep 'demo soak: FAIL' "$TMP/run.log" | head -n 5 >&2
if awk -v g="$GROWTH" -v l="$LIMIT" 'BEGIN { exit !(g > l) }'; then
  echo "soak: FAIL" >&2
  exit 1
fi
echo "soak: pass"
