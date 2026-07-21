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
"$SCRIPT_DIR/test-release-bundle.sh" "$EXTRACTED_APP"
SIGNING_INFO="$(codesign -dvvv "$EXTRACTED_APP" 2>&1)"
DISTRIBUTION_MODE="$(release_distribution_mode "$SIGNING_INFO")"

case "$DISTRIBUTION_MODE" in
    ad-hoc)
        "$SCRIPT_DIR/test-homebrew-resign.sh" "$EXTRACTED_APP"
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
