#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-identity-continuity.sh"

if (( $# != 2 )); then
    echo "Usage: $0 /path/to/first/Agent\ Visor.app /path/to/second/Agent\ Visor.app" >&2
    exit 2
fi

FIRST_APP="$1"
SECOND_APP="$2"

for app_path in "$FIRST_APP" "$SECOND_APP"; do
    if [[ ! -d "$app_path" ]]; then
        echo "ERROR: app bundle not found: $app_path" >&2
        exit 1
    fi
    "$SCRIPT_DIR/verify-stable-release-signature.sh" "$app_path" >/dev/null
done

executable_hash() {
    local app_path="$1"
    local executable_name
    executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")"
    shasum -a 256 "$app_path/Contents/MacOS/$executable_name" | awk '{print $1}'
}

designated_requirement() {
    codesign -d -r- "$1" 2>&1 | sed -n '/^designated =>/p'
}

FIRST_HASH="$(executable_hash "$FIRST_APP")"
SECOND_HASH="$(executable_hash "$SECOND_APP")"
FIRST_REQUIREMENT="$(designated_requirement "$FIRST_APP")"
SECOND_REQUIREMENT="$(designated_requirement "$SECOND_APP")"

release_identity_is_continuous \
    "$FIRST_HASH" \
    "$SECOND_HASH" \
    "$FIRST_REQUIREMENT" \
    "$SECOND_REQUIREMENT"

echo "Release identity continuity PASS"
echo "First executable:  $FIRST_HASH"
echo "Second executable: $SECOND_HASH"
echo "$FIRST_REQUIREMENT"
