#!/bin/bash
# Local debug build with a stable code-signing identity, so macOS TCC
# permission grants (AppleScript control of iTerm/Ghostty, etc.) survive
# across rebuilds.
#
# Without this script, debug builds get an ad-hoc signature whose
# designated requirement includes the binary cdhash, which changes every
# build. TCC sees a different app every time and re-prompts on the next
# AppleScript call. With a stable self-signed cert, the designated
# requirement is keyed on the cert's hash and is constant across rebuilds.
#
# First-time setup: scripts/dev-sign-setup.sh creates the cert.
#
# Env overrides:
#   AV_DEV_CERT   — keychain identity name (default: "AgentVisor Dev")
#   AV_DERIVED    — derived-data path (default: /tmp/av-debug-build)
#   AV_DEV_INSTALL_DIR — stable app destination (default: /Applications)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CERT_NAME="${AV_DEV_CERT:-AgentVisor Dev}"
DERIVED="${AV_DERIVED:-/tmp/av-debug-build}"
INSTALL_DIR="${AV_DEV_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/Agent Visor Dev.app"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

cd "$PROJECT_DIR"

# Detect the stable cert. Look for the exact name in quotes so a partial
# match (e.g., "AgentVisor Dev Old") doesn't false-positive.
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    SIGN_IDENTITY="$CERT_NAME"
    echo "==> Building with stable signing identity: $CERT_NAME"
    echo "==> Derived data: $DERIVED"
    xcodebuild \
        -project AgentVisor.xcodeproj \
        -scheme AgentVisor \
        -configuration Debug \
        -derivedDataPath "$DERIVED" \
        -onlyUsePackageVersionsFromResolvedFile \
        CODE_SIGN_IDENTITY="$CERT_NAME" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGNING_REQUIRED=YES \
        build
else
    SIGN_IDENTITY="-"
    echo "==> Cert '$CERT_NAME' not found in login keychain."
    echo "==> Run scripts/dev-sign-setup.sh once to create it."
    echo "==> Falling back to ad-hoc signing (TCC will re-prompt on every rebuild)."
    xcodebuild \
        -project AgentVisor.xcodeproj \
        -scheme AgentVisor \
        -configuration Debug \
        -derivedDataPath "$DERIVED" \
        -onlyUsePackageVersionsFromResolvedFile \
        build
fi

APP_PATH="$DERIVED/Build/Products/Debug/Agent Visor Dev.app"
if ! "$SCRIPT_DIR/test-codex-runtime-bundle.sh" "$APP_PATH"; then
    echo "==> Re-sealing app after incremental resource updates"
    codesign --force --sign "$SIGN_IDENTITY" \
        --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
        --timestamp=none \
        "$APP_PATH"
    "$SCRIPT_DIR/test-codex-runtime-bundle.sh" "$APP_PATH"
fi

echo
echo "==> Built: $APP_PATH"

# Launching from DerivedData or /tmp makes the development identity difficult
# to locate in macOS permission choosers. Deploy one stable, visible copy and
# always run that copy so TCC, LaunchServices, and the user agree on its path.
STAGED_APP="$INSTALL_DIR/.Agent Visor Dev.installing.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> Deploying: $INSTALLED_APP"
mkdir -p "$INSTALL_DIR"
pkill -x "Agent Visor Dev" 2>/dev/null || true
for _ in {1..50}; do
    if ! pgrep -x "Agent Visor Dev" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
if pgrep -x "Agent Visor Dev" >/dev/null 2>&1; then
    echo "ERROR: Agent Visor Dev did not quit before deployment." >&2
    exit 1
fi

rm -rf "$STAGED_APP"
ditto "$APP_PATH" "$STAGED_APP"
"$SCRIPT_DIR/test-codex-runtime-bundle.sh" "$STAGED_APP"
rm -rf "$INSTALLED_APP"
mv "$STAGED_APP" "$INSTALLED_APP"
"$LSREGISTER" -u "$APP_PATH" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$INSTALLED_APP"

echo "==> Launching: $INSTALLED_APP"
open -n "$INSTALLED_APP"
