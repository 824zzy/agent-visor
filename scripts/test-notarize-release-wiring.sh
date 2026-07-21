#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTARIZE_SCRIPT="$SCRIPT_DIR/notarize-release.sh"

if [[ ! -x "$NOTARIZE_SCRIPT" ]]; then
    echo "ERROR: notarization command is missing" >&2
    exit 1
fi

require_source() {
    local pattern="$1"
    local message="$2"
    if ! grep -Fq -- "$pattern" "$NOTARIZE_SCRIPT"; then
        echo "ERROR: $message" >&2
        exit 1
    fi
}

require_source 'verify-stable-release-signature.sh' \
    "notarization does not validate the Developer ID signature first"
require_source 'AV_NOTARY_KEYCHAIN_PROFILE' \
    "notarization does not require an explicit keychain profile"
require_source 'notarytool submit' \
    "notarization does not submit to Apple's notary service"
require_source '--wait' \
    "notarization does not wait for Apple's decision"
require_source 'stapler staple' \
    "notarization does not staple the accepted ticket"
require_source 'verify-notarized-release.sh' \
    "notarization does not validate the final stapled app"

echo "Notarize release wiring PASS"
