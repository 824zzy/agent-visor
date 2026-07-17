#!/bin/bash
set -euo pipefail

APP_PATH="${1:-/tmp/av-debug-build/Build/Products/Debug/Agent Visor.app}"
HELPER="$APP_PATH/Contents/Helpers/AgentVisorCodexRuntime"
PLIST="$APP_PATH/Contents/Library/LaunchAgents/com.824zzy.AgentVisor.CodexRuntime.plist"

[[ -d "$APP_PATH" ]]
[[ -x "$HELPER" ]]
[[ -f "$PLIST" ]]

plutil -lint "$PLIST" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST")" == \
    "com.824zzy.AgentVisor.CodexRuntime" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$PLIST")" == \
    "Contents/Helpers/AgentVisorCodexRuntime" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers' "$PLIST")" == \
    "com.824zzy.AgentVisor" ]]

codesign --verify --deep --strict "$APP_PATH"
codesign --verify --strict "$HELPER"
SIGNATURE_INFO="$(codesign -d --verbose=4 "$HELPER" 2>&1)"
grep -q '^Identifier=com.824zzy.AgentVisor.CodexRuntime$' <<<"$SIGNATURE_INFO"

echo "Codex runtime bundle PASS: embedded layout and signatures are valid."
