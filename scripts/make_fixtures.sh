#!/usr/bin/env bash
# SPECTRE Capture — generates SYNTHETIC video fixtures (no real footage, no real place).
# Requires ffmpeg/ffprobe (macOS: brew install ffmpeg).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=tests/fixtures/generated
mkdir -p "$OUT"
command -v ffmpeg >/dev/null || { echo "ffmpeg missing (brew install ffmpeg)"; exit 2; }

# 1) Short 1080p30 H.264 + AAC QuickTime with technical metadata and a FICTIONAL
#    location (Null Island 0,0) to check that metadata survive the deposit untouched.
ffmpeg -loglevel error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=3" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=3" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \
  -metadata creation_time="2026-11-04T12:00:00Z" \
  -metadata location="+00.0000+000.0000/" \
  -metadata comment="SPECTRE synthetic fixture - not real footage" \
  -movflags +use_metadata_tags \
  "$OUT/short_1080p30_meta.mov"

# 2) 4K60 sample (only to exercise size/codec metadata paths; not a camera capability claim)
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=3840x2160:rate=60:duration=1" \
  -c:v libx264 -pix_fmt yuv420p -preset ultrafast "$OUT/short_2160p60.mov"

for f in "$OUT"/*.mov; do
  echo "== $f"
  ffprobe -v error -show_entries format=duration,size:format_tags=creation_time,location,comment:stream=codec_name,width,height,r_frame_rate -of compact "$f"
  shasum -a 256 "$f" 2>/dev/null || sha256sum "$f"
done
