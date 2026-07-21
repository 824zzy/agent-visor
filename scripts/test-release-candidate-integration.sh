#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_ROOT="$(mktemp -d -t av-candidate-policy.XXXXXX)"
APP_PATH="$TEMP_ROOT/Agent Visor.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/Agent Visor"
CASK_PATH="$TEMP_ROOT/agent-visor.rb"
SAFE_CASK_PATH="$TEMP_ROOT/signed-agent-visor.rb"
ENTITLEMENTS_PATH="$TEMP_ROOT/AgentVisor.entitlements"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$APP_PATH/Contents/MacOS"
printf 'int main(void) { return 0; }\n' > "$TEMP_ROOT/main.c"
xcrun clang -arch arm64 "$TEMP_ROOT/main.c" -o "$EXECUTABLE"
plutil -create xml1 "$APP_PATH/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.824zzy.AgentVisor "$APP_PATH/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 14.0 "$APP_PATH/Contents/Info.plist"
plutil -create xml1 "$ENTITLEMENTS_PATH"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool false' "$ENTITLEMENTS_PATH"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$ENTITLEMENTS_PATH"
codesign --force --options runtime --entitlements "$ENTITLEMENTS_PATH" --sign - "$APP_PATH"
printf 'cask "agent-visor" do\n  app "Agent Visor.app"\n  postflight do\n    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine"]\n    system_command "/usr/bin/codesign", args: ["--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements,flags"]\n  end\nend\n' > "$CASK_PATH"
printf 'cask "agent-visor" do\n  app "Agent Visor.app"\nend\n' > "$SAFE_CASK_PATH"

if [[ ! -x "$SCRIPT_DIR/validate-release-candidate.sh" ]]; then
    echo "ERROR: release-candidate validator is missing" >&2
    exit 1
fi

"$SCRIPT_DIR/validate-release-candidate.sh" "$APP_PATH" "$CASK_PATH" >/dev/null

set +e
"$SCRIPT_DIR/validate-release-candidate.sh" "$APP_PATH" "$SAFE_CASK_PATH" >/dev/null 2>&1
SAFE_CASK_STATUS=$?
set -e
if (( SAFE_CASK_STATUS == 0 )); then
    echo "ERROR: ad-hoc publication accepted a cask that cannot recover from quarantine" >&2
    exit 1
fi

echo "Release candidate integration PASS"
