#!/usr/bin/env bash
# SPECTRE Capture — reproducible build + tests on the owner's Mac (no signing needed).
# Produces test-results/mac/*.log. This is the step that establishes "build iOS validé".
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=test-results/mac; mkdir -p "$OUT"
# Simulator: $SIM if given, otherwise the first available iPhone.
SIM="${SIM:-$(xcrun simctl list devices available | grep -oE "iPhone [0-9A-Za-z ]+[0-9A-Za-z]" | head -1)}"
echo "Simulateur : $SIM"
./scripts/check_env_mac.sh || true
CFG="Tella/Supporting Files/TellaConfig.xcconfig"
[ -f "$CFG" ] || { cp "$CFG.example" "$CFG"; echo "TellaConfig.xcconfig créé depuis l'exemple (connecteurs Tella désactivés)"; }
echo "== CocoaPods"; pod install 2>&1 | tee "$OUT/pod.log" | tail -3
echo "== Projet Xcode (idempotent)"; ruby scripts/xcode_integrate_spectre.rb || echo "xcodeproj gem absent: fichiers déjà intégrés au dépôt"
echo "== Build simulateur (sans signature)"
xcodebuild -workspace Tella.xcworkspace -scheme Tella -configuration Debug \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO build > "$OUT/build.log" 2>&1 && BUILD=PASS || BUILD=FAIL
tail -5 "$OUT/build.log"
if [ "$BUILD" = FAIL ]; then
  echo "== Erreurs de compilation (extrait de $OUT/build.log)"
  grep -E "(error|fatal error):" "$OUT/build.log" | sort -u | head -80
  exit 1
fi
echo "== Tests SPECTRE dans l'app (cible SpectreAppTests, simulateur)"
# Tella's own TellaTests target does not compile upstream (stale VaultManagerTests/ModelStubs/MockCryptoManager);
# SPECTRE's app tests therefore live in their own target and scheme.
xcodebuild -workspace Tella.xcworkspace -scheme SpectreAppTests -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO test > "$OUT/apptests.log" 2>&1 && APPTESTS=PASS || APPTESTS=FAIL
grep -E "Test Case .*(passed|failed)|error:|Executed [0-9]+ test" "$OUT/apptests.log" | sort -u | head -40
echo "SpectreAppTests : $APPTESTS (détail : $OUT/apptests.log)"
echo "== SpectreCore + backend + scénarios"
./scripts/run_all_tests.sh 2>&1 | tee "$OUT/core.log" | tail -60
echo "== Contrôle du binaire : aucun identifiant propriétaire embarqué"
APP=$(find build/dd -name "Tella.app" -type d | head -1)
if [ -n "$APP" ]; then
  if strings -a "$APP/Tella" | grep -E "ya29\.|GOCSPX-|client_secret|refresh_token|BEGIN PRIVATE KEY|CFG_FOLDER_ID=" ; then
    echo "BINAIRE: motif sensible trouvé"; exit 1
  else echo "BINAIRE: aucun jeton/secret Google détecté ($APP)"; fi
fi
echo "Terminé. Journaux : $OUT/"
[ "$APPTESTS" = PASS ] || { echo "ATTENTION : des tests de l'app ont échoué ; ne pas considérer le build comme validé."; exit 1; }
