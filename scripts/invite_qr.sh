#!/usr/bin/env bash
# SPECTRE Capture — turns an invitation link into a QR code, entirely offline.
# Show it in person; it works once and expires.
# Usage:
#   ./scripts/invite_qr.sh 'spectre://enroll?v=1&endpoint=...&code=...' [out.png]
#   ./scripts/invite_qr.sh --drive [out.png]
#       reads SPECTRE_INVITATION_A_SUPPRIMER*.txt from the Google Drive for desktop
#       folder (written by spectreNouvelleInvitation), makes the QR, then moves the
#       text file to the trash. The link is never printed.
set -euo pipefail
command -v qrencode >/dev/null || { echo "brew install qrencode"; exit 2; }
if [ "${1:-}" = "--drive" ]; then
  OUT="${2:-$HOME/Desktop/SPECTRE_invitation_QR.png}"
  # The invitation file sits in the deposit folder (top level of My Drive): search shallowly,
  # never the whole Drive (a deep find on a streamed Drive can take minutes).
  echo "Recherche du fichier d'invitation dans Google Drive…"
  FILE="$(find "$HOME/Library/CloudStorage" -maxdepth 4 -name 'SPECTRE_INVITATION_A_SUPPRIMER*.txt' 2>/dev/null | head -1)"
  [ -n "$FILE" ] || { echo "Introuvable. Autre méthode : copiez le contenu du fichier dans Drive (Cmd+A, Cmd+C) puis"; echo "  ./scripts/invite_qr.sh \"\$(pbpaste)\" \"$OUT\""; exit 1; }
  LINK="$(head -1 "$FILE")"
  [[ "$LINK" == spectre://enroll* ]] || { echo "contenu inattendu"; exit 1; }
  printf '%s' "$LINK" | qrencode -o "$OUT" -s 8
  mv "$FILE" "$HOME/.Trash/" 2>/dev/null || rm -f "$FILE"
  echo "QR écrit dans $OUT ; fichier d'invitation retiré du Drive. Supprimez le QR après usage."
  exit 0
fi
LINK="${1:?invitation link or --drive}"
[[ "$LINK" == spectre://enroll* ]] || { echo "lien inattendu"; exit 1; }
if [ -n "${2:-}" ]; then qrencode -o "$2" -s 8 "$LINK"; echo "QR écrit dans $2 (supprimez-le après usage)"; else qrencode -t ANSIUTF8 "$LINK"; fi
