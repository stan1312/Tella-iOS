#!/usr/bin/env bash
# SPECTRE Capture — sets YOUR bundle identifier and Apple team on the app target.
# Usage: ./scripts/configure_signing.sh ch.<votre-nom>.spectrecapture ABCDE12345
# (Team ID : developer.apple.com > Account > Membership details). Nothing is sent anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."
BID="${1:?bundle id}"; TEAM="${2:?team id}"
[[ "$BID" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "bundle id invalide"; exit 1; }
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "team id invalide (10 caractères)"; exit 1; }
PBX=Tella.xcodeproj/project.pbxproj
cp "$PBX" "$PBX.bak"
# App target only (Tella's id is org.wearehorizontal.tella); every team id in the project
# (including the sdk=iphoneos* conditional one) is replaced by yours. perl -i is portable macOS/Linux.
BID="$BID" perl -pi -e 's/PRODUCT_BUNDLE_IDENTIFIER = org\.wearehorizontal\.tella;/PRODUCT_BUNDLE_IDENTIFIER = $ENV{BID};/g' "$PBX"
TEAM="$TEAM" perl -pi -e 's/((?:"DEVELOPMENT_TEAM\[sdk=iphoneos\*\]"|DEVELOPMENT_TEAM) = )(?:"[^"]*"|[A-Z0-9]*);/$1$ENV{TEAM};/g' "$PBX"
grep -n "PRODUCT_BUNDLE_IDENTIFIER = $BID" "$PBX" | head -3
echo "OK. Dans Xcode : cible Tella > Signing & Capabilities > Team = votre équipe (si non sélectionnée)."
