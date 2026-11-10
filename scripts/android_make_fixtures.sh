#!/usr/bin/env bash
# SPECTRE Capture Android — SYNTHETIC fixtures in the formats the Android app produces
# (CameraX: H.264 + AAC in MP4). No real footage, fictional location (Null Island).
# Requires ffmpeg/ffprobe. Also runs scripts/make_fixtures.sh (QuickTime fixtures).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=tests/fixtures/generated
mkdir -p "$OUT"
command -v ffmpeg >/dev/null || { echo "ffmpeg missing"; exit 2; }
[ -f "$OUT/short_1080p30_meta.mov" ] && [ -f "$OUT/short_2160p60.mov" ] || ./scripts/make_fixtures.sh >/dev/null
ffmpeg -loglevel error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=3" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=3" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \
  -metadata creation_time="2026-11-04T12:00:00Z" \
  -metadata location="+00.0000+000.0000/" \
  -metadata comment="SPECTRE synthetic fixture - not real footage" \
  -movflags +use_metadata_tags \
  "$OUT/android_1080p30_meta.mp4"
ffprobe -v error -show_entries format=duration,size:format_tags=creation_time,location:stream=codec_name,width,height -of compact "$OUT/android_1080p30_meta.mp4"
