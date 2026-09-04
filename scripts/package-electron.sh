#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT/scripts"
OUTPUT="${AV_ELECTRON_OUTPUT_DIR:-$ROOT/build/electron}"
APP="$OUTPUT/Agent Visor.app"
SOURCE="$ROOT/node_modules/electron/dist/Electron.app"
ENTITLEMENTS="$ROOT/scripts/electron-entitlements.plist"

source "$SCRIPT_DIR/lib/release-build-mode.sh"
source "$SCRIPT_DIR/lib/release-version.sh"
source "$ROOT/config/release-signing.env"

release_load_version_config "$ROOT"
COORDINATES="$(release_assert_coordinates "$ROOT" "${AV_VERSION:-}" "${AV_BUILD:-}")"
IFS=$'\t' read -r VERSION BUILD <<<"$COORDINATES"

if [[ "${AV_SIGN_IDENTITY+x}" == x ]]; then
    IDENTITY="$AV_SIGN_IDENTITY"
else
    IDENTITY="${AV_RELEASE_SIGN_IDENTITY:-$AGENT_VISOR_RELEASE_IDENTITY}"
fi
TEAM_IDENTIFIER="${AV_RELEASE_TEAM_ID:-}"
EXPECTED_MODE="$(release_build_mode "$IDENTITY" "$TEAM_IDENTIFIER")"
if [[ -n "${AV_RELEASE_BUILD_MODE:-}" && "$AV_RELEASE_BUILD_MODE" != "$EXPECTED_MODE" ]]; then
    echo "ERROR: requested Electron build mode '$AV_RELEASE_BUILD_MODE' does not match the signing policy '$EXPECTED_MODE'" >&2
    exit 1
fi
BUILD_MODE="${AV_RELEASE_BUILD_MODE:-$EXPECTED_MODE}"

case "$BUILD_MODE" in
    local-adhoc)
        if [[ -n "$IDENTITY" || -n "$TEAM_IDENTIFIER" ]]; then
            echo "ERROR: ad-hoc Electron packaging cannot carry a signing identity or Team ID" >&2
            exit 1
        fi
        CODESIGN_IDENTITY="-"
        CODESIGN_TIMESTAMP=(--timestamp=none)
        ;;
    self-signed)
        if [[ "$IDENTITY" != "$AGENT_VISOR_RELEASE_IDENTITY" ]]; then
            echo "ERROR: self-signed Electron packaging must use $AGENT_VISOR_RELEASE_IDENTITY" >&2
            exit 1
        fi
        IDENTITY_LINE="$(security find-identity -v -p codesigning \
            "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
            | grep -F "\"$IDENTITY\"" \
            | grep -v 'CSSMERR_TP_NOT_TRUSTED' \
            | head -1 || true)"
        if [[ -z "$IDENTITY_LINE" ]]; then
            echo "ERROR: pinned self-signed release identity is unavailable: $IDENTITY" >&2
            exit 1
        fi
        INSTALLED_SHA1="$(awk '{print toupper($2)}' <<<"$IDENTITY_LINE")"
        PINNED_SHA1="$(printf '%s' "$AGENT_VISOR_RELEASE_CERT_SHA1" | tr '[:lower:]' '[:upper:]')"
        if [[ "$INSTALLED_SHA1" != "$PINNED_SHA1" ]]; then
            echo "ERROR: installed release certificate does not match the pinned identity" >&2
            echo "       installed: $INSTALLED_SHA1" >&2
            echo "       expected:  $PINNED_SHA1" >&2
            exit 1
        fi
        CODESIGN_IDENTITY="$IDENTITY"
        CODESIGN_TIMESTAMP=(--timestamp)
        ;;
    developer-id)
        if ! security find-identity -v -p codesigning \
            | grep -Fq "\"$IDENTITY\""; then
            echo "ERROR: Developer ID identity is unavailable: $IDENTITY" >&2
            exit 1
        fi
        CODESIGN_IDENTITY="$IDENTITY"
        CODESIGN_TIMESTAMP=(--timestamp)
        ;;
    *)
        echo "ERROR: unsupported Electron build mode: $BUILD_MODE" >&2
        exit 1
        ;;
esac

if [[ ! -d "$SOURCE" ]]; then
    echo "ERROR: Electron runtime is missing at $SOURCE" >&2
    echo "       Run npm ci before packaging." >&2
    exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "ERROR: Electron release entitlements are missing at $ENTITLEMENTS" >&2
    exit 1
