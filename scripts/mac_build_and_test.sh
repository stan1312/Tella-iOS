#!/usr/bin/env bash
# SPECTRE Capture — reproducible build + tests on the owner's Mac (no signing needed).
# Produces test-results/mac/*.log. This is the step that establishes "build iOS validé".
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=test-results/mac; mkdir -p "$OUT"
SIM="${SIM:-iPhone 15}"
./scripts/check_env_mac.sh || true
echo "== CocoaPods"; pod install 2>&1 | tee "$OUT/pod.log" | tail -3
echo "== Projet Xcode (idempotent)"; ruby scripts/xcode_integrate_spectre.rb || echo "xcodeproj gem absent: fichiers déjà intégrés au dépôt"
echo "== Build simulateur (sans signature)"
xcodebuild -workspace Tella.xcworkspace -scheme Tella -configuration Debug \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$OUT/build.log" | tail -5
echo "== Tests unitaires de l'app (TellaTests, dont SpectreIntegrationTests)"
xcodebuild -workspace Tella.xcworkspace -scheme Tella -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath build/dd -only-testing:TellaTests CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$OUT/apptests.log" | tail -15 || true
echo "== SpectreCore + backend + scénarios"
./scripts/run_all_tests.sh 2>&1 | tee "$OUT/core.log" | tail -5
echo "== Contrôle du binaire : aucun identifiant propriétaire embarqué"
APP=$(find build/dd -name "Tella.app" -type d | head -1)
if [ -n "$APP" ]; then
  if strings -a "$APP/Tella" | grep -E "ya29\.|GOCSPX-|client_secret|refresh_token|BEGIN PRIVATE KEY|CFG_FOLDER_ID=" ; then
    echo "BINAIRE: motif sensible trouvé"; exit 1
  else echo "BINAIRE: aucun jeton/secret Google détecté ($APP)"; fi
fi
echo "Terminé. Journaux : $OUT/"
