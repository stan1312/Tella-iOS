#!/usr/bin/env bash
# SPECTRE Capture — fails if anything resembling a real credential is tracked.
# Uses gitleaks when installed (brew install gitleaks); always runs the pattern scan.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
patterns='ya29\.[0-9A-Za-z_-]{20,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN (RSA |EC )?PRIVATE KEY-----|"client_secret"\s*:|"refresh_token"\s*:\s*"1//|GOCSPX-[0-9A-Za-z_-]{20,}|xox[baprs]-[0-9A-Za-z-]{10,}'
if git grep -nE "$patterns" -- . ':!scripts/secret_scan.sh' ':!*.xcassets' ':!backend/apps-script/test/*' ; then
  echo "SECRET SCAN: suspicious literal found"; fail=1
else
  echo "SECRET SCAN (patterns): clean"
fi
# Tracked files that must never exist
for f in .env backend/apps-script/.clasprc.json backend/apps-script/.clasp.json GoogleService-Info.plist; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 && { echo "tracked forbidden file: $f"; fail=1; }
done
if command -v detect-secrets >/dev/null; then
  # SPECTRE-owned paths only; the single known false positive is the grep pattern in mac_build_and_test.sh
  found=$(detect-secrets scan --all-files SpectreCore/Sources backend/apps-script/src backend/mock-stack Tella/Spectre scripts env.example docs 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin)['results']; d.pop('scripts/mac_build_and_test.sh', None); print(sum(len(v) for v in d.values()))")
  [ "$found" = "0" ] && echo "SECRET SCAN (detect-secrets): clean" || { echo "detect-secrets: $found finding(s)"; fail=1; }
fi
if command -v gitleaks >/dev/null; then gitleaks detect --no-banner --redact -s . || fail=1; else echo "gitleaks not installed (optional)"; fi
exit $fail
