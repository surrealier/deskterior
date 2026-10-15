#!/bin/bash
# shot.sh NAME [CROP_pt x0 y0 x1 y1]: screenshot with the widget corner blacked out; writes r2/NAME.png (full device px)
# and r2/NAME-s.png (1470 wide, or the crop at device px).
C="$(cd "$(dirname "$0")" && pwd)"; mkdir -p "$C/r2"
screencapture -x "$C/r2/$1-raw.png"
ffmpeg -v error -y -i "$C/r2/$1-raw.png" -vf "drawbox=x=0:y=70:w=760:h=400:color=black:t=fill" "$C/r2/$1.png"; rm -f "$C/r2/$1-raw.png"
if [ -n "$5" ]; then
  ffmpeg -v error -y -i "$C/r2/$1.png" -vf "crop=$(( ($4-$2)*2 )):$(( ($5-$3)*2 )):$(( $2*2 )):$(( $3*2 ))" "$C/r2/$1-s.png"
else
  ffmpeg -v error -y -i "$C/r2/$1.png" -vf "scale=1470:-1:flags=area" "$C/r2/$1-s.png"
fi
echo "$C/r2/$1-s.png"
