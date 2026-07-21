#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build.sh"

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

echo "Release build wiring PASS"
