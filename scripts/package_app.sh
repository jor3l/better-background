#!/usr/bin/env bash
# Builds BetterBackground.app (ad-hoc signed) and BetterBackground.dmg into ./build.
# Expects the compiled model at build/model/DepthAnythingV2SmallF16.mlmodelc.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/BetterBackground.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BetterBackground" "$APP/Contents/MacOS/BetterBackground"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"

MODEL="build/model/DepthAnythingV2SmallF16.mlmodelc"
if [ -d "$MODEL" ]; then
  cp -R "$MODEL" "$APP/Contents/Resources/"
else
  echo "warning: $MODEL not found, app will run without depth" >&2
fi

codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

DMG_ROOT="build/dmg"
rm -rf "$DMG_ROOT" build/BetterBackground.dmg
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname BetterBackground -srcfolder "$DMG_ROOT" -ov -format UDZO build/BetterBackground.dmg
echo "Built build/BetterBackground.dmg"
