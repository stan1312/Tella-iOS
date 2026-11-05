#!/usr/bin/env bash
# SPECTRE Capture — checks the owner's Mac before building. Read-only.
set -u
ok() { printf "  [OK]  %s\n" "$1"; }
ko() { printf "  [À FAIRE] %s\n" "$1"; missing=1; }
missing=0
echo "SPECTRE Capture — vérification de l'environnement"
[ "$(uname)" = "Darwin" ] && ok "macOS $(sw_vers -productVersion)" || ko "Ce script doit tourner sur macOS"
if xcodebuild -version >/dev/null 2>&1; then
  v=$(xcodebuild -version | head -1); ok "$v"
  major=$(xcodebuild -version | head -1 | awk '{print $2}' | cut -d. -f1)
  [ "${major:-0}" -ge 16 ] || ko "Xcode 16 ou plus récent requis (Tella utilise la syntaxe Swift 6) : App Store > Xcode"
else ko "Xcode absent : installez-le depuis l'App Store puis lancez-le une fois"; fi
xcode-select -p >/dev/null 2>&1 && ok "xcode-select: $(xcode-select -p)" || ko "sudo xcode-select -s /Applications/Xcode.app"
command -v brew >/dev/null && ok "Homebrew" || ko "Homebrew : https://brew.sh"
command -v pod >/dev/null && ok "CocoaPods $(pod --version)" || ko "brew install cocoapods"
command -v node >/dev/null && ok "node $(node --version)" || ko "brew install node (tests backend + mock)"
command -v ffmpeg >/dev/null && ok "ffmpeg" || ko "brew install ffmpeg (vidéos de test synthétiques)"
command -v qrencode >/dev/null && ok "qrencode" || echo "  [option] brew install qrencode (QR d'invitation hors ligne)"
gem list xcodeproj -i >/dev/null 2>&1 && ok "gem xcodeproj" || echo "  [option] gem install xcodeproj --user-install (déjà intégré dans le projet)"
xcrun simctl list devices available 2>/dev/null | grep -q iPhone && ok "Simulateur iPhone disponible" || ko "Xcode > Settings > Platforms : installer un simulateur iOS"
[ $missing -eq 0 ] && echo "Environnement prêt." || echo "Corrigez les points [À FAIRE] puis relancez."
exit $missing
