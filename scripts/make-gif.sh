#!/usr/bin/env bash
# Records the scripted tour (Demos/hero.json) headless on a fresh mktemp fixture, assembles it as build/tour.gif and
# writes the README's stills (docs/DESIGN.md §6, docs/DEMOS.md). The README's docs/media/hero.gif is a real screen
# recording, not this tour. Needs ffmpeg. Portable to macOS's bash 3.2.
#
# Usage: scripts/make-gif.sh [--out DIR] [--every N] [--keep]
#   --out DIR    where the stills go (default docs/media)
#   --every N    record every Nth scene frame (default 3: 20 fps; 60 must divide by N)
#   --keep       keep the recorded frames and snapshots (their folder is printed)
# Env: SWIFT_SCRATCH_PATH, SWIFT_JOBS, DESKTERIOR_BIN as for scripts/run-demo.sh; GIF_MAX_BYTES (default 4 MiB).
#
# The demo runs through scripts/run-demo.sh --record (its own mktemp fixture and state folder; never the real
# desktop) with the built-in kind icons (--icons kind), so the media come out the same on every Mac and show no other
# apps' document icons. Frames are art px with the demo's pointer drawn in; the GIF is nearest-neighbour ×2 with a palette of
# the frames' own (Apollo) colours, no dithering, looping. The stills come from the demo's snapshots: desk.png (the
# room by day, ×2), mat-peel.png (the desk around the mat, its edge peeled off a pile, a ×4 crop), hiding.png (the
# riser, pen cup, phone and filing cabinet in use, a ×4 crop), lamp-only.png (Lamp Only at night, ×2) and
# partition.png (the desk partition with notes, the memo pad, memo clips and the D-Day card, a ×2 crop). The README
# shows each at half its width, so every art pixel is a whole number of screen pixels (1 or 2 for the ×2 images, 2 or
# 4 for the crops).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/docs/media"
EVERY=3
KEEP=0
MAX_BYTES="${GIF_MAX_BYTES:-4194304}"

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    --every) [ $# -ge 2 ] || usage; EVERY="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage ;;
    *) echo "make-gif: unknown argument $1" >&2; usage ;;
  esac
done
case "$EVERY" in ''|*[!0-9]*|0) echo "make-gif: --every needs a positive number" >&2; exit 2 ;; esac
[ $((60 % EVERY)) -eq 0 ] || { echo "make-gif: --every must divide 60" >&2; exit 2; }
command -v ffmpeg >/dev/null || { echo "make-gif: ffmpeg is required (e.g. brew install ffmpeg)" >&2; exit 1; }
"$ROOT/scripts/make-fixture-desktop.sh" --check "$OUT" || exit $?

WORK="$(mktemp -d "${TMPDIR:-/tmp}/deskterior-gif.XXXXXX")"
cleanup() {
  if [ "$KEEP" -eq 1 ]; then echo "make-gif: kept $WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

DESKTERIOR_ICONS=kind "$ROOT/scripts/run-demo.sh" --out "$WORK" --scale 2 --record "$EVERY" hero
FRAMES="$WORK/hero/frames"
COUNT="$(find "$FRAMES" -name 'frame-*.png' | wc -l | tr -d ' ')"
[ "$COUNT" -gt 0 ] || { echo "make-gif: the demo recorded no frames" >&2; exit 1; }

mkdir -p "$OUT"
mkdir -p "$ROOT/build"
GIF="$ROOT/build/tour.gif"
ffmpeg -v error -y -framerate "60/$EVERY" -i "$FRAMES/frame-%05d.png" \
  -vf "scale=iw*2:ih*2:flags=neighbor,split[a][b];[a]palettegen=max_colors=64:stats_mode=full:reserve_transparent=0[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  -loop 0 "$GIF"

for still in desk lamp-only; do
  cp "$WORK/hero/still-$still@2x.png" "$OUT/$still.png"
done
# Crops in canvas px of the hero's 1470x956@2 display (588x383), nearest ×4: the desk around the mat, and the hiding
# places from the riser to the filing cabinet.
ffmpeg -v error -y -i "$WORK/hero/still-peel.png" -vf "crop=288:96:150:204,scale=iw*4:ih*4:flags=neighbor" \
  "$OUT/mat-peel.png"
ffmpeg -v error -y -i "$WORK/hero/still-hiding.png" -vf "crop=300:182:212:201,scale=iw*4:ih*4:flags=neighbor" \
  "$OUT/hiding.png"
# The partition from the wall calendar down to the desk's back edge (core 8…504 × 20…176), nearest ×2.
ffmpeg -v error -y -i "$WORK/hero/still-partition.png" -vf "crop=496:156:46:77,scale=iw*2:ih*2:flags=neighbor" \
  "$OUT/partition.png"

BYTES="$(wc -c < "$GIF" | tr -d ' ')"
echo "make-gif: $GIF ($COUNT frames at $((60 / EVERY)) fps, $(awk "BEGIN { printf \"%.1f\", $COUNT * $EVERY / 60 }") s, $BYTES bytes)"
for still in desk mat-peel hiding lamp-only partition; do echo "make-gif: $OUT/$still.png ($(wc -c < "$OUT/$still.png" | tr -d ' ') bytes)"; done
if [ "$BYTES" -gt "$MAX_BYTES" ]; then
  echo "make-gif: $GIF is over $MAX_BYTES bytes" >&2
  exit 1
fi
