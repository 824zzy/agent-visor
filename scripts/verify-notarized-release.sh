#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-notarization.sh"

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" ]]; then
    echo "Usage: $0 /path/to/Agent\ Visor.app" >&2
    exit 2
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: app bundle not found: $APP_PATH" >&2
    exit 1
fi

stapler_status=0
stapler_output="$(xcrun stapler validate "$APP_PATH" 2>&1)" || stapler_status=$?

assessment_status=0
assessment_output="$(/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1)" || assessment_status=$?

if (( stapler_status != 0 )); then
    printf '%s\n' "$stapler_output" >&2
fi
if (( assessment_status != 0 )); then
    printf '%s\n' "$assessment_output" >&2
fi
if (( stapler_status != 0 || assessment_status != 0 )); then
    exit 1
fi

release_notarization_is_accepted "$assessment_output" "$stapler_output"
echo "Notarized release PASS"
