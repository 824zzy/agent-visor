#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_PATH="$PROJECT_DIR/AgentVisorCore"
OUTPUT_DIR="${AV_NATIVE_HELPER_OUTPUT_DIR:-$PROJECT_DIR/build/native-helper}"
IDENTITY="${AV_NATIVE_HELPER_SIGN_IDENTITY-}"
TEAM_IDENTIFIER="${AV_NATIVE_HELPER_TEAM_ID-}"
KEYCHAIN="${AV_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
VERSION="${AV_VERSION:-}"
BUILD="${AV_BUILD:-}"

source "$PROJECT_DIR/scripts/lib/release-version.sh"
release_load_version_config "$PROJECT_DIR"

if [[ -z "$IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    SIGNING_TIMESTAMP=(--timestamp=none)
else
    if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
        | grep -Fq "\"$IDENTITY\""; then
        echo "ERROR: native helper signing identity is unavailable: $IDENTITY" >&2
        exit 1
    fi
    SIGNING_IDENTITY="$IDENTITY"
    SIGNING_TIMESTAMP=(--timestamp)
fi

swift build --package-path "$PACKAGE_PATH" -c release --product AgentVisorNativeHelper
BIN_DIR="$(swift build --package-path "$PACKAGE_PATH" -c release --show-bin-path)"
HELPER_APP="$OUTPUT_DIR/Agent Visor Native Helper.app"
HELPER_EXECUTABLE="$HELPER_APP/Contents/MacOS/AgentVisorNativeHelper"
rm -rf "$HELPER_APP"
mkdir -p "$OUTPUT_DIR" "$(dirname "$HELPER_EXECUTABLE")"
cp "$BIN_DIR/AgentVisorNativeHelper" "$OUTPUT_DIR/AgentVisorNativeHelper"
codesign --force --options runtime "${SIGNING_TIMESTAMP[@]}" \
    --sign "$SIGNING_IDENTITY" "$OUTPUT_DIR/AgentVisorNativeHelper"
codesign --verify --strict "$OUTPUT_DIR/AgentVisorNativeHelper"
cp "$OUTPUT_DIR/AgentVisorNativeHelper" "$HELPER_EXECUTABLE"
{
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0"><dict>'
    printf '%s\n' '<key>CFBundleDisplayName</key><string>Agent Visor</string>'
    printf '%s\n' '<key>CFBundleExecutable</key><string>AgentVisorNativeHelper</string>'
    printf '%s\n' '<key>CFBundleIdentifier</key><string>AgentVisorNativeHelper</string>'
    printf '%s\n' '<key>CFBundleName</key><string>Agent Visor</string>'
    printf '%s\n' '<key>CFBundlePackageType</key><string>APPL</string>'
    printf '<key>LSMinimumSystemVersion</key><string>%s</string>\n' "$AGENT_VISOR_MIN_MACOS"
    if [[ -n "$VERSION" ]]; then
        printf '<key>CFBundleShortVersionString</key><string>%s</string>\n' "$VERSION"
    fi
    if [[ -n "$BUILD" ]]; then
        printf '<key>CFBundleVersion</key><string>%s</string>\n' "$BUILD"
    fi
    printf '%s\n' '<key>LSUIElement</key><true/>'
    printf '%s\n' '<key>NSUserNotificationAlertStyle</key><string>alert</string>'
    printf '<key>NSAppleEventsUsageDescription</key><string>%s</string>\n' "$AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION"
    printf '%s\n' '</dict></plist>'
} > "$HELPER_APP/Contents/Info.plist"
codesign --force --options runtime "${SIGNING_TIMESTAMP[@]}" \
    --sign "$SIGNING_IDENTITY" "$HELPER_APP"
codesign --verify --deep --strict "$HELPER_APP"
HELPER_SIGNING_INFO="$(codesign -dvvv "$HELPER_APP" 2>&1)"
if [[ -n "$IDENTITY" ]] \
    && ! grep -Fqx "Authority=$IDENTITY" <<<"$HELPER_SIGNING_INFO"; then
    echo "ERROR: native helper was not signed by the requested identity: $IDENTITY" >&2
    exit 1
fi
if [[ -n "$TEAM_IDENTIFIER" ]] \
    && ! grep -Fqx "TeamIdentifier=$TEAM_IDENTIFIER" <<<"$HELPER_SIGNING_INFO"; then
    echo "ERROR: native helper does not carry the requested TeamIdentifier: $TEAM_IDENTIFIER" >&2
    exit 1
fi

echo "Signed native helper: $HELPER_APP"
