#!/bin/bash
set -euo pipefail

APP_PATH="${1:-/tmp/av-debug-build/Build/Products/Debug/Agent Visor Dev.app}"
INFO="$APP_PATH/Contents/Info.plist"
HELPER="$APP_PATH/Contents/Helpers/AgentVisorDevCodexRuntime"
PLIST="$APP_PATH/Contents/Library/LaunchAgents/com.824zzy.AgentVisor.Dev.CodexRuntime.plist"

[[ -d "$APP_PATH" ]]
[[ -f "$INFO" ]]
[[ -x "$HELPER" ]]
[[ -f "$PLIST" ]]

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO")" == \
    "Agent Visor Dev" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == \
    "com.824zzy.AgentVisor.Dev" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO")" == \
    "AppIconDev" ]]

plutil -lint "$PLIST" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST")" == \
    "com.824zzy.AgentVisor.Dev.CodexRuntime" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$PLIST")" == \
    "Contents/Helpers/AgentVisorDevCodexRuntime" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers' "$PLIST")" == \
    "com.824zzy.AgentVisor.Dev" ]]

codesign --verify --deep --strict "$APP_PATH"
codesign --verify --strict "$HELPER"
APP_SIGNATURE_INFO="$(codesign -d --verbose=4 "$APP_PATH" 2>&1)"
grep -q '^Identifier=com.824zzy.AgentVisor.Dev$' <<<"$APP_SIGNATURE_INFO"
SIGNATURE_INFO="$(codesign -d --verbose=4 "$HELPER" 2>&1)"
grep -q '^Identifier=com.824zzy.AgentVisor.Dev.CodexRuntime$' <<<"$SIGNATURE_INFO"

echo "Codex runtime bundle PASS: embedded layout and signatures are valid."
