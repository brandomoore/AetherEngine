#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
AETHER_FFMPEG="${FFMPEG_BIN:-ffmpeg}"
AETHER_FIXTURE=$(mktemp "${TMPDIR:-/tmp}/aether-vod.XXXXXX")
AETHER_CAPTIONS=$(mktemp "${TMPDIR:-/tmp}/aether-vod-subtitles.XXXXXX")
trap 'rm -f "$AETHER_FIXTURE" "$AETHER_CAPTIONS"' EXIT
cat > "$AETHER_CAPTIONS" <<'SRT'
1
00:00:00,000 --> 00:00:06,000
First caption

2
00:00:06,000 --> 00:00:14,000
Middle caption

3
00:00:14,000 --> 00:00:20,000
Last caption
SRT
"$AETHER_FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=320x180:rate=25' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
    -f srt -i "$AETHER_CAPTIONS" -map 0:v -map 1:a -map 2:s \
    -t 20 -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    -g 50 -keyint_min 50 -sc_threshold 0 -bf 3 -b:v 350k \
    -c:a aac -b:a 64k -c:s srt -metadata:s:s:0 language=eng -f matroska "$AETHER_FIXTURE"
AETHER_VOD_FIXTURE="$AETHER_FIXTURE" swift test --filter VODOpenSeekIntegrationTests
