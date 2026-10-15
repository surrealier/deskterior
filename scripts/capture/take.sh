#!/bin/bash
# take.sh NAME TAKE CROP [SCALE]: records scenes/NAME.json into takes/NAME-TAKE.mkv (CROP "full" = the default whole room).
C="$(cd "$(dirname "$0")" && pwd)"; export CAP="$C"; N="$1"; T="$2"; CROP="$3"; SC="$4"
OUT="$C/takes/$N-$T.mkv"
if [ "$CROP" = full ]; then "$C/record.sh" start "$OUT"; else "$C/record.sh" start "$OUT" "$CROP" $SC; fi
"$C/tools/director" run "$C/scenes/$N.json" --limit 120; R=$?
"$C/record.sh" stop >/dev/null
echo "director exit $R -> $OUT"; ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT"
