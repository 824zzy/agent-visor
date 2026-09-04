#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build.sh"
PACKAGER_SCRIPT="$SCRIPT_DIR/package-electron.sh"
ARCHIVER_SCRIPT="$SCRIPT_DIR/create-release-archive.sh"
BUNDLE_VALIDATOR="$SCRIPT_DIR/test-release-bundle.sh"
LEGACY_SCRIPT="$SCRIPT_DIR/build-swift-legacy.sh"

require_source() {
    local pattern="$1"
    local message="$2"
    if ! grep -Fq "$pattern" "$BUILD_SCRIPT"; then
        echo "ERROR: $message" >&2
        exit 1
    fi
}

require_source 'source "$SCRIPT_DIR/lib/release-build-mode.sh"' \
    "build.sh does not use the release build-mode policy"
require_source 'AV_RELEASE_SIGN_IDENTITY' \
    "build.sh does not accept a Developer ID Application identity"
require_source 'config/release-signing.env' \
    "build.sh does not load the pinned self-signed release identity"
require_source 'AGENT_VISOR_RELEASE_CERT_SHA1' \
    "build.sh does not verify the pinned self-signed certificate"
require_source 'CODE_SIGN_STYLE=Manual' \
    "build.sh does not configure manual Developer ID signing"
require_source 'verify-stable-release-signature.sh' \
    "build.sh does not validate stable signed output"
require_source 'for local and CI validation only' \
    "build.sh does not keep ad-hoc output outside public publication"
require_source 'package-electron.sh' \
    "build.sh does not use the Electron release packager"
require_source 'AV_ELECTRON_OUTPUT_DIR="$EXPORT_PATH"' \
    "build.sh does not export the Electron app through build/export"
require_source 'test-release-archive.sh' \
    "build.sh does not validate the exact Electron archive"
require_source 'release_assert_coordinates' \
    "build.sh does not enforce the canonical version/build contract"
require_source 'AgentVisor-release.zip' \
    "build.sh does not require the stable generated archive path"

if [[ ! -x "$PACKAGER_SCRIPT" ]]; then
    echo "ERROR: Electron release packager is missing or not executable" >&2
    exit 1
fi
if [[ ! -x "$ARCHIVER_SCRIPT" ]] \
    || ! grep -Fq 'create-release-archive.sh' "$PACKAGER_SCRIPT"; then
    echo "ERROR: Electron packager does not use the deterministic release archiver" >&2
    exit 1
fi
for required_source in \
    'CFBundleExecutable' \
    'Agent Visor' \
    'LSMinimumSystemVersion' \
    'NSAppleEventsUsageDescription' \
    'AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION' \
    'LICENSES.chromium.html' \
    'release_build_mode'; do
    if ! grep -Fq "$required_source" "$PACKAGER_SCRIPT"; then
        echo "ERROR: Electron packager is missing: $required_source" >&2
        exit 1
    fi
done
if ! grep -Fq 'release_validate_nested_signature' "$BUNDLE_VALIDATOR"; then
    echo "ERROR: bundle validator does not enforce nested helper signing continuity" >&2
    exit 1
fi
if ! grep -Fq 'AV_NATIVE_HELPER_TEAM_ID' "$PACKAGER_SCRIPT" \
    || ! grep -Fq 'TeamIdentifier' "$SCRIPT_DIR/build-native-helper.sh"; then
    echo "ERROR: native helper build does not enforce the requested signing team" >&2
    exit 1
fi

if [[ ! -x "$LEGACY_SCRIPT" ]]; then
    echo "ERROR: Swift rollback builder is missing or not executable" >&2
    exit 1
fi
for required_legacy_source in \
    'LEGACY_VERSION="2.6.1"' \
    'LEGACY_BUILD="53"' \
    'LEGACY_SOURCE_TAG="v2.6.1"' \
    'LEGACY_SOURCE_COMMIT="8d7bcd588dff079b3ac2abfa9dc8ec2cf5c7cd6e"' \
    'LEGACY_ARTIFACT_URL="https://github.com/824zzy/agent-visor/releases/download/v2.6.1/AgentVisor-v2.6.1.zip"' \
    'LEGACY_ARTIFACT_SHA256="676e82d217f22e723eb27b6d1b6749ab6ffc199112cf4c4a51871a1c7f6611fb"' \
    'AV_SWIFT_LEGACY_ARTIFACT_PATH' \
    'verify-stable-release-signature.sh' \
    'AgentVisor-v$LEGACY_VERSION.zip' \
    'AgentVisor-release.zip'; do
    if ! grep -Fq "$required_legacy_source" "$LEGACY_SCRIPT"; then
        echo "ERROR: Swift rollback builder is missing pinned artifact contract: $required_legacy_source" >&2
        exit 1
    fi
done
if grep -Fq 'xcodebuild' "$LEGACY_SCRIPT" || grep -Fq 'git push' "$LEGACY_SCRIPT"; then
    echo "ERROR: Swift rollback builder rebuilds or mutates a remote instead of using the public artifact" >&2
    exit 1
fi
if grep -Fq 'release_load_version_config' "$LEGACY_SCRIPT" \
    || grep -Fq 'AGENT_VISOR_MIN_MACOS' "$LEGACY_SCRIPT"; then
    echo "ERROR: Swift rollback builder is coupled to current Electron release configuration" >&2
    exit 1
fi
if ! grep -Fq 'release_load_version_config "$PROJECT_DIR"' "$SCRIPT_DIR/build-native-helper.sh"; then
    echo "ERROR: native helper builder does not source the configured minimum macOS version" >&2
    exit 1
fi

echo "Release build wiring PASS"
