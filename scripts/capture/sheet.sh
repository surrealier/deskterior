#!/bin/bash
# sheet.sh IN OUT.png [COLS] [ROWS] [SCALE]: an evenly sampled contact sheet of a clip or GIF (frame number drawn on each).
IN="$1"; OUT="$2"; COLS="${3:-4}"; ROWS="${4:-4}"; SC="${5:-0.5}"
N=$(ffprobe -v error -count_frames -select_streams v -show_entries stream=nb_read_frames -of csv=p=0 "$IN")
K=$(( (N + COLS*ROWS - 1) / (COLS*ROWS) )); [ $K -lt 1 ] && K=1
ffmpeg -v error -y -i "$IN" -vf "select='not(mod(n\,$K))',scale=iw*$SC:-1:flags=area,tile=${COLS}x${ROWS}:padding=4:color=gray" -frames:v 1 -fps_mode vfr "$OUT" 2>&1 | grep -v "^$" | head -3
echo "frames $N, every $K"
