#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_PATH="${1:-}"

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

require_directory() {
    local path="$1"
    local label="$2"
    if [[ ! -d "$path" ]]; then
        fail "$label is missing: $path"
    fi
}

require_file() {
    local path="$1"
    local label="$2"
    if [[ ! -f "$path" ]]; then
        fail "$label is missing: $path"
    fi
}

require_executable() {
    local path="$1"
    local label="$2"
    if [[ ! -x "$path" ]]; then
        fail "$label is missing or not executable: $path"
    fi
}

require_plist_value() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local label="$4"
    local actual
    if ! actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)"; then
        fail "$label is missing from $plist"
    fi
    if [[ "$actual" != "$expected" ]]; then
        fail "$label must be '$expected' (got '$actual')"
    fi
}

require_plist_file_value() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local label="$4"
    require_plist_value "$plist" "$key" "$expected" "$label"
}

if [[ -z "$APP_PATH" ]]; then
    fail "release app path is required"
fi
if [[ "$APP_PATH" != *.app ]]; then
    fail "release app path must end in .app: $APP_PATH"
fi

source "$SCRIPT_DIR/lib/release-version.sh"
source "$SCRIPT_DIR/lib/release-publication.sh"
source "$SCRIPT_DIR/lib/release-signing.sh"
source "$PROJECT_DIR/config/release-signing.env"
release_load_version_config "$PROJECT_DIR"
VERSION="$(release_product_version "$PROJECT_DIR")"
BUILD="$(release_product_build "$PROJECT_DIR")"

require_directory "$APP_PATH" "release app bundle"
INFO="$APP_PATH/Contents/Info.plist"
require_file "$INFO" "release Info.plist"
if ! plutil -lint "$INFO" >/dev/null 2>&1; then
    fail "release Info.plist is invalid"
fi

EXECUTABLE="$APP_PATH/Contents/MacOS/$AGENT_VISOR_EXECUTABLE"
require_executable "$EXECUTABLE" "Electron release executable"
require_plist_value "$INFO" CFBundleIdentifier "$AGENT_VISOR_BUNDLE_IDENTIFIER" "bundle identifier"
require_plist_value "$INFO" CFBundleExecutable "$AGENT_VISOR_EXECUTABLE" "bundle executable name"
require_plist_value "$INFO" CFBundleShortVersionString "$VERSION" "bundle version"
require_plist_value "$INFO" CFBundleVersion "$BUILD" "bundle build number"
require_plist_value "$INFO" LSMinimumSystemVersion "$AGENT_VISOR_MIN_MACOS" "minimum macOS version"
require_plist_value "$INFO" CFBundleName "$AGENT_VISOR_PRODUCT_NAME" "bundle name"
require_plist_value "$INFO" CFBundleDisplayName "$AGENT_VISOR_PRODUCT_NAME" "bundle display name"
require_plist_value "$INFO" NSAppleEventsUsageDescription "$AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION" "Apple Events usage description"
require_plist_value "$INFO" LSUIElement "false" "Electron menu-bar visibility setting"

FILE_INFO="$(file "$EXECUTABLE" 2>&1)"
if [[ "$FILE_INFO" != *"Mach-O 64-bit executable arm64"* ]]; then
    fail "Electron release executable must be an arm64 Mach-O (got: $FILE_INFO)"
fi

# These are the Swift development runtime paths. Keep the old path names in
# the policy so a rollback-era helper or LaunchAgent cannot enter a public
# Electron archive by accident.
LEGACY_HELPER="$APP_PATH/Contents/Helpers/AgentVisorDevCodexRuntime"
LEGACY_LAUNCH_AGENT="$APP_PATH/Contents/Library/LaunchAgents/com.824zzy.AgentVisor.Dev.CodexRuntime.plist"
if [[ -e "$LEGACY_HELPER" ]]; then
    fail "development helper is present: Contents/Helpers/AgentVisorDevCodexRuntime"
fi
if [[ -e "$LEGACY_LAUNCH_AGENT" ]]; then
    fail "development LaunchAgent is present: Contents/Library/LaunchAgents"
fi

HELPER_APP="$APP_PATH/Contents/Helpers/Agent Visor Native Helper.app"
HELPER_INFO="$HELPER_APP/Contents/Info.plist"
HELPER_EXECUTABLE="$HELPER_APP/Contents/MacOS/AgentVisorNativeHelper"
require_directory "$HELPER_APP" "notification helper bundle"
require_file "$HELPER_INFO" "notification helper Info.plist"
require_executable "$HELPER_EXECUTABLE" "notification helper executable"
require_plist_value "$HELPER_INFO" CFBundleIdentifier "AgentVisorNativeHelper" "notification helper identifier"
require_plist_value "$HELPER_INFO" CFBundleExecutable "AgentVisorNativeHelper" "notification helper executable name"
require_plist_value "$HELPER_INFO" LSMinimumSystemVersion "$AGENT_VISOR_MIN_MACOS" "notification helper minimum macOS version"
require_plist_value "$HELPER_INFO" NSUserNotificationAlertStyle "alert" "notification helper alert style"
require_plist_value "$HELPER_INFO" NSAppleEventsUsageDescription "$AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION" "notification helper Apple Events usage description"
require_plist_value "$HELPER_INFO" CFBundleIconFile AgentVisor.icns "notification helper icon"
require_file "$HELPER_APP/Contents/Resources/AgentVisor.icns" "notification helper icon resource"
if [[ -e "$APP_PATH/Contents/MacOS/AgentVisorNativeHelper" ]]; then
    fail "notification helper must remain a bundle, not an outer executable"
