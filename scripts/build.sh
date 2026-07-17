#!/bin/bash
# Build Agent Visor for release.
#
# The distributed app is ad-hoc signed. Homebrew removes quarantine and
# re-signs after install; direct-download users can remove quarantine
# manually as documented in README.md.
#
# Keep Release derived data out of Xcode's default DerivedData so local
# daily-driver TCC grants are not disturbed by release packaging builds.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"
DERIVED="${AV_RELEASE_DERIVED:-/tmp/av-release-build}"
APP_NAME="Agent Visor.app"

echo "=== Building Agent Visor Release ==="
echo "Derived data: $DERIVED"
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
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

APP_PATH="$DERIVED/Build/Products/Release/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: expected app not found at $APP_PATH"
    exit 1
fi

ditto "$APP_PATH" "$EXPORT_PATH/$APP_NAME"
"$SCRIPT_DIR/test-release-bundle.sh" "$EXPORT_PATH/$APP_NAME"
"$SCRIPT_DIR/test-homebrew-resign.sh" "$EXPORT_PATH/$APP_NAME"

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/$APP_NAME"
echo ""
echo "Next: Run ./scripts/create-release.sh to create the release ZIP and appcast item"
