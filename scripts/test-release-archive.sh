#!/bin/bash
set -euo pipefail

ZIP_PATH="${1:?release zip path is required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-publication.sh"
TEMP_ROOT="$(mktemp -d -t av-release-archive.XXXXXX)"
EXTRACT_ROOT="$TEMP_ROOT/extracted"
EXTRACTED_APP="$EXTRACT_ROOT/Agent Visor.app"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

[[ -f "$ZIP_PATH" ]]
ARCHIVE_LIST="$(unzip -Z1 "$ZIP_PATH")"
if grep -Eq '(^|/)__MACOSX(/|$)|(^|/)\.DS_Store$|(^|/)\._[^/]+$' <<<"$ARCHIVE_LIST"; then
    echo "ERROR: release archive contains macOS metadata junk" >&2
    exit 1
fi

mkdir -p "$EXTRACT_ROOT"
ditto -x -k "$ZIP_PATH" "$EXTRACT_ROOT"
[[ -d "$EXTRACTED_APP" ]]
NOTIFICATION_HELPER="$EXTRACTED_APP/Contents/Helpers/Agent Visor Native Helper.app"
[[ -x "$NOTIFICATION_HELPER/Contents/MacOS/AgentVisorNativeHelper" ]] || {
    echo "ERROR: release helper must have a notification bundle identity" >&2
    exit 1
}
[[ "$(plutil -extract CFBundleIdentifier raw "$NOTIFICATION_HELPER/Contents/Info.plist")" == "AgentVisorNativeHelper" ]] || {
    echo "ERROR: release helper changed its stable signed identity" >&2
    exit 1
}
[[ "$(plutil -extract NSUserNotificationAlertStyle raw "$NOTIFICATION_HELPER/Contents/Info.plist")" == "alert" ]] || {
    echo "ERROR: release helper does not own macOS notification alerts" >&2
    exit 1
}
[[ "$(plutil -extract CFBundleIconFile raw "$NOTIFICATION_HELPER/Contents/Info.plist")" == "AgentVisor.icns" \
    && -f "$NOTIFICATION_HELPER/Contents/Resources/AgentVisor.icns" ]] || {
    echo "ERROR: release helper notifications do not use the Agent Visor icon" >&2
    exit 1
}
[[ ! -e "$EXTRACTED_APP/Contents/MacOS/AgentVisorNativeHelper" ]] || {
    echo "ERROR: release helper has no notification bundle identity" >&2
    exit 1
}
if plutil -extract NSUserNotificationAlertStyle raw "$EXTRACTED_APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "ERROR: Electron must not register a second notification client" >&2
    exit 1
fi
for integration in \
    agent-visor-state.py \
    agent-visor-codex-state.py \
    agent-visor-state-auggie.sh \
    agent-visor-pi.ts.txt; do
    [[ -f "$EXTRACTED_APP/Contents/Resources/AgentIntegrations/$integration" ]] || {
        echo "ERROR: release archive is missing $integration" >&2
        exit 1
    }
done
"$SCRIPT_DIR/test-release-bundle.sh" "$EXTRACTED_APP"
SIGNING_INFO="$(codesign -dvvv "$EXTRACTED_APP" 2>&1)"
DISTRIBUTION_MODE="$(release_distribution_mode "$SIGNING_INFO")"

case "$DISTRIBUTION_MODE" in
    ad-hoc)
        "$SCRIPT_DIR/test-homebrew-resign.sh" "$EXTRACTED_APP"
        ;;
    self-signed)
        "$SCRIPT_DIR/verify-stable-release-signature.sh" "$EXTRACTED_APP"
        ;;
    developer-id)
        "$SCRIPT_DIR/verify-stable-release-signature.sh" "$EXTRACTED_APP"
        "$SCRIPT_DIR/verify-notarized-release.sh" "$EXTRACTED_APP"
        ;;
    *)
        echo "ERROR: unsupported archive distribution mode: $DISTRIBUTION_MODE" >&2
        exit 1
        ;;
esac

echo "Release archive PASS: contents and $DISTRIBUTION_MODE distribution contract are valid."
