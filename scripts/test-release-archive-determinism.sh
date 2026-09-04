#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVER="$SCRIPT_DIR/create-release-archive.sh"
FIXTURE="$SCRIPT_DIR/fixtures/create-release-bundle-fixture.sh"
VALIDATOR="$SCRIPT_DIR/test-release-archive.sh"
TEMP_ROOT="$(mktemp -d -t av-release-archive-determinism.XXXXXX)"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

for required_path in "$ARCHIVER" "$FIXTURE" "$VALIDATOR"; do
    if [[ ! -x "$required_path" ]]; then
        echo "ERROR: archive determinism dependency is missing: $required_path" >&2
        exit 1
    fi
done

APP_PATH="$TEMP_ROOT/Agent Visor.app"
FIRST_ZIP="$TEMP_ROOT/first.zip"
SECOND_ZIP="$TEMP_ROOT/second.zip"
"$FIXTURE" "$APP_PATH" >/dev/null
"$ARCHIVER" "$APP_PATH" "$FIRST_ZIP"
"$ARCHIVER" "$APP_PATH" "$SECOND_ZIP"

if ! cmp -s "$FIRST_ZIP" "$SECOND_ZIP"; then
    echo "ERROR: repeated archives of the same signed app are not byte-identical" >&2
    shasum -a 256 "$FIRST_ZIP" "$SECOND_ZIP" >&2
    exit 1
fi

"$VALIDATOR" "$FIRST_ZIP" >/dev/null
echo "Release archive determinism PASS: repeated archives are byte-identical and preserve the signed app contract."
