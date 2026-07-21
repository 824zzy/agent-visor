#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_ROOT="$(mktemp -d -t av-notarization-policy.XXXXXX)"
APP_PATH="$TEMP_ROOT/Agent Visor.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/Agent Visor"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$APP_PATH/Contents/MacOS"
printf '#!/bin/sh\nexit 0\n' > "$EXECUTABLE"
chmod +x "$EXECUTABLE"
plutil -create xml1 "$APP_PATH/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.824zzy.AgentVisor "$APP_PATH/Contents/Info.plist"
codesign --force --sign - "$APP_PATH"

if [[ ! -x "$SCRIPT_DIR/verify-notarized-release.sh" ]]; then
    echo "ERROR: notarization validator is missing" >&2
    exit 1
fi

if "$SCRIPT_DIR/verify-notarized-release.sh" "$APP_PATH" >/dev/null 2>&1; then
    echo "ERROR: notarization validator accepted an unstapled app" >&2
    exit 1
fi

echo "Release notarization integration PASS"
