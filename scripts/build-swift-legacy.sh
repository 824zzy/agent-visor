#!/bin/bash
# Export the exact public Swift v2.6.1 rollback artifact while the Electron
# release completes its observation window. The v2.6.1 ZIP is the source of
# truth here: rebuilding the current checkout could silently produce an
# Electron or post-2.6.1 app under the rollback name.
#
# This entry is intentionally separate from scripts/build.sh. The public
# release entry builds Electron; this script copies and verifies the last
# known Swift release without invoking Xcode or changing its signature.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${AV_SWIFT_LEGACY_BUILD_DIR:-$PROJECT_DIR/build/swift-legacy}"
EXPORT_PATH="$BUILD_DIR/export"
APP_NAME="Agent Visor.app"

# These values are deliberately independent of config/release-version.env,
# which describes the current Electron release.
LEGACY_VERSION="2.6.1"
LEGACY_BUILD="53"
LEGACY_SOURCE_TAG="v2.6.1"
LEGACY_SOURCE_COMMIT="8d7bcd588dff079b3ac2abfa9dc8ec2cf5c7cd6e"
LEGACY_ARTIFACT_URL="https://github.com/824zzy/agent-visor/releases/download/v2.6.1/AgentVisor-v2.6.1.zip"
LEGACY_ARTIFACT_SHA256="676e82d217f22e723eb27b6d1b6749ab6ffc199112cf4c4a51871a1c7f6611fb"
LEGACY_ARTIFACT_SIZE="12943176"
LEGACY_ARTIFACT_OVERRIDE="${AV_SWIFT_LEGACY_ARTIFACT_PATH:-}"

TEMP_ROOT="$(mktemp -d -t av-swift-legacy.XXXXXX)"
SOURCE_ZIP="$TEMP_ROOT/AgentVisor-v$LEGACY_VERSION.zip"
EXTRACT_ROOT="$TEMP_ROOT/extracted"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

if [[ -n "${AV_RELEASE_SIGN_IDENTITY:-}" || -n "${AV_RELEASE_TEAM_ID:-}" ]]; then
    echo "ERROR: the pinned Swift rollback artifact is already signed; signing overrides are unsupported." >&2
    exit 1
fi

if [[ -n "$LEGACY_ARTIFACT_OVERRIDE" ]]; then
    if [[ ! -f "$LEGACY_ARTIFACT_OVERRIDE" ]]; then
        echo "ERROR: Swift rollback artifact override not found: $LEGACY_ARTIFACT_OVERRIDE" >&2
        exit 1
    fi
    cp "$LEGACY_ARTIFACT_OVERRIDE" "$SOURCE_ZIP"
else
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: curl is required to retrieve the public Swift rollback artifact." >&2
        exit 1
    fi
    echo "Downloading public Swift rollback artifact $LEGACY_SOURCE_TAG..."
    curl --fail --location --silent --show-error --retry 3 \
        --output "$SOURCE_ZIP" "$LEGACY_ARTIFACT_URL"
fi

ACTUAL_SHA256="$(shasum -a 256 "$SOURCE_ZIP" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$LEGACY_ARTIFACT_SHA256" ]]; then
    echo "ERROR: Swift rollback artifact checksum mismatch." >&2
    echo "       expected: $LEGACY_ARTIFACT_SHA256" >&2
    echo "       actual:   $ACTUAL_SHA256" >&2
    exit 1
fi

ACTUAL_SIZE="$(stat -f '%z' "$SOURCE_ZIP")"
if [[ "$ACTUAL_SIZE" != "$LEGACY_ARTIFACT_SIZE" ]]; then
    echo "ERROR: Swift rollback artifact size mismatch." >&2
    echo "       expected: $LEGACY_ARTIFACT_SIZE" >&2
    echo "       actual:   $ACTUAL_SIZE" >&2
    exit 1
fi

if ! unzip -tq "$SOURCE_ZIP" >/dev/null; then
    echo "ERROR: Swift rollback artifact is not a valid ZIP archive." >&2
    exit 1
fi

mkdir -p "$EXTRACT_ROOT"
ditto -x -k "$SOURCE_ZIP" "$EXTRACT_ROOT"
APP_PATH="$EXTRACT_ROOT/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: pinned Swift rollback app is missing from the public artifact: $APP_PATH" >&2
    exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")"
if [[ "$APP_VERSION" != "$LEGACY_VERSION" || "$APP_BUILD" != "$LEGACY_BUILD" ]]; then
    echo "ERROR: pinned Swift rollback app coordinates do not match v$LEGACY_VERSION." >&2
    echo "       expected: version $LEGACY_VERSION (build $LEGACY_BUILD)" >&2
    echo "       actual:   version $APP_VERSION (build $APP_BUILD)" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP_PATH"
"$SCRIPT_DIR/verify-stable-release-signature.sh" "$APP_PATH"

# Only replace the caller-selected output after the downloaded artifact and
# its signature have passed every check. The two ZIP names are byte-for-byte
# copies of the public release; no re-signing or re-packaging is performed.
rm -rf "$EXPORT_PATH"
mkdir -p "$EXPORT_PATH"
ditto "$APP_PATH" "$EXPORT_PATH/$APP_NAME"
cp "$SOURCE_ZIP" "$EXPORT_PATH/AgentVisor-v$LEGACY_VERSION.zip"
cp "$SOURCE_ZIP" "$EXPORT_PATH/AgentVisor-release.zip"
shasum -a 256 "$EXPORT_PATH/AgentVisor-v$LEGACY_VERSION.zip" \
    > "$EXPORT_PATH/AgentVisor-v$LEGACY_VERSION.zip.sha256"
shasum -a 256 "$EXPORT_PATH/AgentVisor-release.zip" \
    > "$EXPORT_PATH/AgentVisor-release.zip.sha256"

echo "Swift rollback artifact: v$LEGACY_VERSION ($LEGACY_SOURCE_COMMIT)"
echo "Swift rollback application exported to: $EXPORT_PATH/$APP_NAME"
echo "Swift rollback archive exported to: $EXPORT_PATH/AgentVisor-release.zip"
