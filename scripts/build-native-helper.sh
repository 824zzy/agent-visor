#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_PATH="$PROJECT_DIR/AgentVisorCore"
OUTPUT_DIR="${AV_NATIVE_HELPER_OUTPUT_DIR:-$PROJECT_DIR/build/native-helper}"
IDENTITY="${AV_NATIVE_HELPER_SIGN_IDENTITY:-AgentVisor Dev}"
KEYCHAIN="${AV_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | grep -Fq "\"$IDENTITY\""; then
    echo "ERROR: native helper signing identity is unavailable: $IDENTITY" >&2
    exit 1
fi

swift build --package-path "$PACKAGE_PATH" -c release --product AgentVisorNativeHelper
BIN_DIR="$(swift build --package-path "$PACKAGE_PATH" -c release --show-bin-path)"
mkdir -p "$OUTPUT_DIR"
cp "$BIN_DIR/AgentVisorNativeHelper" "$OUTPUT_DIR/AgentVisorNativeHelper"
codesign --force --sign "$IDENTITY" "$OUTPUT_DIR/AgentVisorNativeHelper"
codesign --verify --strict "$OUTPUT_DIR/AgentVisorNativeHelper"

echo "Signed native helper: $OUTPUT_DIR/AgentVisorNativeHelper"
