#!/bin/bash
# Real AVPlayer witness for raw-TS fast joins with 5 s and 10 s closed GOPs.
set -euo pipefail
cd "$(dirname "$0")/.."
AETHER_FFMPEG="${FFMPEG_BIN:-ffmpeg}"
AETHER_FIXTURES=$(mktemp -d "${TMPDIR:-/tmp}/aether-long-gop.XXXXXX")
trap 'rm -rf "$AETHER_FIXTURES"' EXIT
for gop in 5 10; do
    "$AETHER_FFMPEG" -hide_banner -loglevel error \
        -f lavfi -i 'testsrc2=size=320x180:rate=25' \
        -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
        -t 40 -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
        -g "$((gop * 25))" -keyint_min "$((gop * 25))" -sc_threshold 0 \
        -bf 3 -b:v 350k -c:a aac -b:a 64k -muxrate 700000 -f mpegts \
        "$AETHER_FIXTURES/gop-$gop.ts"
done
AETHER_LONG_GOP_FIXTURES="$AETHER_FIXTURES" swift test --filter LongGOPLiveStartupTests
