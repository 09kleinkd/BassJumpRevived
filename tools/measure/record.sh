#!/bin/bash
# record.sh <name> [mic-index]: records 7 s from the mic while pink noise plays after 1 s.
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
OUT=/tmp/bjmeasure; mkdir -p "$OUT"
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$OUT/pink.wav" ] || python3 "$DIR/pink.py" "$OUT/pink.wav" 4
ffmpeg -hide_banner -loglevel error -y -f avfoundation -i ":${2:-3}" -t 7 -ar 48000 -ac 1 "$OUT/$1.wav" &
REC=$!
sleep 1.2
afplay "$OUT/pink.wav"
wait $REC
echo "recorded $OUT/$1.wav"
