#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/release-version.sh"
release_load_version_config "$PROJECT_DIR"
FIXTURE="$SCRIPT_DIR/fixtures/create-release-bundle-fixture.sh"
VALIDATOR="$SCRIPT_DIR/test-release-bundle.sh"
TEMP_ROOT="$(mktemp -d -t av-release-bundle-negative.XXXXXX)"

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

if [[ ! -x "$FIXTURE" || ! -x "$VALIDATOR" ]]; then
    echo "ERROR: release bundle fixture or validator is missing" >&2
    exit 1
fi

BASE_APP="$TEMP_ROOT/base/Agent Visor.app"
"$FIXTURE" "$BASE_APP" >/dev/null
"$VALIDATOR" "$BASE_APP" >/dev/null

reject_case() {
    local name="$1"
    local expected="$2"
    local candidate="$TEMP_ROOT/$name/Agent Visor.app"
    local output="$TEMP_ROOT/$name.log"
    mkdir -p "$(dirname "$candidate")"

    if [[ "$name" == "wrong-architecture" ]]; then
        AV_FIXTURE_ARCH=x86_64 "$FIXTURE" "$candidate" >/dev/null
    else
        "$FIXTURE" "$candidate" >/dev/null
    fi

    case "$name" in
        missing-executable)
            rm -f "$candidate/Contents/MacOS/Agent Visor"
            ;;
        wrong-executable-name)
            /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Electron' \
                "$candidate/Contents/Info.plist"
            ;;
        wrong-architecture)
            ;;
        wrong-minimum-macos)
            /usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 12.0' \
                "$candidate/Contents/Info.plist"
            ;;
        wrong-bundle-id)
            /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.AgentVisor' \
                "$candidate/Contents/Info.plist"
            ;;
        missing-apple-events-description)
            /usr/libexec/PlistBuddy -c 'Delete :NSAppleEventsUsageDescription' \
                "$candidate/Contents/Info.plist"
            ;;
        wrong-apple-events-description)
            /usr/libexec/PlistBuddy -c 'Set :NSAppleEventsUsageDescription Wrong description' \
                "$candidate/Contents/Info.plist"
            ;;
        missing-helper-apple-events-description)
            /usr/libexec/PlistBuddy -c 'Delete :NSAppleEventsUsageDescription' \
                "$candidate/Contents/Helpers/Agent Visor Native Helper.app/Contents/Info.plist"
            ;;
        wrong-helper-apple-events-description)
            /usr/libexec/PlistBuddy -c 'Set :NSAppleEventsUsageDescription Wrong description' \
                "$candidate/Contents/Helpers/Agent Visor Native Helper.app/Contents/Info.plist"
            ;;
        missing-electron-notice)
            rm -f "$candidate/Contents/Resources/ThirdPartyLicenses/Electron.LICENSE"
            ;;
        missing-chromium-notice)
            rm -f "$candidate/Contents/Resources/ThirdPartyLicenses/LICENSES.chromium.html"
            ;;
        missing-helper)
            rm -rf "$candidate/Contents/Helpers/Agent Visor Native Helper.app"
            ;;
        wrong-helper-identity)
            /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.Helper' \
                "$candidate/Contents/Helpers/Agent Visor Native Helper.app/Contents/Info.plist"
            ;;
        missing-renderer)
            rm -f "$candidate/Contents/Resources/app/packages/app/dist/index.html"
            ;;
        missing-integration)
            rm -f "$candidate/Contents/Resources/AgentIntegrations/agent-visor-pi.ts.txt"
            ;;
        development-helper)
            mkdir -p "$candidate/Contents/Helpers/AgentVisorDevCodexRuntime"
            ;;
        bad-entitlement)
            BAD_ENTITLEMENTS="$TEMP_ROOT/bad-entitlements.plist"
            plutil -create xml1 "$BAD_ENTITLEMENTS"
            /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool false' \
                "$BAD_ENTITLEMENTS"
            /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' \
                "$BAD_ENTITLEMENTS"
            /usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' \
                "$BAD_ENTITLEMENTS"
            codesign --force --deep --options runtime --timestamp=none \
                --entitlements "$BAD_ENTITLEMENTS" --sign - "$candidate"
            ;;
        invalid-signature)
            printf 'tampered release payload\n' >> "$candidate/Contents/MacOS/Agent Visor"
            ;;
        *)
            echo "ERROR: unknown negative test case: $name" >&2
            exit 1
            ;;
    esac

    if "$VALIDATOR" "$candidate" >"$output" 2>&1; then
        echo "ERROR: bundle validator accepted $name" >&2
        cat "$output" >&2
        exit 1
    fi
    if ! grep -Fq "$expected" "$output"; then
        echo "ERROR: bundle validator rejected $name for an unexpected reason" >&2
        echo "Expected: $expected" >&2
        cat "$output" >&2
        exit 1
    fi
}

reject_case missing-executable "Electron release executable is missing or not executable"
reject_case wrong-executable-name "bundle executable name must be 'Agent Visor'"
reject_case wrong-architecture "must be an arm64 Mach-O"
reject_case wrong-minimum-macos "minimum macOS version must be '$AGENT_VISOR_MIN_MACOS'"
reject_case wrong-bundle-id "bundle identifier must be 'com.824zzy.AgentVisor'"
reject_case missing-apple-events-description "Apple Events usage description is missing from"
reject_case wrong-apple-events-description "Apple Events usage description must be '$AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION'"
reject_case missing-helper-apple-events-description "notification helper Apple Events usage description is missing from"
reject_case wrong-helper-apple-events-description "notification helper Apple Events usage description must be '$AGENT_VISOR_APPLE_EVENTS_USAGE_DESCRIPTION'"
reject_case missing-electron-notice "Electron license notice is missing"
reject_case missing-chromium-notice "Chromium license notice is missing"
reject_case missing-helper "notification helper bundle is missing"
reject_case wrong-helper-identity "notification helper identifier must be 'AgentVisorNativeHelper'"
reject_case missing-renderer "Electron renderer export is missing"
reject_case missing-integration "Electron integration agent-visor-pi.ts.txt is missing"
reject_case development-helper "development helper is present"
reject_case bad-entitlement "release app contains com.apple.security.get-task-allow"
reject_case invalid-signature "release app signature failed strict deep verification"

echo "Release bundle negative tests PASS: invalid executable, architecture, metadata, helper, resources, notices, entitlements, and signature were rejected."
