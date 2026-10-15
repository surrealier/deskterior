#!/bin/bash
# waitidle.sh N [MAX]: waits until the user has not touched mouse/keyboard for N seconds (gives up after MAX s, default 3600).
N=${1:-120}; MAX=${2:-3600}; t=0
while :; do
  i=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {printf "%d", $NF/1000000000; exit}')
  [ "$i" -ge "$N" ] && { echo "idle ${i}s"; exit 0; }
  [ "$t" -ge "$MAX" ] && { echo "still busy (idle ${i}s)"; exit 1; }
  s=$((N - i)); [ $s -gt 30 ] && s=30; [ $s -lt 2 ] && s=2
  sleep $s; t=$((t + s))
done
