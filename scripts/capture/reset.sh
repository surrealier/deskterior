#!/bin/bash
# Fresh take: quit the capture app, rebuild the showcase, relaunch at 16:00 in English, connect, place the Finder window, hide other apps.
C="$(cd "$(dirname "$0")" && pwd)"; T="$C/tools"
"$T/quitapp" Deskterior >/dev/null; sleep 1.5
"$C/mkshowcase.sh"
rm -rf "$C/state"; mkdir -p "$C/state"
nohup "$C/Deskterior.app/Contents/MacOS/Deskterior" --desktop-folder "$C/showcase/Desktop" --state-dir "$C/state" --clock 16:00 --language en > "$C/app.log" 2>&1 &
sleep 4
"$T/director" hide "$C/hidden-extra.txt" >/dev/null; { cat "$C/hidden-extra.txt"; echo; } >> "$C/hidden-all.txt"
echo '[{"click":[968,478],"dur":0.3},{"wait":2.5}]' > "$C/s-connect.json"; "$T/director" run "$C/s-connect.json" >/dev/null
open "$C/Apps"; sleep 1.2
"$T/menupress" Finder 보기 "사이드바 가리기"; sleep 0.5
"$T/winpos" Finder 1060 70 380 230 Apps || exit 1
"$T/director" hide "$C/hidden-extra.txt" >/dev/null; { cat "$C/hidden-extra.txt"; echo; } >> "$C/hidden-all.txt"
echo '[{"warp":[1180,300]},{"wait":0.8}]' > "$C/s-park.json"; "$T/director" run "$C/s-park.json" >/dev/null
echo "reset done"
