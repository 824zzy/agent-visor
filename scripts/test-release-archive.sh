#!/bin/bash
set -euo pipefail

ZIP_PATH="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

if [[ -z "$ZIP_PATH" ]]; then
    fail "release zip path is required"
fi
if [[ ! -f "$ZIP_PATH" ]]; then
    fail "release archive is missing: $ZIP_PATH"
fi

source "$SCRIPT_DIR/lib/release-publication.sh"
source "$SCRIPT_DIR/lib/release-version.sh"
release_load_version_config "$PROJECT_DIR"
VERSION="$(release_product_version "$PROJECT_DIR")"

TEMP_ROOT="$(mktemp -d -t av-release-archive.XXXXXX)"
EXTRACT_ROOT="$TEMP_ROOT/extracted"
EXTRACTED_APP="$EXTRACT_ROOT/Agent Visor.app"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

if ! unzip -tq "$ZIP_PATH" >/dev/null 2>&1; then
    fail "release archive failed ZIP integrity verification"
fi
if ! ARCHIVE_LIST="$(unzip -Z1 "$ZIP_PATH" 2>&1)"; then
    fail "release archive contents could not be listed"
fi
if [[ -z "$ARCHIVE_LIST" ]]; then
    fail "release archive is empty"
fi

if grep -Eq '(^|/)__MACOSX(/|$)|(^|/)\.DS_Store$|(^|/)\._[^/]+$' <<<"$ARCHIVE_LIST"; then
    fail "release archive contains macOS metadata junk"
fi

while IFS= read -r entry; do
    if [[ -z "$entry" ]]; then
        continue
    fi
    if [[ "$entry" == /* || "$entry" =~ ^[[:alpha:]]:[/\\] ]]; then
        fail "release archive contains an absolute path entry: $entry"
    fi
    IFS='/' read -r -a entry_components <<<"$entry"
    for component in "${entry_components[@]}"; do
        if [[ "$component" == ".." ]]; then
            fail "release archive contains a parent path entry: $entry"
        fi
    done
    case "$entry" in
        "Agent Visor.app"|"Agent Visor.app/"*)
            ;;
        *)
            fail "release archive contains an unexpected top-level entry: $entry"
            ;;
    esac
done <<<"$ARCHIVE_LIST"

mkdir -p "$EXTRACT_ROOT"
if ! ditto -x -k "$ZIP_PATH" "$EXTRACT_ROOT"; then
    fail "release archive could not be extracted"
fi
if [[ ! -d "$EXTRACTED_APP" ]]; then
    fail "release archive does not contain Agent Visor.app"
fi

ARCHIVE_APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$EXTRACTED_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$ARCHIVE_APP_VERSION" != "$VERSION" ]]; then
    fail "release archive app version does not match $VERSION"
fi

# Keep the helper checks close to the archive boundary. The bundle verifier
# repeats them so a caller that validates only the extracted app gets the same
# failure behavior.
NOTIFICATION_HELPER="$EXTRACTED_APP/Contents/Helpers/Agent Visor Native Helper.app"
HELPER_INFO="$NOTIFICATION_HELPER/Contents/Info.plist"
HELPER_EXECUTABLE="$NOTIFICATION_HELPER/Contents/MacOS/AgentVisorNativeHelper"
if [[ ! -x "$HELPER_EXECUTABLE" ]]; then
    fail "release helper must have a notification bundle identity"
fi
if [[ "$(plutil -extract CFBundleIdentifier raw "$HELPER_INFO" 2>/dev/null || true)" != "AgentVisorNativeHelper" ]]; then
    fail "release helper changed its stable signed identity"
fi
if [[ "$(plutil -extract NSUserNotificationAlertStyle raw "$HELPER_INFO" 2>/dev/null || true)" != "alert" ]]; then
    fail "release helper does not own macOS notification alerts"
fi
if [[ "$(plutil -extract CFBundleIconFile raw "$HELPER_INFO" 2>/dev/null || true)" != "AgentVisor.icns" \
    || ! -f "$NOTIFICATION_HELPER/Contents/Resources/AgentVisor.icns" ]]; then
    fail "release helper notifications do not use the Agent Visor icon"
fi
if [[ -e "$EXTRACTED_APP/Contents/MacOS/AgentVisorNativeHelper" ]]; then
    fail "release helper has no notification bundle identity"
fi
if /usr/libexec/PlistBuddy -c 'Print :NSUserNotificationAlertStyle' \
    "$EXTRACTED_APP/Contents/Info.plist" >/dev/null 2>&1; then
    fail "Electron must not register a second notification client"
fi

for integration in \
    agent-visor-state.py \
    agent-visor-codex-state.py \
    agent-visor-state-auggie.sh \
    agent-visor-pi.ts.txt; do
    if [[ ! -f "$EXTRACTED_APP/Contents/Resources/AgentIntegrations/$integration" ]]; then
        fail "release archive is missing $integration"
    fi
done

"$SCRIPT_DIR/test-release-bundle.sh" "$EXTRACTED_APP"
if ! SIGNING_INFO="$(codesign -dvvv "$EXTRACTED_APP" 2>&1)"; then
    fail "release archive app signature could not be inspected"
fi
if ! DISTRIBUTION_MODE="$(release_distribution_mode "$SIGNING_INFO")"; then
    fail "release archive has an unsupported signing identity"
fi

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
        fail "unsupported archive distribution mode: $DISTRIBUTION_MODE"
        ;;
esac

echo "Release archive PASS: exact contents, notices, helper, and $DISTRIBUTION_MODE distribution contract are valid."
