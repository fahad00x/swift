#!/usr/bin/env bash
# Ad-hoc signs an unsigned .app with its entitlements (e.g. iCloud) so the App Store export,
# which re-signs it with a cloud-managed certificate, keeps them. Nested code first (codesign
# refuses an app whose frameworks aren't signed), the app last. No certificate or profile.
# Usage: adhoc_sign_with_entitlements.sh <App.app> <app.entitlements>
set -euo pipefail
APP="$1"
ENTITLEMENTS="$2"

if [ -d "$APP/Frameworks" ]; then
  find "$APP/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) -print0 |
    while IFS= read -r -d '' item; do
      codesign --force --sign - --timestamp=none "$item"
    done
fi
if [ -d "$APP/PlugIns" ]; then
  find "$APP/PlugIns" -maxdepth 1 -name "*.appex" -print0 |
    while IFS= read -r -d '' item; do
      codesign --force --sign - --timestamp=none "$item"
    done
fi
codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "icloud-container-identifiers"
