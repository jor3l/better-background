#!/usr/bin/env bash
# Builds BetterBackground.app (ad-hoc signed) and BetterBackground.dmg into ./build.
# Expects the compiled model at build/model/DepthAnythingV2SmallF16.mlmodelc.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
# Sparkle compares CFBundleVersion, so it follows the release version by default.
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/BetterBackground.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/BetterBackground" "$APP/Contents/MacOS/BetterBackground"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"

MODEL="build/model/DepthAnythingV2SmallF16.mlmodelc"
if [ -d "$MODEL" ]; then
  cp -R "$MODEL" "$APP/Contents/Resources/"
else
  echo "warning: $MODEL not found, app will run without depth" >&2
fi

# Sparkle (over-the-air updates). The app is not sandboxed, so the XPC services are not needed.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_SRC="$BIN_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
  SPARKLE_SRC="$(find .build/artifacts -path '*macos*/Sparkle.framework' -maxdepth 6 -type d | head -n1)"
fi
[ -d "$SPARKLE_SRC" ] || { echo "error: Sparkle.framework not found" >&2; exit 1; }
ditto "$SPARKLE_SRC" "$SPARKLE"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"

# Ad-hoc sign inside out (no --deep, as Sparkle recommends).
codesign --force --sign - "$SPARKLE/Versions/B/Autoupdate"
codesign --force --sign - "$SPARKLE/Versions/B/Updater.app"
codesign --force --sign - "$SPARKLE"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Fail early if the binary can't find Sparkle at launch.
otool -l "$APP/Contents/MacOS/BetterBackground" | grep -q '@executable_path/../Frameworks' \
  || { echo "error: missing @executable_path/../Frameworks rpath" >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"

DMG_ROOT="build/dmg"
rm -rf "$DMG_ROOT" build/BetterBackground.dmg
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname BetterBackground -srcfolder "$DMG_ROOT" -ov -format UDZO build/BetterBackground.dmg
echo "Built build/BetterBackground.dmg"