fi

set_plist_string() {
    local key="$1"
    local value="$2"
    local path="$3"
    if ! plutil -replace "$key" -string "$value" "$path" 2>/dev/null; then
        plutil -insert "$key" -string "$value" "$path"
    fi
}

set_plist_bool() {
    local key="$1"
    local value="$2"
    local path="$3"
    if ! plutil -replace "$key" -bool "$value" "$path" 2>/dev/null; then
        plutil -insert "$key" -bool "$value" "$path"
    fi
}

copy_required_notice() {
    local source_path="$1"
    local destination_path="$2"
    if [[ ! -s "$source_path" ]]; then
        echo "ERROR: required distribution notice is missing: $source_path" >&2
        exit 1
    fi
    cp "$source_path" "$destination_path"
}

echo "=== Building Electron Agent Visor $VERSION (build $BUILD) ==="
echo "Output: $APP"
echo "Signing mode: $BUILD_MODE"

npm --prefix "$ROOT" run build

rm -rf "$OUTPUT/Agent Visor.app" "$OUTPUT/AgentVisor-v$VERSION.zip" \
    "$OUTPUT/AgentVisor-v$VERSION.zip.sha256" "$OUTPUT/AgentVisor-release.zip" \
    "$OUTPUT/AgentVisor-release.zip.sha256" "$OUTPUT/native-helper"
mkdir -p "$OUTPUT"

AV_NATIVE_HELPER_SIGN_IDENTITY="$IDENTITY" \
AV_NATIVE_HELPER_TEAM_ID="$TEAM_IDENTIFIER" \
AV_NATIVE_HELPER_SIGNING_MODE="$BUILD_MODE" \
AV_NATIVE_HELPER_OUTPUT_DIR="$OUTPUT/native-helper" \
AV_VERSION="$VERSION" \
AV_BUILD="$BUILD" \
    "$ROOT/scripts/build-native-helper.sh"

ditto "$SOURCE" "$APP"
INFO="$APP/Contents/Info.plist"
RESOURCES="$APP/Contents/Resources"
MAIN_EXECUTABLE="$APP/Contents/MacOS/Agent Visor"
ELECTRON_EXECUTABLE="$APP/Contents/MacOS/Electron"
if [[ ! -x "$ELECTRON_EXECUTABLE" ]]; then
    echo "ERROR: Electron runtime has no expected main executable: $ELECTRON_EXECUTABLE" >&2
    exit 1
fi
mv "$ELECTRON_EXECUTABLE" "$MAIN_EXECUTABLE"

set_plist_string CFBundleIdentifier "$AGENT_VISOR_BUNDLE_IDENTIFIER" "$INFO"
set_plist_string CFBundleName "$AGENT_VISOR_PRODUCT_NAME" "$INFO"
set_plist_string CFBundleDisplayName "$AGENT_VISOR_PRODUCT_NAME" "$INFO"
set_plist_string CFBundleExecutable "$AGENT_VISOR_EXECUTABLE" "$INFO"
set_plist_string CFBundleShortVersionString "$VERSION" "$INFO"
set_plist_string CFBundleVersion "$BUILD" "$INFO"
set_plist_string LSMinimumSystemVersion "$AGENT_VISOR_MIN_MACOS" "$INFO"
set_plist_string NSAppleEventsUsageDescription "$AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION" "$INFO"
set_plist_bool LSUIElement false "$INFO"

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
set_plist_string CFBundleIconFile AgentVisor.icns "$INFO"

rm -rf "$RESOURCES/default_app.asar" "$RESOURCES/app"
mkdir -p "$RESOURCES/app/packages/desktop" "$RESOURCES/app/packages/server" \
    "$RESOURCES/app/packages/app" "$RESOURCES/app/node_modules/@agent-visor/protocol" \
    "$RESOURCES/app/node_modules"
printf '%s\n' \
    "{\"name\":\"agent-visor\",\"version\":\"$VERSION\",\"private\":true,\"type\":\"module\",\"main\":\"packages/desktop/dist/main.js\"}" \
    > "$RESOURCES/app/package.json"
for dist in \
    "$ROOT/packages/desktop/dist" \
    "$ROOT/packages/server/dist" \
    "$ROOT/packages/app/dist" \
    "$ROOT/packages/protocol/dist"; do
    if [[ ! -d "$dist" ]]; then
        echo "ERROR: compiled workspace output is missing: $dist" >&2
        exit 1
    fi
