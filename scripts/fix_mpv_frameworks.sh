#!/bin/bash
# Makes the MPVKit frameworks embedded in the app acceptable to App Store Connect.
# Runs as a build phase after the frameworks are embedded and before the app is signed;
# used by both the tvOS and the iOS targets.
#
# MPVKit 1.0.0 ships every framework binary with an invalid LC_BUILD_VERSION "minos 100.0".
# App Store Connect rejects both a framework whose Info.plist MinimumOSVersion differs from its
# binary's minos (ITMS-90208) and one that requires a newer OS than the app. So for each
# framework: if the binary's minos is above the app's deployment target (i.e. the bogus 100.0),
# rewrite it in place to the deployment target (scripts/patch_minos.py); then set Info.plist MinimumOSVersion to the
# binary's minos. A real minos at or below the target is never lowered. Also drops any
# static-archive copies, and re-signs what it changed.
set -u
FW_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
[ -d "$FW_DIR" ] || exit 0

case "$PLATFORM_NAME" in
  appletvos|appletvsimulator) MIN_OS="$TVOS_DEPLOYMENT_TARGET" ;;
  iphoneos|iphonesimulator) MIN_OS="$IPHONEOS_DEPLOYMENT_TARGET" ;;
  *) echo "Unsupported platform $PLATFORM_NAME"; exit 0 ;;
esac

ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }
build_field() { otool -l "$1" 2>/dev/null | awk -v k="$2" '$1==k{print $2}' | sort -V | tail -1; }

for fw in "$FW_DIR"/*.framework; do
  [ -d "$fw" ] || continue
  name=$(basename "$fw" .framework)
  bin="$fw/$name"
  if [ ! -f "$bin" ] || file -b "$bin" | grep -q "ar archive"; then
    echo "Removing static framework copy: $name.framework"
    rm -rf "$fw"
    continue
  fi
  changed=0

  # Rewrite the bogus minos (100.0) in place; a real minos at or below the target is kept.
  before=$(build_field "$bin" minos)
  minos=$(python3 "${SRCROOT}/scripts/patch_minos.py" "$bin" "$MIN_OS") \
    || { echo "error: could not patch the build version of $name"; exit 1; }
  if [ "$before" != "$minos" ]; then
    echo "$name: binary minos $before → $minos"
    changed=1
  fi
  [ -n "$minos" ] || minos="$MIN_OS"

  plist="$fw/Info.plist"
  current=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$plist" 2>/dev/null || echo "")
  if [ "$current" != "$minos" ]; then
    /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $minos" "$plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $minos" "$plist"
    changed=1
  fi

  if [ "$changed" = 1 ]; then
    if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ]; then
      codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,entitlements,flags --timestamp=none "$fw"
    else
      # Unsigned build: drop the now-invalid signature; export / sideloading signs it again.
      codesign --remove-signature "$fw" 2>/dev/null || true
    fi
  fi
done
rmdir "$FW_DIR" 2>/dev/null || true
exit 0
