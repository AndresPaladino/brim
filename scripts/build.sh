#!/bin/zsh
# Builds Brim.app into ~/Library/Caches/brim-build and signs it.
# Build output stays out of the project folder: if it lives in iCloud Drive, the extended attributes
# iCloud adds make codesign fail.
# Usage: scripts/build.sh [--run | --install]
set -euo pipefail
cd "${0:A:h}/.."

# Local certificate from scripts/make-cert.sh. Signing every build with the same identity keeps the
# Accessibility permission across rebuilds. Without it, the app is signed ad hoc.
IDENTITY="Notch Island Dev"
SCRATCH="$HOME/Library/Caches/brim-build"
# .noindex keeps this copy out of Spotlight and Launchpad.
APP="$SCRATCH/app.noindex/Brim.app"

swift build -c release --scratch-path "$SCRATCH"

pkill -x Brim 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/Brim" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"

# Now Playing bridge: a dylib loaded into /usr/bin/perl (see Helper/NowPlayingBridge.m).
clang -dynamiclib -fobjc-arc -O2 -Wall -arch arm64 -arch x86_64 -framework Foundation \
  Helper/NowPlayingBridge.m -o "$APP/Contents/Resources/NowPlayingBridge.dylib"
cp Helper/NowPlayingBridge.pl "$APP/Contents/Resources/"
cp Resources/claude-hook.sh Resources/codex-hook.sh "$APP/Contents/Resources/"

xattr -cr "$APP"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  SIGN="$IDENTITY"
else
  echo "No \"$IDENTITY\" certificate (see scripts/make-cert.sh). Signing ad hoc."
  SIGN="-"
fi
codesign --force --sign "$SIGN" "$APP/Contents/Resources/NowPlayingBridge.dylib"
codesign --force --sign "$SIGN" "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Brim.app"
  ditto "$APP" "/Applications/Brim.app"
  open "/Applications/Brim.app"
  echo "Installed in /Applications"
elif [[ "${1:-}" == "--run" ]]; then
  open "$APP"
fi
