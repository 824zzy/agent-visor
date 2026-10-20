#!/usr/bin/env bash
# Build only. Never launches the app or operates Ghostty.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:?Pass an absolute output directory for this disposable test build}"
[[ "$OUTPUT_DIR" == /* ]] || { echo 'Output directory must be absolute' >&2; exit 1; }
swift build --package-path "$PROJECT_DIR/AgentVisorCore" --product AgentVisorNativeFocusProof --jobs 2
BIN_DIR="$(swift build --package-path "$PROJECT_DIR/AgentVisorCore" --show-bin-path)"
mkdir -p "$OUTPUT_DIR"
STAGING="$(mktemp -d "${OUTPUT_DIR%/}/native-focus-XXXXXX")"
APP="$STAGING/Agent Visor Focus Proof.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/AgentVisorNativeFocusProof" "$APP/Contents/MacOS/AgentVisorNativeFocusProof"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.agentvisor.native-focus-proof</string>
<key>CFBundleExecutable</key><string>AgentVisorNativeFocusProof</string>
<key>CFBundleName</key><string>Agent Visor Focus Proof</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAppleEventsUsageDescription</key><string>This human-operated test creates and focuses only its disposable Ghostty fixtures.</string>
</dict></plist>
PLIST
cat > "$STAGING/automation.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.automation.apple-events</key><true/></dict></plist>
PLIST
codesign --force --sign - --options runtime --entitlements "$STAGING/automation.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
