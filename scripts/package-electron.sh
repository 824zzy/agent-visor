#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${AV_VERSION:-2.7.0}"
BUILD="${AV_BUILD:-54}"
IDENTITY="${AV_SIGN_IDENTITY:-AgentVisor Release}"
OUTPUT="${AV_ELECTRON_OUTPUT_DIR:-$ROOT/build/electron}"
APP="$OUTPUT/Agent Visor.app"
SOURCE="$ROOT/node_modules/electron/dist/Electron.app"
ENTITLEMENTS="$ROOT/scripts/electron-entitlements.plist"

security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" \
  | grep -Fq "\"$IDENTITY\"" || { echo "ERROR: signing identity is unavailable: $IDENTITY" >&2; exit 1; }

npm --prefix "$ROOT" run build
AV_NATIVE_HELPER_SIGN_IDENTITY="$IDENTITY" \
  AV_NATIVE_HELPER_OUTPUT_DIR="$OUTPUT/native-helper" \
  "$ROOT/scripts/build-native-helper.sh"

rm -rf "$OUTPUT/Agent Visor.app" "$OUTPUT/AgentVisor-v$VERSION.zip"
mkdir -p "$OUTPUT"
ditto "$SOURCE" "$APP"
plutil -replace CFBundleIdentifier -string com.824zzy.AgentVisor "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "Agent Visor" "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "Agent Visor" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
plutil -replace LSUIElement -bool false "$APP/Contents/Info.plist"

RESOURCES="$APP/Contents/Resources"
ICON_SOURCE="$ROOT/AgentVisor/Assets.xcassets/AppIcon.appiconset"
ICONSET="$OUTPUT/AgentVisor.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp "$ICON_SOURCE/icon_16x16.png" "$ICONSET/icon_16x16.png"
cp "$ICON_SOURCE/icon_32x32 1.png" "$ICONSET/icon_16x16@2x.png"
cp "$ICON_SOURCE/icon_32x32.png" "$ICONSET/icon_32x32.png"
cp "$ICON_SOURCE/icon_64x64.png" "$ICONSET/icon_32x32@2x.png"
cp "$ICON_SOURCE/icon_128x128.png" "$ICONSET/icon_128x128.png"
cp "$ICON_SOURCE/icon_256x256 1.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICON_SOURCE/icon_256x256.png" "$ICONSET/icon_256x256.png"
cp "$ICON_SOURCE/icon_512x512 1.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICON_SOURCE/icon_512x512.png" "$ICONSET/icon_512x512.png"
cp "$ICON_SOURCE/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$RESOURCES/AgentVisor.icns"
rm -rf "$ICONSET"
plutil -replace CFBundleIconFile -string AgentVisor.icns "$APP/Contents/Info.plist"

rm -rf "$RESOURCES/default_app.asar" "$RESOURCES/app"
mkdir -p "$RESOURCES/app/packages/desktop" "$RESOURCES/app/packages/server" \
  "$RESOURCES/app/packages/app" "$RESOURCES/app/node_modules/@agent-visor/protocol" \
  "$RESOURCES/app/node_modules"
cat > "$RESOURCES/app/package.json" <<JSON
{"name":"agent-visor","version":"$VERSION","private":true,"type":"module","main":"packages/desktop/dist/main.js"}
JSON
ditto "$ROOT/packages/desktop/dist" "$RESOURCES/app/packages/desktop/dist"
ditto "$ROOT/packages/server/dist" "$RESOURCES/app/packages/server/dist"
ditto "$ROOT/packages/app/dist" "$RESOURCES/app/packages/app/dist"
ditto "$ROOT/packages/protocol/dist" "$RESOURCES/app/node_modules/@agent-visor/protocol/dist"
cp "$ROOT/packages/protocol/package.json" "$RESOURCES/app/node_modules/@agent-visor/protocol/package.json"
ditto "$ROOT/node_modules/ws" "$RESOURCES/app/node_modules/ws"
ditto "$ROOT/node_modules/zod" "$RESOURCES/app/node_modules/zod"
cp "$OUTPUT/native-helper/AgentVisorNativeHelper" "$RESOURCES/AgentVisorNativeHelper"
mkdir -p "$RESOURCES/AgentIntegrations"
for integration in \
  agent-visor-state.py \
  agent-visor-codex-state.py \
  agent-visor-state-auggie.sh \
  agent-visor-pi.ts.txt; do
  cp "$ROOT/AgentVisor/Resources/$integration" "$RESOURCES/AgentIntegrations/$integration"
done

codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

/usr/bin/ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$OUTPUT/AgentVisor-v$VERSION.zip"
shasum -a 256 "$OUTPUT/AgentVisor-v$VERSION.zip" > "$OUTPUT/AgentVisor-v$VERSION.zip.sha256"
echo "Electron candidate: $OUTPUT/AgentVisor-v$VERSION.zip"
