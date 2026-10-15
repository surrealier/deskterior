#!/bin/bash
# Rebuilds the showcase Desktop folder (app aliases and generated files) and puts the scratch Apps back.
C="$(cd "$(dirname "$0")" && pwd)"; D="$C/showcase/Desktop"
for a in Music Notes Calculator; do [ -d "$D/$a.app" ] && mv "$D/$a.app" "$C/Apps/"; done
rm -rf "$C/showcase"; mkdir -p "$D"
for pair in "/Applications/Claude.app:Claude" "/Applications/ChatGPT.app:ChatGPT" "/Applications/Safari.app:Safari" "/System/Applications/Books.app:Books" "/System/Applications/Weather.app:Weather" "/System/Applications/Calendar.app:Calendar" "/System/Applications/Maps.app:Maps" "/System/Applications/Photos.app:Photos"; do
  "$C/tools/mkalias" "${pair%%:*}" "$D/${pair##*:}"; done
cd "$D" || exit 1
ffmpeg -v error -f lavfi -i "mandelbrot=size=1600x1200:end_pts=4:start_scale=2:end_scale=0.02" -frames:v 1 -update 1 "IMG_2041.jpg"
ffmpeg -v error -f lavfi -i "gradients=size=1600x1066:c0=0xff7a3d:c1=0x5b2a86:c2=0xffd36e:x0=0:y0=0:x1=1600:y1=1066:seed=7" -frames:v 1 -update 1 "Sunset.jpg"
ffmpeg -v error -f lavfi -i "cellauto=rule=110:size=1200x900:rate=1,scale=1200:900,colorchannelmixer=.3:.4:.3:0:.6:.8:.2:0:.2:.5:.9" -frames:v 1 -update 1 "제주 여행.jpg"
ffmpeg -v error -f lavfi -i "testsrc2=size=1470x956" -frames:v 1 -update 1 "Screenshot 2026-10-15 at 14.02.11.png"
T="$(mktemp -d)"; printf 'Invoice #1042\n\nDesk lamp   $39\nDesk mat    $24\n\nTotal       $63\n' > "$T/i.txt"; cupsfilter "$T/i.txt" > "Invoice.pdf" 2>/dev/null
printf '분기 보고서\n\n1. 요약\n2. 일정\n' > "$T/r.txt"; cupsfilter "$T/r.txt" > "보고서 final.pdf" 2>/dev/null
mkdir -p "Projects" "프로젝트"; printf '# To do\n- water the plant\n- tidy the desk\n' > "todo.md"; printf 'meeting at 3\n' > "notes.txt"
(cd "$T" && printf 'x' > a.txt && zip -q a.zip a.txt && mv a.zip "$D/archive.zip"); rm -rf "$T"
echo "showcase: $(ls "$D" | wc -l | tr -d ' ') items"
