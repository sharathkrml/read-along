#!/bin/bash
# Build the Read Along DMG from a fresh app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="ReadAlong"
VOLNAME="Read Along"
VERSION="${VERSION:-1.0.0}"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$BUILD/$NAME.app"
DMG="${OUTPUT:-$DIST/$NAME-$VERSION.dmg}"

# Keep the build in a log file: a live subprocess holding the terminal pipe
# makes the following hdiutil create fail with "Resource busy".
mkdir -p "$BUILD"
BUILD_LOG="$BUILD/build.log"
if ! VERSION="$VERSION" "$ROOT/scripts/build_app.sh" >"$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG" >&2
  exit 1
fi
tail -1 "$BUILD_LOG"

echo "==> DMG"
rm -rf "$BUILD/dmg"
mkdir -p "$BUILD/dmg" "$(dirname "$DMG")"
# Move the app into the staging folder instead of duplicating 1+ GB.
mv "$APP" "$BUILD/dmg/"
ln -s /Applications "$BUILD/dmg/Applications"
sync
# Build to /tmp, not `dist` or `$TMPDIR`: a synced Documents folder can return
# "Resource busy" for a large hdiutil output, and the per-user TMPDIR failed
# verification for the 750 MB app. The final `mv` is a rename.
TMP_DMG="/tmp/$NAME-$VERSION.$$.tmp.dmg"
trap 'rm -f "$TMP_DMG"; mv "$BUILD/dmg/$NAME.app" "$APP" 2>/dev/null || true; rm -rf "$BUILD/dmg"' EXIT
rm -f "$TMP_DMG"
DMG_LOG="$BUILD/dmg.log"
for attempt in 1 2 3; do
  if hdiutil create -volname "$VOLNAME" -srcfolder "$BUILD/dmg" -ov -format UDZO "$TMP_DMG" >"$DMG_LOG" 2>&1; then break; fi
  if [ "$attempt" = 3 ]; then cat "$DMG_LOG" >&2; echo "DMG creation failed: $TMP_DMG" >&2; exit 1; fi
  sleep 2
done
for attempt in 1 2 3; do
  if hdiutil verify "$TMP_DMG" >/dev/null 2>&1; then break; fi
  if [ "$attempt" = 3 ]; then echo "DMG verification failed: $TMP_DMG" >&2; exit 1; fi
  sleep 1
done
mv -f "$TMP_DMG" "$DMG"

# Optional: sign with a Developer ID and notarize so Gatekeeper opens it cleanly.
#   CODESIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=readalong ./scripts/build_dmg.sh
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
