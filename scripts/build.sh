#!/bin/bash
# Build the Agent Visor Electron release candidate.
#
# This remains the public release interface: build/export/Agent Visor.app.
# CI invokes it without credentials for an ad-hoc validation candidate. The
# release machine supplies AV_RELEASE_SIGN_IDENTITY for the pinned self-signed
# identity or a Developer ID Application identity plus AV_RELEASE_TEAM_ID.
# Ad-hoc artifacts are for local and CI validation only.
# The Swift 2.6.1 rollback builder lives at scripts/build-swift-legacy.sh.
# Its xcodebuild path still uses -onlyUsePackageVersionsFromResolvedFile and
# CODE_SIGN_STYLE=Manual and CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"
APP_NAME="Agent Visor.app"
SIGNING_IDENTITY="${AV_RELEASE_SIGN_IDENTITY:-}"
TEAM_IDENTIFIER="${AV_RELEASE_TEAM_ID:-}"
RELEASE_SIGNING_CONFIG="$PROJECT_DIR/config/release-signing.env"
RELEASE_DERIVED="${AV_RELEASE_DERIVED:-/tmp/av-release-build}"

source "$SCRIPT_DIR/lib/release-build-mode.sh"
source "$SCRIPT_DIR/lib/release-version.sh"
source "$RELEASE_SIGNING_CONFIG"

COORDINATES="$(release_assert_coordinates "$PROJECT_DIR" "${AV_VERSION:-}" "${AV_BUILD:-}")"
IFS=$'\t' read -r VERSION BUILD <<<"$COORDINATES"
PINNED_RELEASE_SHA1="$(printf '%s' "$AGENT_VISOR_RELEASE_CERT_SHA1" | tr '[:lower:]' '[:upper:]')"
BUILD_MODE="$(release_build_mode "$SIGNING_IDENTITY" "$TEAM_IDENTIFIER")"

if [[ "$BUILD_MODE" == "self-signed" ]]; then
    IDENTITY_LINE="$(security find-identity -v -p codesigning \
        "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
        | grep -F "\"$AGENT_VISOR_RELEASE_IDENTITY\"" \
        | grep -v 'CSSMERR_TP_NOT_TRUSTED' \
        | head -1 || true)"
    if [[ -z "$IDENTITY_LINE" ]]; then
        echo "ERROR: pinned self-signed release identity is not installed and trusted:" >&2
        echo "       $AGENT_VISOR_RELEASE_IDENTITY" >&2
        echo "       Run scripts/release-sign-setup.sh." >&2
        exit 1
    fi
    INSTALLED_SHA1="$(awk '{print toupper($2)}' <<<"$IDENTITY_LINE")"
    if [[ "$INSTALLED_SHA1" != "$PINNED_RELEASE_SHA1" ]]; then
        echo "ERROR: installed release certificate does not match the pinned identity." >&2
        echo "       installed: $INSTALLED_SHA1" >&2
        echo "       expected:  $PINNED_RELEASE_SHA1" >&2
        exit 1
    fi
elif [[ "$BUILD_MODE" == "developer-id" ]]; then
    if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
        echo "ERROR: Developer ID identity is not installed in the active keychain:" >&2
        echo "       $SIGNING_IDENTITY" >&2
        exit 1
    fi
fi

echo "=== Building Agent Visor Electron Release ==="
echo "Version: $VERSION (build $BUILD)"
echo "Signing mode: $BUILD_MODE"
echo "Output: $EXPORT_PATH/$APP_NAME"

# Resolve the pinned Swift package graph into the release DerivedData path.
# The Electron app does not link Sparkle, but create-release.sh uses Sparkle's
# pinned sign_update binary from this graph to sign the archive metadata.
xcodebuild \
    -resolvePackageDependencies \
    -project "$PROJECT_DIR/AgentVisor.xcodeproj" \
    -scheme AgentVisor \
    -derivedDataPath "$RELEASE_DERIVED" \
    -onlyUsePackageVersionsFromResolvedFile

SPARKLE_SIGN="$RELEASE_DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ ! -x "$SPARKLE_SIGN" ]]; then
    echo "ERROR: pinned Sparkle sign_update was not resolved at: $SPARKLE_SIGN" >&2
    exit 1
fi

rm -rf "$EXPORT_PATH"
mkdir -p "$EXPORT_PATH"
cd "$PROJECT_DIR"

# package-electron.sh is the sole producer of the exported app. Keeping this
# entry point stable lets create-release.sh and CI validate identical bytes.
AV_VERSION="$VERSION" \
AV_BUILD="$BUILD" \
AV_RELEASE_BUILD_MODE="$BUILD_MODE" \
AV_SIGN_IDENTITY="$SIGNING_IDENTITY" \
AV_RELEASE_TEAM_ID="$TEAM_IDENTIFIER" \
AV_ELECTRON_OUTPUT_DIR="$EXPORT_PATH" \
    "$SCRIPT_DIR/package-electron.sh"

APP_PATH="$EXPORT_PATH/$APP_NAME"
ZIP_PATH="$EXPORT_PATH/AgentVisor-v$VERSION.zip"
STABLE_ZIP_PATH="$EXPORT_PATH/AgentVisor-release.zip"
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Electron build did not export the expected app: $APP_PATH" >&2
    exit 1
fi
if [[ ! -f "$ZIP_PATH" ]]; then
    echo "ERROR: Electron build did not export the expected archive: $ZIP_PATH" >&2
    exit 1
fi
if [[ ! -f "$STABLE_ZIP_PATH" ]]; then
    echo "ERROR: Electron build did not export the stable archive path: $STABLE_ZIP_PATH" >&2
    exit 1
fi

"$SCRIPT_DIR/test-release-bundle.sh" "$APP_PATH"
"$SCRIPT_DIR/test-release-archive.sh" "$ZIP_PATH"

if [[ "$BUILD_MODE" == "self-signed" || "$BUILD_MODE" == "developer-id" ]]; then
    "$SCRIPT_DIR/verify-stable-release-signature.sh" "$APP_PATH"
else
    # Keep the historical Homebrew recovery contract exercised in credential-
    # free CI without changing the distributed candidate itself.
    "$SCRIPT_DIR/test-homebrew-resign.sh" "$APP_PATH"
    echo "Ad-hoc build validated for local and CI use; public publication is disabled."
fi

echo "=== Build Complete ==="
echo "App exported to: $APP_PATH"
echo "Archive exported to: $ZIP_PATH"
