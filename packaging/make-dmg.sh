#!/bin/bash
# Builds a styled, signed BaseChat DMG. Notarization runs only when
# NOTARY_ISSUER is set (see README).
set -euo pipefail

VERSION="${VERSION:-0.2}"
APP="dist/BaseChat.app"
VOL="BaseChat $VERSION"
DMG="BaseChat-$VERSION.dmg"
IDENTITY="Developer ID Application: Martin Enzinger (JX6ZG43F7U)"
NOTARY_KEY="${NOTARY_KEY:-$HOME/Dev/macos-dev-key/AuthKey_B8Q66JTB96.p8}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-B8Q66JTB96}"

cd "$(dirname "$0")/.."
[ -d "$APP" ] || { echo "error: $APP not found — build Release first"; exit 1; }

STAGE=$(mktemp -d)
RW=$(mktemp -u).dmg
trap 'rm -rf "$STAGE" "$RW"' EXIT

echo "==> staging"
hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp packaging/dmg-background.tiff "$STAGE/.background/bg.tiff"

echo "==> creating writable image"
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
hdiutil attach "$RW" -nobrowse -noverify >/dev/null
MOUNT="/Volumes/$VOL"

echo "==> arranging window"
# Finder can snap icons on the first pass, so set, settle, then confirm.
for attempt in 1 2 3; do
  osascript >/dev/null <<AS
tell application "Finder"
  tell disk "$VOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {180, 120, 820, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 118
    set text size of opts to 12
    set background picture of opts to file ".background:bg.tiff"
    set position of item "BaseChat.app" of container window to {170, 185}
    set position of item "Applications" of container window to {470, 185}
    update without registering applications
    delay 1
    close
  end tell
end tell
AS
  POS=$(osascript -e "tell application \"Finder\" to tell disk \"$VOL\"
    open
    delay 1
    set p to position of item \"BaseChat.app\" of container window
    close
    return (item 2 of p) as text
  end tell")
  [ "$POS" = "185" ] && { echo "    icons placed (y=$POS)"; break; }
  echo "    Finder snapped to y=$POS, retrying ($attempt)"
done

sync
hdiutil detach "$MOUNT" >/dev/null

echo "==> compressing"
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

echo "==> signing"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"

if [ -n "${NOTARY_ISSUER:-}" ]; then
  echo "==> notarizing (this can take a few minutes)"
  xcrun notarytool submit "$DMG" \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG" || true
else
  echo "==> skipping notarization (set NOTARY_ISSUER to enable)"
fi

echo "==> done: $DMG ($(du -h "$DMG" | cut -f1))"
