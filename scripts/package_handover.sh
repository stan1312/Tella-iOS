#!/usr/bin/env bash
# SPECTRE Capture — clean source archive of the current commit (no build products, no secrets).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
REV=$(git rev-parse --short HEAD)
git archive --format=zip --prefix=SPECTRE-Capture/ -o "dist/SPECTRE-Capture-$REV.zip" HEAD
shasum -a 256 "dist/SPECTRE-Capture-$REV.zip" 2>/dev/null || sha256sum "dist/SPECTRE-Capture-$REV.zip"
