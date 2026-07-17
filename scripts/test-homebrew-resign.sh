#!/bin/bash
set -euo pipefail

APP_PATH="${1:?release app path is required}"
TEMP_ROOT="$(mktemp -d -t av-homebrew-resign.XXXXXX)"
INSTALLED_APP="$TEMP_ROOT/Agent Visor.app"
ENTITLEMENTS="$TEMP_ROOT/entitlements.plist"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

ditto "$APP_PATH" "$INSTALLED_APP"
codesign --force --deep --sign - \
    --preserve-metadata=entitlements,flags \
    "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"
codesign -d --entitlements :- "$INSTALLED_APP" > "$ENTITLEMENTS" 2>/dev/null

[[ "$(
    /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS"
)" == "false" ]]
[[ "$(
    /usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$ENTITLEMENTS"
)" == "true" ]]
if grep -q 'com.apple.security.get-task-allow' "$ENTITLEMENTS"; then
    echo "ERROR: Homebrew re-sign introduced com.apple.security.get-task-allow" >&2
    exit 1
fi

echo "Homebrew re-sign PASS: signature and release entitlements are preserved."
