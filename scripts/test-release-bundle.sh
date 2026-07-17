#!/bin/bash
set -euo pipefail

APP_PATH="${1:?release app path is required}"
HELPER="$APP_PATH/Contents/Helpers/AgentVisorCodexRuntime"
LAUNCH_AGENT="$APP_PATH/Contents/Library/LaunchAgents/com.824zzy.AgentVisor.CodexRuntime.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/Agent Visor"

[[ -d "$APP_PATH" ]]
[[ "$APP_PATH" == *.app ]]
[[ -x "$EXECUTABLE" ]]
[[ "$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist"
)" == "com.824zzy.AgentVisor" ]]
[[ "$(
    /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PATH/Contents/Info.plist"
)" == "14.0" ]]

FILE_INFO="$(file "$EXECUTABLE")"
[[ "$FILE_INFO" == *"Mach-O 64-bit executable arm64"* ]]

[[ ! -e "$HELPER" ]]
[[ ! -e "$LAUNCH_AGENT" ]]

codesign --verify --deep --strict "$APP_PATH"
SIGNING_INFO="$(codesign -dvvv "$APP_PATH" 2>&1)"
grep -Eq 'flags=.*runtime' <<<"$SIGNING_INFO"
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null)"
if grep -q 'com.apple.security.get-task-allow' <<<"$ENTITLEMENTS"; then
    echo "ERROR: release app contains com.apple.security.get-task-allow" >&2
    exit 1
fi

echo "Release bundle PASS: identity, distribution boundary, entitlements, and signatures are valid."