fi
if /usr/libexec/PlistBuddy -c 'Print :NSUserNotificationAlertStyle' "$INFO" >/dev/null 2>&1; then
    fail "Electron must not register a second notification client"
fi

RUNTIME_ROOT="$APP_PATH/Contents/Resources/app"
RUNTIME_PACKAGE="$RUNTIME_ROOT/package.json"
require_file "$RUNTIME_PACKAGE" "Electron runtime package manifest"
if ! node -e '
const fs = require("fs");
const [path, version] = process.argv.slice(1);
const value = JSON.parse(fs.readFileSync(path, "utf8"));
if (value.version !== version || value.main !== "packages/desktop/dist/main.js") process.exit(1);
' "$RUNTIME_PACKAGE" "$VERSION"; then
    fail "Electron runtime manifest does not contain the canonical version and main entry"
fi
require_file "$RUNTIME_ROOT/packages/desktop/dist/main.js" "Electron desktop runtime"
require_file "$RUNTIME_ROOT/packages/server/dist/bin.js" "Electron daemon runtime"
require_file "$RUNTIME_ROOT/packages/app/dist/index.html" "Electron renderer export"
require_file "$RUNTIME_ROOT/node_modules/@agent-visor/protocol/package.json" "Electron protocol package manifest"
require_file "$RUNTIME_ROOT/node_modules/@agent-visor/protocol/dist/index.js" "Electron protocol runtime"
require_directory "$RUNTIME_ROOT/node_modules/ws" "Electron ws runtime dependency"
require_directory "$RUNTIME_ROOT/node_modules/zod" "Electron zod runtime dependency"

INTEGRATIONS="$APP_PATH/Contents/Resources/AgentIntegrations"
for integration in \
    agent-visor-state.py \
    agent-visor-codex-state.py \
    agent-visor-state-auggie.sh \
    agent-visor-pi.ts.txt; do
    require_file "$INTEGRATIONS/$integration" "Electron integration $integration"
done

NOTICES="$APP_PATH/Contents/Resources/$AGENT_VISOR_THIRD_PARTY_LICENSES_DIR"
require_file "$NOTICES/Electron.LICENSE" "Electron license notice"
require_file "$NOTICES/LICENSES.chromium.html" "Chromium license notice"
require_file "$NOTICES/AgentVisor.LICENSE.md" "Agent Visor license notice"
require_file "$NOTICES/README.txt" "third-party notices index"

if find "$APP_PATH/Contents" -name '__MACOSX' -o -name '.DS_Store' -o -name '*.p12' -o -name '*.password' | grep -q .; then
    fail "release app contains metadata or signing secret artifacts"
fi

if ! codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    fail "release app signature failed strict deep verification"
fi
SIGNING_INFO="$(codesign -dvvv "$APP_PATH" 2>&1)"
if ! grep -Eq 'flags=.*runtime' <<<"$SIGNING_INFO"; then
    fail "release app does not carry the hardened runtime"
fi
if ! HELPER_SIGNING_INFO="$(codesign -dvvv "$HELPER_APP" 2>&1)"; then
    fail "notification helper signature could not be inspected"
fi
if ! DISTRIBUTION_MODE="$(release_distribution_mode "$SIGNING_INFO")"; then
    fail "release app has an unsupported signing identity"
fi
PINNED_IDENTITY=""
PINNED_TEAM=""
if [[ "$DISTRIBUTION_MODE" == "self-signed" ]]; then
    PINNED_IDENTITY="$AGENT_VISOR_RELEASE_IDENTITY"
    PINNED_TEAM="not set"
fi
if ! release_validate_nested_signature \
    "$DISTRIBUTION_MODE" \
    "$SIGNING_INFO" \
    "$HELPER_SIGNING_INFO" \
    "$PINNED_IDENTITY" \
    "$PINNED_TEAM"; then
    fail "nested native helper signing identity/team does not match the outer release app"
fi

ENTITLEMENTS_PATH="$(mktemp -t av-release-entitlements).plist"
cleanup_entitlements() {
    rm -f "$ENTITLEMENTS_PATH"
}
trap cleanup_entitlements EXIT
if ! codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PATH" 2>/dev/null; then
    fail "release app entitlements could not be read"
fi
if grep -q 'com.apple.security.get-task-allow' "$ENTITLEMENTS_PATH"; then
    fail "release app contains com.apple.security.get-task-allow"
fi
require_plist_value "$ENTITLEMENTS_PATH" com.apple.security.app-sandbox "false" "app sandbox entitlement"
require_plist_value "$ENTITLEMENTS_PATH" com.apple.security.cs.disable-library-validation "true" "library validation entitlement"

echo "Release bundle PASS: Electron identity, arm64 executable, runtime layout, notices, entitlements, and signatures are valid."
