#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/release-version.sh"
release_load_version_config "$PROJECT_DIR"
FIXTURE="$SCRIPT_DIR/fixtures/create-release-bundle-fixture.sh"
VALIDATOR="$SCRIPT_DIR/test-release-archive.sh"
TEMP_ROOT="$(mktemp -d -t av-release-archive-negative.XXXXXX)"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

if [[ ! -x "$FIXTURE" || ! -x "$VALIDATOR" ]]; then
    echo "ERROR: release archive fixture or validator is missing" >&2
    exit 1
fi

BASE_APP="$TEMP_ROOT/base/Agent Visor.app"
BASE_ZIP="$TEMP_ROOT/base.zip"
"$FIXTURE" "$BASE_APP" >/dev/null
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noacl --keepParent \
    "$BASE_APP" "$BASE_ZIP"
"$VALIDATOR" "$BASE_ZIP" >/dev/null

reject_archive() {
    local name="$1"
    local expected="$2"
    local archive="$TEMP_ROOT/$name.zip"
    local output="$TEMP_ROOT/$name.log"
    cp "$BASE_ZIP" "$archive"

    case "$name" in
        unexpected-root-entry)
            printf 'archive junk\n' > "$TEMP_ROOT/junk.txt"
            (cd "$TEMP_ROOT" && zip -q "$archive" junk.txt)
            ;;
        metadata-junk)
            printf 'metadata\n' > "$TEMP_ROOT/.DS_Store"
            (cd "$TEMP_ROOT" && zip -q "$archive" .DS_Store)
            ;;
        absolute-entry)
            python3 - "$archive" '/tmp/agent-visor-absolute.txt' <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], 'a') as archive:
    archive.writestr(sys.argv[2], 'archive path mutation\n')
PY
            ;;
        parent-entry)
            python3 - "$archive" 'Agent Visor.app/../agent-visor-parent.txt' <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], 'a') as archive:
    archive.writestr(sys.argv[2], 'archive path mutation\n')
PY
            ;;
        missing-helper)
            MUTATED_APP="$TEMP_ROOT/missing-helper/Agent Visor.app"
            "$FIXTURE" "$MUTATED_APP" >/dev/null
            rm -rf "$MUTATED_APP/Contents/Helpers/Agent Visor Native Helper.app"
            rm -f "$archive"
            COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noacl --keepParent \
                "$MUTATED_APP" "$archive"
            ;;
        wrong-minimum-macos)
            MUTATED_APP="$TEMP_ROOT/wrong-minimum/Agent Visor.app"
            "$FIXTURE" "$MUTATED_APP" >/dev/null
            /usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 12.0' \
                "$MUTATED_APP/Contents/Info.plist"
            rm -f "$archive"
            COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noacl --keepParent \
                "$MUTATED_APP" "$archive"
            ;;
        corrupted-zip)
            printf 'not a zip archive\n' > "$archive"
            ;;
        *)
            echo "ERROR: unknown archive negative test case: $name" >&2
            exit 1
            ;;
    esac

    if "$VALIDATOR" "$archive" >"$output" 2>&1; then
        echo "ERROR: archive validator accepted $name" >&2
        cat "$output" >&2
        exit 1
    fi
    if ! grep -Fq "$expected" "$output"; then
        echo "ERROR: archive validator rejected $name for an unexpected reason" >&2
        echo "Expected: $expected" >&2
        cat "$output" >&2
        exit 1
    fi
}

reject_archive unexpected-root-entry "unexpected top-level entry"
reject_archive metadata-junk "metadata junk"
reject_archive missing-helper "release helper must have a notification bundle identity"
reject_archive absolute-entry "absolute path entry"
reject_archive parent-entry "parent path entry"
reject_archive wrong-minimum-macos "minimum macOS version must be '$AGENT_VISOR_MIN_MACOS'"
reject_archive corrupted-zip "failed ZIP integrity verification"

echo "Release archive negative tests PASS: unexpected entries, metadata junk, missing helper, bad metadata, and corrupted ZIPs were rejected."
