#!/bin/bash
set -euo pipefail

ZIP_PATH="${1:?release zip path is required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
"$SCRIPT_DIR/test-homebrew-resign.sh" "$EXTRACTED_APP"

echo "Release archive PASS: contents, signatures, and installation path are valid."
