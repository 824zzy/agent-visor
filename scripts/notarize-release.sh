#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_PATH="${1:-$PROJECT_DIR/build/export/Agent Visor.app}"
NOTARY_PROFILE="${AV_NOTARY_KEYCHAIN_PROFILE:-}"
TEMP_ROOT=""

cleanup() {
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
        rm -rf "$TEMP_ROOT"
    fi
}
trap cleanup EXIT

if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "ERROR: AV_NOTARY_KEYCHAIN_PROFILE is required." >&2
    echo "       Store credentials with xcrun notarytool store-credentials, then" >&2
    echo "       set AV_NOTARY_KEYCHAIN_PROFILE to that profile name." >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: app bundle not found: $APP_PATH" >&2
    exit 1
fi

"$SCRIPT_DIR/verify-stable-release-signature.sh" "$APP_PATH"

TEMP_ROOT="$(mktemp -d -t av-notarize.XXXXXX)"
SUBMISSION_ZIP="$TEMP_ROOT/AgentVisor-notarization.zip"
RESULT_JSON="$TEMP_ROOT/notary-result.json"

COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc "$APP_PATH" "$SUBMISSION_ZIP"

echo "Submitting Agent Visor to Apple's notary service..."
if ! xcrun notarytool submit "$SUBMISSION_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json > "$RESULT_JSON"; then
    cat "$RESULT_JSON" >&2
    exit 1
fi
cat "$RESULT_JSON"

NOTARY_STATUS="$(plutil -extract status raw "$RESULT_JSON" 2>/dev/null || true)"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "ERROR: Apple notarization status is '${NOTARY_STATUS:-unknown}', expected Accepted." >&2
    exit 1
fi

xcrun stapler staple "$APP_PATH"
"$SCRIPT_DIR/verify-stable-release-signature.sh" "$APP_PATH"
"$SCRIPT_DIR/verify-notarized-release.sh" "$APP_PATH"

echo "Notarized and stapled release candidate: $APP_PATH"
