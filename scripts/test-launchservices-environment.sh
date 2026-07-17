#!/bin/zsh

set -euo pipefail

VALUE_VARIABLE="AGENT_VISOR_LAUNCH_ENV_PROBE"
OUTPUT_VARIABLE="AGENT_VISOR_LAUNCH_ENV_OUTPUT"
EXPECTED_VALUE="agent-visor-$RANDOM-$RANDOM"
TMP_DIR="$(mktemp -d /tmp/agent-visor-launch-env.XXXXXX)"
APP_PATH="$TMP_DIR/Launch Environment Probe.app"
OUTPUT_PATH="$TMP_DIR/result.txt"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/LaunchEnvironmentProbe"
PLIST_PATH="$APP_PATH/Contents/Info.plist"
PREVIOUS_VALUE="$(launchctl getenv "$VALUE_VARIABLE" 2>/dev/null || true)"
PREVIOUS_OUTPUT="$(launchctl getenv "$OUTPUT_VARIABLE" 2>/dev/null || true)"

restore_variable() {
  local name="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    launchctl setenv "$name" "$value"
  else
    launchctl unsetenv "$name" 2>/dev/null || true
  fi
}

cleanup() {
  restore_variable "$VALUE_VARIABLE" "$PREVIOUS_VALUE"
  restore_variable "$OUTPUT_VARIABLE" "$PREVIOUS_OUTPUT"
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$APP_PATH/Contents/MacOS"
cp "${0:A:h}/fixtures/launch-environment-probe.sh" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"
plutil -create xml1 "$PLIST_PATH"
plutil -insert CFBundleExecutable -string LaunchEnvironmentProbe "$PLIST_PATH"
plutil -insert CFBundleIdentifier -string com.824zzy.AgentVisor.LaunchEnvironmentProbe "$PLIST_PATH"
plutil -insert CFBundleName -string "Launch Environment Probe" "$PLIST_PATH"
plutil -insert CFBundlePackageType -string APPL "$PLIST_PATH"
plutil -insert LSUIElement -bool true "$PLIST_PATH"
codesign --force --sign - "$APP_PATH" >/dev/null

launchctl setenv "$VALUE_VARIABLE" "$EXPECTED_VALUE"
launchctl setenv "$OUTPUT_VARIABLE" "$OUTPUT_PATH"
open -n "$APP_PATH"

for _ in {1..50}; do
  [[ -f "$OUTPUT_PATH" ]] && break
  sleep 0.1
done

if [[ ! -f "$OUTPUT_PATH" ]]; then
  print -u2 "LaunchServices probe did not produce an output file."
  exit 1
fi

ACTUAL_VALUE="$(<"$OUTPUT_PATH")"
if [[ "$ACTUAL_VALUE" != "$EXPECTED_VALUE" ]]; then
  print -u2 "LaunchServices inherited '$ACTUAL_VALUE', expected '$EXPECTED_VALUE'."
  exit 1
fi

print "LaunchServices environment PASS: future app launches inherit launchctl setenv."
