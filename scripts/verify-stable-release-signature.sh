#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-signing.sh"

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" ]]; then
    echo "Usage: $0 /path/to/Agent\ Visor.app" >&2
    exit 2
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: app bundle not found: $APP_PATH" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP_PATH"

signing_info="$(codesign -dvvv "$APP_PATH" 2>&1)"
designated_requirement="$(codesign -d -r- "$APP_PATH" 2>&1)"

release_signature_is_stable "$signing_info" "$designated_requirement"
echo "Stable release signature PASS"
