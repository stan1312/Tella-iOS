#!/usr/bin/env bash
# SPECTRE Capture — runs every test executable WITHOUT Apple/Google accounts.
# Linux or macOS. Requires: node >= 18, swift >= 5.9, (optional) ffmpeg.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
OUT=test-results; mkdir -p "$OUT"
status=0
echo "== 1/3 backend (real Apps Script code + mock Drive)"
(cd backend && node --test --test-reporter=spec apps-script/test/*.test.mjs) 2>&1 | tee "$OUT/backend.log" | tail -12
[ "${PIPESTATUS[0]}" -eq 0 ] || status=1
echo "== 2/3 synthetic video fixtures"
if command -v ffmpeg >/dev/null; then ./scripts/make_fixtures.sh > "$OUT/fixtures.log" 2>&1 && echo "fixtures OK"; else echo "ffmpeg absent: T12 will be SKIPPED"; fi
echo "== 3/3 SpectreCore (unit + end-to-end scenarios T01-T14)"
command -v swift >/dev/null || { echo "swift introuvable (Xcode sur Mac, ou toolchain Swift sur Linux)"; exit 1; }
(cd SpectreCore && swift test) 2>&1 | tee "$OUT/spectrecore.log" | grep -E "Test Case .*(passed|failed|skipped)|Executed .* tests" | tail -40
[ "${PIPESTATUS[0]}" -eq 0 ] || status=1
echo "== secret scan"
./scripts/secret_scan.sh || status=1
echo "RESULT: $([ $status -eq 0 ] && echo ALL PASSED || echo FAILURES — see $OUT/)"
exit $status