done
ditto "$ROOT/packages/desktop/dist" "$RESOURCES/app/packages/desktop/dist"
ditto "$ROOT/packages/server/dist" "$RESOURCES/app/packages/server/dist"
ditto "$ROOT/packages/app/dist" "$RESOURCES/app/packages/app/dist"
ditto "$ROOT/packages/protocol/dist" "$RESOURCES/app/node_modules/@agent-visor/protocol/dist"
cp "$ROOT/packages/protocol/package.json" "$RESOURCES/app/node_modules/@agent-visor/protocol/package.json"
for dependency in ws zod; do
    if [[ ! -d "$ROOT/node_modules/$dependency" ]]; then
        echo "ERROR: runtime dependency is missing: $ROOT/node_modules/$dependency" >&2
        exit 1
    fi
    ditto "$ROOT/node_modules/$dependency" "$RESOURCES/app/node_modules/$dependency"
done

NOTICES="$RESOURCES/$AGENT_VISOR_THIRD_PARTY_LICENSES_DIR"
mkdir -p "$NOTICES"
copy_required_notice "$ROOT/node_modules/electron/LICENSE" "$NOTICES/Electron.LICENSE"
CHROMIUM_LICENSE="$ROOT/node_modules/electron/LICENSES.chromium.html"
if [[ ! -s "$CHROMIUM_LICENSE" ]]; then
    CHROMIUM_LICENSE="$ROOT/node_modules/electron/dist/LICENSES.chromium.html"
fi
copy_required_notice "$CHROMIUM_LICENSE" "$NOTICES/LICENSES.chromium.html"
copy_required_notice "$ROOT/LICENSE.md" "$NOTICES/AgentVisor.LICENSE.md"
for dependency in ws zod; do
    if [[ -s "$ROOT/node_modules/$dependency/LICENSE" ]]; then
        cp "$ROOT/node_modules/$dependency/LICENSE" "$NOTICES/$dependency.LICENSE"
    fi
done
printf '%s\n' \
    "Agent Visor third-party notices" \
    "" \
    "Electron.LICENSE and LICENSES.chromium.html are distributed by Electron." \
    "The remaining files identify notices for runtime dependencies shipped in this app." \
    > "$NOTICES/README.txt"

mkdir -p "$APP/Contents/Helpers"
HELPER_APP="$APP/Contents/Helpers/Agent Visor Native Helper.app"
if [[ ! -d "$OUTPUT/native-helper/Agent Visor Native Helper.app" ]]; then
    echo "ERROR: signed native helper bundle is missing" >&2
    exit 1
fi
ditto "$OUTPUT/native-helper/Agent Visor Native Helper.app" "$HELPER_APP"
mkdir -p "$HELPER_APP/Contents/Resources"
cp "$RESOURCES/AgentVisor.icns" "$HELPER_APP/Contents/Resources/AgentVisor.icns"
set_plist_string NSAppleEventsUsageDescription "$AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION" \
    "$HELPER_APP/Contents/Info.plist"
set_plist_string CFBundleIconFile AgentVisor.icns "$HELPER_APP/Contents/Info.plist"

mkdir -p "$RESOURCES/AgentIntegrations"
for integration in \
    agent-visor-state.py \
    agent-visor-codex-state.py \
    agent-visor-state-auggie.sh \
    agent-visor-pi.ts.txt; do
    if [[ ! -f "$ROOT/AgentVisor/Resources/$integration" ]]; then
        echo "ERROR: integration resource is missing: $integration" >&2
        exit 1
    fi
    cp "$ROOT/AgentVisor/Resources/$integration" "$RESOURCES/AgentIntegrations/$integration"
done

codesign --force --deep --options runtime "${CODESIGN_TIMESTAMP[@]}" \
    --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noacl --keepParent \
    "$APP" "$OUTPUT/AgentVisor-v$VERSION.zip"
shasum -a 256 "$OUTPUT/AgentVisor-v$VERSION.zip" > "$OUTPUT/AgentVisor-v$VERSION.zip.sha256"
ln "$OUTPUT/AgentVisor-v$VERSION.zip" "$OUTPUT/AgentVisor-release.zip"
shasum -a 256 "$OUTPUT/AgentVisor-release.zip" > "$OUTPUT/AgentVisor-release.zip.sha256"
echo "Electron candidate: $OUTPUT/AgentVisor-v$VERSION.zip"
