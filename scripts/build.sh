#!/bin/bash
# Build Agent Visor.
#
# With AV_RELEASE_SIGN_IDENTITY="AgentVisor Release", this creates the current
# self-signed public release candidate. A Developer ID identity and Team ID
# create the optional notarizable candidate. Without either identity, the
# script creates a credential-free local and CI ad-hoc validation artifact.
#
# Keep Release derived data out of Xcode's default DerivedData so local
# daily-driver TCC grants are not disturbed by release packaging builds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"
DERIVED="${AV_RELEASE_DERIVED:-/tmp/av-release-build}"
APP_NAME="Agent Visor.app"
SIGNING_IDENTITY="${AV_RELEASE_SIGN_IDENTITY:-}"
TEAM_IDENTIFIER="${AV_RELEASE_TEAM_ID:-}"
RELEASE_SIGNING_CONFIG="$PROJECT_DIR/config/release-signing.env"

source "$SCRIPT_DIR/lib/release-build-mode.sh"
source "$RELEASE_SIGNING_CONFIG"
PINNED_RELEASE_SHA1="$(printf '%s' "$AGENT_VISOR_RELEASE_CERT_SHA1" | tr '[:lower:]' '[:upper:]')"
BUILD_MODE="$(release_build_mode "$SIGNING_IDENTITY" "$TEAM_IDENTIFIER")"

if [[ "$BUILD_MODE" == "self-signed" ]]; then
    IDENTITY_LINE="$({
        security find-identity -v -p codesigning \
            "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
            | grep -F "\"$AGENT_VISOR_RELEASE_IDENTITY\"" \
            | grep -v 'CSSMERR_TP_NOT_TRUSTED' \
            | head -1
    })"
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
    XCODE_SIGNING_ARGS=(
        CODE_SIGN_STYLE=Manual
        "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
        CODE_SIGNING_REQUIRED=YES
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    )
elif [[ "$BUILD_MODE" == "developer-id" ]]; then
    if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
        echo "ERROR: Developer ID identity is not installed in the active keychain:" >&2
        echo "       $SIGNING_IDENTITY" >&2
        exit 1
    fi
    XCODE_SIGNING_ARGS=(
        CODE_SIGN_STYLE=Manual
        "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
        "DEVELOPMENT_TEAM=$TEAM_IDENTIFIER"
        CODE_SIGNING_REQUIRED=YES
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    )
else
    XCODE_SIGNING_ARGS=(
        CODE_SIGN_IDENTITY=-
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
        CODE_SIGNING_REQUIRED=NO
    )
fi

echo "=== Building Agent Visor Release ==="
echo "Derived data: $DERIVED"
echo "Signing mode: $BUILD_MODE"
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_PATH"

cd "$PROJECT_DIR"

xcodebuild \
    -project AgentVisor.xcodeproj \
    -scheme AgentVisor \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -onlyUsePackageVersionsFromResolvedFile \
    "${XCODE_SIGNING_ARGS[@]}" \
    build

APP_PATH="$DERIVED/Build/Products/Release/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: expected app not found at $APP_PATH"
    exit 1
fi

ditto "$APP_PATH" "$EXPORT_PATH/$APP_NAME"
"$SCRIPT_DIR/test-release-bundle.sh" "$EXPORT_PATH/$APP_NAME"

if [[ "$BUILD_MODE" == "self-signed" || "$BUILD_MODE" == "developer-id" ]]; then
    "$SCRIPT_DIR/verify-stable-release-signature.sh" "$EXPORT_PATH/$APP_NAME"
    if [[ "$BUILD_MODE" == "developer-id" ]]; then
        echo "Developer ID candidate built. Run scripts/notarize-release.sh before publishing."
    else
        echo "Self-signed release candidate built with the pinned certificate."
    fi
else
    "$SCRIPT_DIR/test-homebrew-resign.sh" "$EXPORT_PATH/$APP_NAME"
    echo "Ad-hoc build validated for local and CI use; public publication is disabled."
fi

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/$APP_NAME"
echo ""
if [[ "$BUILD_MODE" == "developer-id" ]]; then
    echo "Next: Run ./scripts/notarize-release.sh, then ./scripts/create-release.sh"
elif [[ "$BUILD_MODE" == "self-signed" ]]; then
    echo "Next: Run ./scripts/create-release.sh"
else
    echo "This ad-hoc artifact is for local and CI validation only."
fi
