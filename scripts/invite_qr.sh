#!/usr/bin/env bash
# SPECTRE Capture — turns an invitation link (from spectreCreateInvite in Apps Script)
# into a QR code, entirely offline. Show it in person; it works once and expires.
# Usage: ./scripts/invite_qr.sh 'spectre://enroll?v=1&endpoint=...&code=...' [out.png]
set -euo pipefail
LINK="${1:?invitation link}"
[[ "$LINK" == spectre://enroll* ]] || { echo "lien inattendu"; exit 1; }
command -v qrencode >/dev/null || { echo "brew install qrencode"; exit 2; }
if [ -n "${2:-}" ]; then qrencode -o "$2" -s 8 "$LINK"; echo "QR écrit dans $2 (supprimez-le après usage)"; else qrencode -t ANSIUTF8 "$LINK"; fi
