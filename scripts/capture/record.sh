#!/bin/bash
# record.sh start OUT.mkv [CROP [SCALE]] | stop
#   Default: the screen below the menu bar, art-aligned (y from 69 device px), area-scaled 5→2 px per art px, lossless.
#   CROP  W:H:X:Y in device px (keep X ≡ 0, Y ≡ 4 mod 5 and W, H multiples of 5 so art pixels stay whole).
#   SCALE W:H of the output; without it a crop is area-scaled ×0.8 (4 px per art px) for close-ups.
C="$(cd "$(dirname "$0")" && pwd)"
case "$1" in
  start)
    CROP="${3:-2940:1840:0:69}"
    if [ -n "$4" ]; then SCALE="$4"
    elif [ -n "$3" ]; then IFS=: read -r W H _ _ <<< "$CROP"; SCALE="$((W * 4 / 5)):$((H * 4 / 5))"
    else SCALE="1176:736"; fi
    ffmpeg -v error -y -f avfoundation -pixel_format bgr0 -capture_cursor 1 -framerate 30 -i "1:none" \
      -vf "crop=$CROP,scale=$SCALE:flags=area" -c:v ffv1 -pix_fmt bgr0 "$2" > "$C/ffmpeg.log" 2>&1 &
    echo $! > "$C/ffmpeg.pid"; sleep 1.5 ;;
  stop)
    kill -INT "$(cat "$C/ffmpeg.pid")"; while kill -0 "$(cat "$C/ffmpeg.pid")" 2>/dev/null; do sleep 0.2; done; echo stopped ;;
esac
