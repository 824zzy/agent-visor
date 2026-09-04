#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEMP_ROOT="$(mktemp -d -t av-release-swift-legacy.XXXXXX)"
ARTIFACT_URL="https://github.com/824zzy/agent-visor/releases/download/v2.6.1/AgentVisor-v2.6.1.zip"
EXPECTED_SHA256="676e82d217f22e723eb27b6d1b6749ab6ffc199112cf4c4a51871a1c7f6611fb"
EXPECTED_VERSION="2.6.1"
EXPECTED_BUILD="53"
BEFORE_STATUS=""

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required for the Swift rollback artifact test" >&2
    exit 1
fi

curl --fail --location --silent --show-error --retry 3 \
    --output "$TEMP_ROOT/public.zip" "$ARTIFACT_URL"
ACTUAL_SHA256="$(shasum -a 256 "$TEMP_ROOT/public.zip" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "ERROR: downloaded public Swift rollback artifact checksum changed" >&2
    echo "       expected: $EXPECTED_SHA256" >&2
    echo "       actual:   $ACTUAL_SHA256" >&2
    exit 1
fi

BEFORE_STATUS="$(git -C "$PROJECT_DIR" status --short)"
OUTPUT_ROOT="$TEMP_ROOT/output"
OUTPUT_PATH="$OUTPUT_ROOT/export"
if ! AV_SWIFT_LEGACY_ARTIFACT_PATH="$TEMP_ROOT/public.zip" \
    AV_SWIFT_LEGACY_BUILD_DIR="$OUTPUT_ROOT" \
    "$SCRIPT_DIR/build-swift-legacy.sh" > "$TEMP_ROOT/build.log" 2>&1; then
    echo "ERROR: pinned Swift rollback artifact export failed" >&2
    cat "$TEMP_ROOT/build.log" >&2
    exit 1
fi

for required_output in \
    "$OUTPUT_PATH/Agent Visor.app" \
    "$OUTPUT_PATH/AgentVisor-v$EXPECTED_VERSION.zip" \
    "$OUTPUT_PATH/AgentVisor-release.zip" \
    "$OUTPUT_PATH/AgentVisor-v$EXPECTED_VERSION.zip.sha256" \
    "$OUTPUT_PATH/AgentVisor-release.zip.sha256"; do
    if [[ ! -e "$required_output" ]]; then
        echo "ERROR: Swift rollback export is missing: $required_output" >&2
        cat "$TEMP_ROOT/build.log" >&2
        exit 1
    fi
done

if ! cmp -s "$TEMP_ROOT/public.zip" "$OUTPUT_PATH/AgentVisor-v$EXPECTED_VERSION.zip" \
    || ! cmp -s "$TEMP_ROOT/public.zip" "$OUTPUT_PATH/AgentVisor-release.zip"; then
    echo "ERROR: rollback output ZIPs are not byte-for-byte copies of public v$EXPECTED_VERSION" >&2
    exit 1
fi
for archive in \
    "$OUTPUT_PATH/AgentVisor-v$EXPECTED_VERSION.zip" \
    "$OUTPUT_PATH/AgentVisor-release.zip"; do
    archive_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$archive_sha" != "$EXPECTED_SHA256" ]]; then
        echo "ERROR: rollback output checksum mismatch: $archive" >&2
        exit 1
    fi
done

APP_PATH="$OUTPUT_PATH/Agent Visor.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
if [[ "$APP_VERSION" != "$EXPECTED_VERSION" || "$APP_BUILD" != "$EXPECTED_BUILD" ]]; then
    echo "ERROR: rollback app coordinates changed: $APP_VERSION (build $APP_BUILD)" >&2
    exit 1
fi

if ! codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    echo "ERROR: exported Swift rollback app failed strict signature verification" >&2
    exit 1
fi

AFTER_STATUS="$(git -C "$PROJECT_DIR" status --short)"
if [[ "$AFTER_STATUS" != "$BEFORE_STATUS" ]]; then
    echo "ERROR: rollback export changed the shared worktree" >&2
    diff -u <(printf '%s\n' "$BEFORE_STATUS") <(printf '%s\n' "$AFTER_STATUS") >&2 || true
    exit 1
fi

# A local override is a test seam, but it must still be pinned to the exact
# public checksum. This negative case prevents accidental use of a current or
# otherwise substituted checkout artifact.
cp "$TEMP_ROOT/public.zip" "$TEMP_ROOT/tampered.zip"
printf '%s' 'tampered' >> "$TEMP_ROOT/tampered.zip"
if AV_SWIFT_LEGACY_ARTIFACT_PATH="$TEMP_ROOT/tampered.zip" \
    AV_SWIFT_LEGACY_BUILD_DIR="$TEMP_ROOT/tampered-output" \
    "$SCRIPT_DIR/build-swift-legacy.sh" > "$TEMP_ROOT/tampered.log" 2>&1; then
    echo "ERROR: tampered Swift rollback artifact was accepted" >&2
    exit 1
fi
if ! grep -Fq 'checksum mismatch' "$TEMP_ROOT/tampered.log"; then
    echo "ERROR: tampered rollback artifact did not fail at checksum verification" >&2
    cat "$TEMP_ROOT/tampered.log" >&2
    exit 1
fi

echo "Swift rollback artifact PASS: exact public v$EXPECTED_VERSION bytes/signature exported without worktree or remote mutation."
