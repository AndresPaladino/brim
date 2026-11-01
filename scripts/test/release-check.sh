#!/bin/zsh
# Checks the build in dist/ (from scripts/dist.sh) before publishing: architectures, signatures,
# versions against the appcast, DMG layout, and a smoke run under Rosetta.
# Usage: scripts/test/release-check.sh
set -uo pipefail
cd "${0:A:h}/../.."
source scripts/test/lib.sh
DMG=dist/Brim.dmg; ZIP=dist/Brim.zip
ok() { PASS=$((PASS+1)); print "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("release: $1"); print "  ✗ $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi }

scenario "Source"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" Resources/Info.plist)
print "  Info.plist: $VERSION ($BUILD), macOS $MIN_OS+"
APPCAST_BUILD=$(grep -oE "<sparkle:version>[0-9]+" docs/appcast.xml | head -1 | grep -oE "[0-9]+")
APPCAST_SHORT=$(grep -oE "<sparkle:shortVersionString>[^<]+" docs/appcast.xml | head -1 | sed 's/.*>//')
check "appcast's newest entry is this version ($APPCAST_SHORT/$APPCAST_BUILD)" "[[ $APPCAST_SHORT == $VERSION && $APPCAST_BUILD == $BUILD ]]"
check "minimum macOS matches Package.swift (.v${MIN_OS%%.*})" "grep -q 'macOS(.v${MIN_OS%%.*})' Package.swift"
check "Info.plist has Sparkle's public key" "/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' Resources/Info.plist"
check "Info.plist has a feed URL" "/usr/libexec/PlistBuddy -c 'Print SUFeedURL' Resources/Info.plist"

scenario "DMG"
[[ -f $DMG ]] || { bad "no $DMG (run scripts/dist.sh)"; summary release; exit 1; }
MNT=$(mktemp -d)
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint $MNT $DMG >/dev/null 2>&1 || { bad "DMG doesn't mount"; summary release; exit 1; }
APP=$MNT/Brim.app
check "Brim.app inside" "[[ -d $APP ]]"
check "Applications link" "[[ -L $MNT/Applications ]]"
check "background image" "[[ -f $MNT/.background/bg.tiff ]]"
V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $APP/Contents/Info.plist 2>/dev/null)
check "app version is $VERSION (got $V)" "[[ $V == $VERSION ]]"
archs=$(lipo -archs $APP/Contents/MacOS/Brim 2>/dev/null)
check "universal binary ($archs)" "[[ '$archs' == *x86_64* && '$archs' == *arm64* ]]"
darchs=$(lipo -archs $APP/Contents/Resources/NowPlayingBridge.dylib 2>/dev/null)
check "universal bridge ($darchs)" "[[ '$darchs' == *x86_64* && '$darchs' == *arm64* ]]"
check "signature valid" "codesign --verify --deep --strict $APP"
# Sparkle from SwiftPM comes signed ad hoc (see build.sh): the signature only has to be intact.
check "Sparkle's signature valid" "codesign --verify --deep --strict $APP/Contents/Frameworks/Sparkle.framework"
for f in claude-hook.sh codex-hook.sh NowPlayingBridge.pl en.lproj/Localizable.strings es.lproj/Localizable.strings AppIcon.icns Assets.car; do
  check "resource $f" "[[ -f $APP/Contents/Resources/$f ]]"
done
check "hook scripts executable by sh" "sh -n $APP/Contents/Resources/claude-hook.sh && sh -n $APP/Contents/Resources/codex-hook.sh"
check "no debug tools left on by default" "! /usr/libexec/PlistBuddy -c 'Print debugTools' $APP/Contents/Info.plist"
size=$(du -sm $APP | cut -f1); print "  app size: ${size} MB"
echo "release.app_size_mb	$size" >> $REPORT/metrics.tsv

scenario "Intel (Rosetta)"
if arch -x86_64 /usr/bin/true 2>/dev/null; then
  out=$(mktemp -d)/charge.png
  arch -x86_64 $APP/Contents/MacOS/Brim --render-charge $out full --plain >/dev/null 2>&1
  check "x86_64 slice runs and renders" "[[ -s $out ]]"
  arch -x86_64 /usr/bin/perl -e 1 2>/dev/null && check "bridge dylib loads in x86_64 perl" \
    "printf '' | arch -x86_64 /usr/bin/perl $APP/Contents/Resources/NowPlayingBridge.pl $APP/Contents/Resources/NowPlayingBridge.dylib"
else
  print "  Rosetta not installed: skipped (softwareupdate --install-rosetta)"
fi
hdiutil detach $MNT >/dev/null 2>&1

scenario "Update archive"
if [[ -f $ZIP ]]; then
  len=$(stat -f %z $ZIP)
  alen=$(grep -oE 'length="[0-9]+"' docs/appcast.xml | head -1 | grep -oE "[0-9]+")
  check "zip size matches the appcast ($len vs $alen)" "[[ $len == $alen ]]"
  Z=$(mktemp -d); ditto -x -k $ZIP $Z
  check "zip contains a valid signed app" "codesign --verify --deep --strict $Z/Brim.app"
else
  print "  no $ZIP"
fi
summary "release"
