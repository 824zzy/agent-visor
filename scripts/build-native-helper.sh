#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_PATH="$PROJECT_DIR/AgentVisorCore"
OUTPUT_DIR="${AV_NATIVE_HELPER_OUTPUT_DIR:-$PROJECT_DIR/build/native-helper}"
IDENTITY="${AV_NATIVE_HELPER_SIGN_IDENTITY:-AgentVisor Dev}"
KEYCHAIN="${AV_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | grep -Fq "\"$IDENTITY\""; then
    echo "ERROR: native helper signing identity is unavailable: $IDENTITY" >&2
    exit 1
fi

swift build --package-path "$PACKAGE_PATH" -c release --product AgentVisorNativeHelper
BIN_DIR="$(swift build --package-path "$PACKAGE_PATH" -c release --show-bin-path)"
HELPER_APP="$OUTPUT_DIR/Agent Visor Native Helper.app"
HELPER_EXECUTABLE="$HELPER_APP/Contents/MacOS/AgentVisorNativeHelper"
rm -rf "$HELPER_APP"
mkdir -p "$OUTPUT_DIR" "$(dirname "$HELPER_EXECUTABLE")"
cp "$BIN_DIR/AgentVisorNativeHelper" "$OUTPUT_DIR/AgentVisorNativeHelper"
codesign --force --sign "$IDENTITY" "$OUTPUT_DIR/AgentVisorNativeHelper"
codesign --verify --strict "$OUTPUT_DIR/AgentVisorNativeHelper"
cp "$OUTPUT_DIR/AgentVisorNativeHelper" "$HELPER_EXECUTABLE"
cat > "$HELPER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Agent Visor</string>
<key>CFBundleExecutable</key><string>AgentVisorNativeHelper</string>
<key>CFBundleIdentifier</key><string>AgentVisorNativeHelper</string>
<key>CFBundleName</key><string>Agent Visor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSUserNotificationAlertStyle</key><string>alert</string>
</dict></plist>
PLIST
codesign --force --options runtime --sign "$IDENTITY" "$HELPER_APP"
codesign --verify --deep --strict "$HELPER_APP"

echo "Signed native helper: $HELPER_APP"
