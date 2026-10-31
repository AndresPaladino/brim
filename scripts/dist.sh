#!/bin/zsh
# Builds a universal Brim.app (Apple silicon and Intel) and packs it in dist/Brim.dmg.
# The release asset keeps that name so releases/latest/download/Brim.dmg always works.
# Usage: scripts/dist.sh
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
SCRATCH="$HOME/Library/Caches/brim-build"
APP="$SCRATCH/app.noindex/Brim.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Intel slice first, then the regular build (Apple silicon), then merge them.
swift build -c release --triple x86_64-apple-macosx15.0 --scratch-path "$SCRATCH"
cp "$SCRATCH/release/Brim" "$TMP/Brim-x86_64"
./scripts/build.sh
lipo -create "$APP/Contents/MacOS/Brim" "$TMP/Brim-x86_64" -output "$TMP/Brim"
cp "$TMP/Brim" "$APP/Contents/MacOS/Brim"

IDENTITY="Notch Island Dev"
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 && SIGN="$IDENTITY" || SIGN="-"
codesign --force --sign "$SIGN" "$APP/Contents/Resources/NowPlayingBridge.dylib"
codesign --force --sign "$SIGN" "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/Brim")"

# Writable image first so Finder can lay out the window, then compress it.
# scripts/dmg/background.tiff is rendered from scripts/dmg/background.html at 1x and 2x.
STAGE="$TMP/stage"
VOL="Brim $VERSION"
mkdir -p "$STAGE/.background" dist
ditto "$APP" "$STAGE/Brim.app"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg/background.tiff "$STAGE/.background/bg.tiff"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$TMP/rw.dmg" >/dev/null
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP/rw.dmg" | awk '/Apple_HFS/{print $1}')
sleep 1
# The first run asks for permission to let the terminal control Finder.
osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:bg.tiff"
    set position of item "Brim.app" of container window to {160, 170}
    set position of item "Applications" of container window to {440, 170}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach "$DEV" >/dev/null
DMG="dist/Brim.dmg"
rm -f "$DMG"
hdiutil convert "$TMP/rw.dmg" -format UDZO -o "$DMG" >/dev/null
echo "Built $DMG"
