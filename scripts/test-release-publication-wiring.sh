#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SCRIPT="$SCRIPT_DIR/create-release.sh"

first_line() {
    local pattern="$1"
    grep -nF "$pattern" "$RELEASE_SCRIPT" | head -1 | cut -d: -f1
}

require_source() {
    local pattern="$1"
    local message="$2"
    if ! grep -Fq "$pattern" "$RELEASE_SCRIPT"; then
        echo "ERROR: $message" >&2
        exit 1
    fi
}

require_source 'source "$SCRIPT_DIR/lib/release-publication.sh"' \
    "create-release.sh does not use publication policy"
require_source 'validate-release-candidate.sh' \
    "create-release.sh does not validate the signed and notarized candidate"

validation_line="$(first_line '"$SCRIPT_DIR/validate-release-candidate.sh"')"
zip_line="$(first_line '=== Step 2: Creating Release ZIP ===')"
cask_line="$(first_line '=== Step 3: Updating Local Casks ===')"
appcast_line="$(first_line '=== Step 7: Updating Appcast ===')"

if [[ -z "$validation_line" || -z "$zip_line" || -z "$cask_line" || -z "$appcast_line" ]]; then
    echo "ERROR: could not locate publication ordering markers" >&2
    exit 1
fi

if (( validation_line >= zip_line || validation_line >= cask_line || validation_line >= appcast_line )); then
    echo "ERROR: release validation runs after local publication artifacts are mutated" >&2
    exit 1
fi

if grep -Fq 'AV_RELEASE_DRY_RUN_ALLOW_UNSTABLE' "$RELEASE_SCRIPT"; then
    echo "ERROR: create-release.sh can bypass candidate validation instead of validating both modes" >&2
    exit 1
fi

echo "Release publication wiring PASS"
