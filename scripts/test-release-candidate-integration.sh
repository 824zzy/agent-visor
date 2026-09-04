#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/release-version.sh"
release_load_version_config "$PROJECT_DIR"
VERSION="$(release_product_version "$PROJECT_DIR")"
BUILD="$(release_product_build "$PROJECT_DIR")"
TEMP_ROOT="$(mktemp -d -t av-candidate-policy.XXXXXX)"
APP_PATH="$TEMP_ROOT/Agent Visor.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/Agent Visor"
HELPER_APP="$APP_PATH/Contents/Helpers/Agent Visor Native Helper.app"
HELPER_EXECUTABLE="$HELPER_APP/Contents/MacOS/AgentVisorNativeHelper"
CASK_PATH="$TEMP_ROOT/agent-visor.rb"
SAFE_CASK_PATH="$TEMP_ROOT/signed-agent-visor.rb"
ENTITLEMENTS_PATH="$TEMP_ROOT/AgentVisor.entitlements"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

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
xcrun clang -arch arm64 "$TEMP_ROOT/main.c" -o "$EXECUTABLE"
xcrun clang -arch arm64 "$TEMP_ROOT/main.c" -o "$HELPER_EXECUTABLE"
plutil -create xml1 "$APP_PATH/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.824zzy.AgentVisor "$APP_PATH/Contents/Info.plist"
plutil -insert CFBundleName -string "Agent Visor" "$APP_PATH/Contents/Info.plist"
plutil -insert CFBundleDisplayName -string "Agent Visor" "$APP_PATH/Contents/Info.plist"
plutil -insert CFBundleExecutable -string "Agent Visor" "$APP_PATH/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$APP_PATH/Contents/Info.plist"
plutil -insert CFBundleVersion -string "$BUILD" "$APP_PATH/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string "$AGENT_VISOR_MIN_MACOS" "$APP_PATH/Contents/Info.plist"
plutil -insert NSAppleEventsUsageDescription -string "$AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION" "$APP_PATH/Contents/Info.plist"
plutil -insert LSUIElement -bool false "$APP_PATH/Contents/Info.plist"
plutil -create xml1 "$HELPER_APP/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string AgentVisorNativeHelper "$HELPER_APP/Contents/Info.plist"
plutil -insert CFBundleName -string "Agent Visor" "$HELPER_APP/Contents/Info.plist"
plutil -insert CFBundleDisplayName -string "Agent Visor" "$HELPER_APP/Contents/Info.plist"
plutil -insert CFBundleExecutable -string AgentVisorNativeHelper "$HELPER_APP/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string "$AGENT_VISOR_MIN_MACOS" "$HELPER_APP/Contents/Info.plist"
plutil -insert NSUserNotificationAlertStyle -string alert "$HELPER_APP/Contents/Info.plist"
plutil -insert NSAppleEventsUsageDescription -string "$AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION" "$HELPER_APP/Contents/Info.plist"
plutil -insert CFBundleIconFile -string AgentVisor.icns "$HELPER_APP/Contents/Info.plist"
printf 'icon\n' > "$HELPER_APP/Contents/Resources/AgentVisor.icns"
printf '%s\n' "{\"name\":\"agent-visor\",\"version\":\"$VERSION\",\"main\":\"packages/desktop/dist/main.js\"}" \
    > "$APP_PATH/Contents/Resources/app/package.json"
for runtime_file in \
    "$APP_PATH/Contents/Resources/app/packages/desktop/dist/main.js" \
    "$APP_PATH/Contents/Resources/app/packages/server/dist/bin.js" \
    "$APP_PATH/Contents/Resources/app/packages/app/dist/index.html" \
    "$APP_PATH/Contents/Resources/app/node_modules/@agent-visor/protocol/package.json" \
    "$APP_PATH/Contents/Resources/app/node_modules/@agent-visor/protocol/dist/index.js"; do
    printf '\n' > "$runtime_file"
done
for integration in \
    agent-visor-state.py \
    agent-visor-codex-state.py \
    agent-visor-state-auggie.sh \
    agent-visor-pi.ts.txt; do
    printf '\n' > "$APP_PATH/Contents/Resources/AgentIntegrations/$integration"
done
printf 'Electron\n' > "$APP_PATH/Contents/Resources/ThirdPartyLicenses/Electron.LICENSE"
printf '<html>Chromium</html>\n' > "$APP_PATH/Contents/Resources/ThirdPartyLicenses/LICENSES.chromium.html"
printf 'Agent Visor\n' > "$APP_PATH/Contents/Resources/ThirdPartyLicenses/AgentVisor.LICENSE.md"
printf 'notices\n' > "$APP_PATH/Contents/Resources/ThirdPartyLicenses/README.txt"
plutil -create xml1 "$ENTITLEMENTS_PATH"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool false' "$ENTITLEMENTS_PATH"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$ENTITLEMENTS_PATH"
codesign --force --options runtime --sign - "$HELPER_APP"
codesign --force --options runtime --entitlements "$ENTITLEMENTS_PATH" --sign - "$APP_PATH"
printf 'cask "agent-visor" do\n  app "Agent Visor.app"\n  postflight do\n    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine"]\n    system_command "/usr/bin/codesign", args: ["--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements,flags"]\n  end\nend\n' > "$CASK_PATH"
printf 'cask "agent-visor" do\n  app "Agent Visor.app"\nend\n' > "$SAFE_CASK_PATH"

if [[ ! -x "$SCRIPT_DIR/validate-release-candidate.sh" ]]; then
    echo "ERROR: release-candidate validator is missing" >&2
    exit 1
fi

"$SCRIPT_DIR/validate-release-candidate.sh" "$APP_PATH" "$CASK_PATH" >/dev/null

set +e
"$SCRIPT_DIR/validate-release-candidate.sh" "$APP_PATH" "$SAFE_CASK_PATH" >/dev/null 2>&1
SAFE_CASK_STATUS=$?
set -e
if (( SAFE_CASK_STATUS == 0 )); then
    echo "ERROR: ad-hoc publication accepted a cask that cannot recover from quarantine" >&2
    exit 1
fi

echo "Release candidate integration PASS"
