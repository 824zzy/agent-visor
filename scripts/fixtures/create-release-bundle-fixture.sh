#!/bin/bash
set -euo pipefail

APP_PATH="${1:?fixture app path is required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCHITECTURE="${AV_FIXTURE_ARCH:-arm64}"

source "$PROJECT_DIR/scripts/lib/release-version.sh"
release_load_version_config "$PROJECT_DIR"
VERSION="$(release_product_version "$PROJECT_DIR")"
BUILD="$(release_product_build "$PROJECT_DIR")"

TEMP_ROOT="$(mktemp -d -t av-release-fixture.XXXXXX)"
cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

rm -rf "$APP_PATH"
HELPER_APP="$APP_PATH/Contents/Helpers/Agent Visor Native Helper.app"
mkdir -p "$APP_PATH/Contents/MacOS" \
    "$HELPER_APP/Contents/MacOS" \
    "$HELPER_APP/Contents/Resources" \
    "$APP_PATH/Contents/Resources/app/packages/desktop/dist" \
    "$APP_PATH/Contents/Resources/app/packages/server/dist" \
    "$APP_PATH/Contents/Resources/app/packages/app/dist" \
    "$APP_PATH/Contents/Resources/app/node_modules/@agent-visor/protocol/dist" \
    "$APP_PATH/Contents/Resources/app/node_modules/ws" \
    "$APP_PATH/Contents/Resources/app/node_modules/zod" \
    "$APP_PATH/Contents/Resources/AgentIntegrations" \
    "$APP_PATH/Contents/Resources/ThirdPartyLicenses"

printf 'int main(void) { return 0; }\n' > "$TEMP_ROOT/main.c"
xcrun clang -arch "$ARCHITECTURE" "$TEMP_ROOT/main.c" \
    -o "$APP_PATH/Contents/MacOS/Agent Visor"
xcrun clang -arch "$ARCHITECTURE" "$TEMP_ROOT/main.c" \
    -o "$HELPER_APP/Contents/MacOS/AgentVisorNativeHelper"

INFO="$APP_PATH/Contents/Info.plist"
plutil -create xml1 "$INFO"
plutil -insert CFBundleIdentifier -string "$AGENT_VISOR_BUNDLE_IDENTIFIER" "$INFO"
plutil -insert CFBundleName -string "$AGENT_VISOR_PRODUCT_NAME" "$INFO"
plutil -insert CFBundleDisplayName -string "$AGENT_VISOR_PRODUCT_NAME" "$INFO"
plutil -insert CFBundleExecutable -string "$AGENT_VISOR_EXECUTABLE" "$INFO"
plutil -insert CFBundlePackageType -string APPL "$INFO"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$INFO"
plutil -insert CFBundleVersion -string "$BUILD" "$INFO"
plutil -insert LSMinimumSystemVersion -string "$AGENT_VISOR_MIN_MACOS" "$INFO"
plutil -insert NSAppleEventsUsageDescription -string "$AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION" "$INFO"
plutil -insert LSUIElement -bool false "$INFO"

HELPER_INFO="$HELPER_APP/Contents/Info.plist"
plutil -create xml1 "$HELPER_INFO"
plutil -insert CFBundleIdentifier -string AgentVisorNativeHelper "$HELPER_INFO"
plutil -insert CFBundleName -string "$AGENT_VISOR_PRODUCT_NAME" "$HELPER_INFO"
plutil -insert CFBundleDisplayName -string "$AGENT_VISOR_PRODUCT_NAME" "$HELPER_INFO"
plutil -insert CFBundleExecutable -string AgentVisorNativeHelper "$HELPER_INFO"
plutil -insert CFBundlePackageType -string APPL "$HELPER_INFO"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$HELPER_INFO"
plutil -insert CFBundleVersion -string "$BUILD" "$HELPER_INFO"
plutil -insert LSMinimumSystemVersion -string "$AGENT_VISOR_MIN_MACOS" "$HELPER_INFO"
plutil -insert LSUIElement -bool true "$HELPER_INFO"
plutil -insert NSUserNotificationAlertStyle -string alert "$HELPER_INFO"
plutil -insert NSAppleEventsUsageDescription -string "$AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION" "$HELPER_INFO"
plutil -insert CFBundleIconFile -string AgentVisor.icns "$HELPER_INFO"
printf 'icon\n' > "$APP_PATH/Contents/Resources/AgentVisor.icns"
cp "$APP_PATH/Contents/Resources/AgentVisor.icns" "$HELPER_APP/Contents/Resources/AgentVisor.icns"

printf '%s\n' \
    "{\"name\":\"agent-visor\",\"version\":\"$VERSION\",\"private\":true,\"type\":\"module\",\"main\":\"packages/desktop/dist/main.js\"}" \
    > "$APP_PATH/Contents/Resources/app/package.json"
printf '%s\n' \
    "export {};" > "$APP_PATH/Contents/Resources/app/packages/desktop/dist/main.js"
printf '%s\n' \
    "export {};" > "$APP_PATH/Contents/Resources/app/packages/server/dist/bin.js"
printf '%s\n' \
    "<!doctype html>" > "$APP_PATH/Contents/Resources/app/packages/app/dist/index.html"
printf '%s\n' \
    '{"name":"@agent-visor/protocol","version":"0.1.0"}' \
    > "$APP_PATH/Contents/Resources/app/node_modules/@agent-visor/protocol/package.json"
printf '%s\n' \
    "export {};" > "$APP_PATH/Contents/Resources/app/node_modules/@agent-visor/protocol/dist/index.js"
printf '%s\n' runtime > "$APP_PATH/Contents/Resources/app/node_modules/ws/index.js"
printf '%s\n' runtime > "$APP_PATH/Contents/Resources/app/node_modules/zod/index.js"

for integration in \
    agent-visor-state.py \
    agent-visor-codex-state.py \
    agent-visor-state-auggie.sh \
    agent-visor-pi.ts.txt; do
    printf '# synthetic release fixture\n' \
        > "$APP_PATH/Contents/Resources/AgentIntegrations/$integration"
done
printf 'Electron license\n' > "$APP_PATH/Contents/Resources/ThirdPartyLicenses/Electron.LICENSE"
printf '<html>Chromium license</html>\n' \
    > "$APP_PATH/Contents/Resources/ThirdPartyLicenses/LICENSES.chromium.html"
cp "$PROJECT_DIR/LICENSE.md" \
    "$APP_PATH/Contents/Resources/ThirdPartyLicenses/AgentVisor.LICENSE.md"
printf 'Synthetic fixture notices.\n' \
    > "$APP_PATH/Contents/Resources/ThirdPartyLicenses/README.txt"

ENTITLEMENTS="$TEMP_ROOT/entitlements.plist"
plutil -create xml1 "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool false' "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$ENTITLEMENTS"
codesign --force --options runtime --timestamp=none --sign - "$HELPER_APP"
codesign --force --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" --sign - "$APP_PATH"

echo "$APP_PATH"
