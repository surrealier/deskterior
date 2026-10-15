#!/bin/bash
# hideall.sh: hides every other regular app (director hide) and adds them to hidden-all.txt for the final unhide.
C="$(cd "$(dirname "$0")" && pwd)"
"$C/tools/director" hide "$C/hidden-extra.txt"; { cat "$C/hidden-extra.txt"; echo; } >> "$C/hidden-all.txt"
