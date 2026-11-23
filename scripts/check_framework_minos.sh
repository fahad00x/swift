#!/bin/bash
# Usage: check_framework_minos.sh path/to/App.app
# For every embedded framework: binary's real minimum OS (LC_BUILD_VERSION minos) vs its
# Info.plist MinimumOSVersion vs the app's. App Store Connect rejects (ITMS-90208) a framework
# whose Info.plist MinimumOSVersion differs from what its binary was built for, and one that
# needs a newer OS than the app.
APP="$1"
APP_MIN=$(plutil -extract MinimumOSVersion raw "$APP/Info.plist")
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
binary_minos() {
  local m
  m=$(xcrun vtool -show-build "$1" 2>/dev/null | awk '/minos/{print $2}' | sort -V | tail -1)
  [ -n "$m" ] || m=$(otool -l "$1" 2>/dev/null | awk '/minos/{print $2}' | sort -V | tail -1)
  [ -n "$m" ] || m=$(otool -l "$1" 2>/dev/null | awk '/LC_VERSION_MIN/{f=1} f&&/version/{print $2; f=0}' | sort -V | tail -1)
  echo "${m:-unknown}"
}
echo "App: $(basename "$APP")  MinimumOSVersion=$APP_MIN"
printf '%-28s %-10s %-10s %s\n' FRAMEWORK BINARY PLIST STATUS
bad=0; highest="$APP_MIN"
for fw in "$APP"/Frameworks/*.framework; do
  [ -d "$fw" ] || continue
  name=$(basename "$fw" .framework)
  bin_min=$(binary_minos "$fw/$name")
  plist_min=$(plutil -extract MinimumOSVersion raw "$fw/Info.plist" 2>/dev/null || echo missing)
  status=ok
  if [ "$plist_min" != "$bin_min" ]; then status="PLIST≠BINARY"; bad=1; fi
  if [ "$bin_min" != unknown ] && ver_gt "$bin_min" "$APP_MIN"; then status="$status NEWER-THAN-APP"; bad=1; fi
  [ "$bin_min" != unknown ] && ver_gt "$bin_min" "$highest" && highest="$bin_min"
  printf '%-28s %-10s %-10s %s\n' "$name" "$bin_min" "$plist_min" "$status"
done
echo "Highest framework minos: $highest"
if [ "$bad" != 0 ]; then
  # Diagnostics for the first framework, to see what the binary actually contains.
  fw=$(ls -d "$APP"/Frameworks/*.framework | head -1); name=$(basename "$fw" .framework)
  echo "--- diagnostics: $name"
  ls -la "$fw"
  file "$fw/$name"
  xcrun vtool -show-build "$fw/$name" 2>&1 | head -20
  otool -l "$fw/$name" 2>&1 | grep -A6 -E "LC_BUILD_VERSION|LC_VERSION_MIN" | head -20
  codesign -dv "$fw" 2>&1 | head -5
fi
if [ "$bad" != 0 ]; then echo "::error::Embedded framework minimum OS mismatch in $(basename "$APP") (see table)"; exit 1; fi
