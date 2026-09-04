#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE="$SCRIPT_DIR/screenshot-fixtures/agent-visor-synthetic.html"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

ACTIVE_PROFILE_DIR=""
ACTIVE_CHROME_PID=""

cleanup_active_chrome() {
    if [ -n "$ACTIVE_CHROME_PID" ]; then
        kill "$ACTIVE_CHROME_PID" 2>/dev/null || true
        wait "$ACTIVE_CHROME_PID" 2>/dev/null || true
        ACTIVE_CHROME_PID=""
    fi
    if [ -n "$ACTIVE_PROFILE_DIR" ]; then
        rm -rf "$ACTIVE_PROFILE_DIR"
        ACTIVE_PROFILE_DIR=""
    fi
}

trap cleanup_active_chrome EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -x "$CHROME" ]; then
    echo "ERROR: Google Chrome is required at $CHROME" >&2
    exit 1
fi

assert_fixture_copy() {
    local copy
    local required_copy=(
        "Search all sessions"
        "Needs you"
        "Ready to continue"
        "In progress"
        "History"
        "Open in Codex"
        "Open in Claude Code"
        "Open in Cursor"
        "Open in Pi"
        "Open Chat"
        "Accessibility"
        "Notifications"
        "Content size"
        "Connected automatically"
        "Observed automatically"
    )

    for copy in "${required_copy[@]}"; do
        if ! rg -Fq -- "$copy" "$FIXTURE"; then
            echo "ERROR: synthetic fixture is missing required copy: $copy" >&2
            exit 1
        fi
    done

    if rg -n '(<img|/Users/|/tmp/|token|account)' "$FIXTURE"; then
        echo "ERROR: synthetic fixture contains a non-synthetic asset or private value" >&2
        exit 1
    fi
}

assert_surface() {
    local fragment="$1"
    local profile_dir
    local dump_path
    local log_path
    local assertion
    local visible_count
    local chrome_pid

    profile_dir="$(mktemp -d -t agent-visor-surface-assert.XXXXXX)"
    dump_path="$profile_dir/dump.html"
    log_path="$profile_dir/chrome.log"
    ACTIVE_PROFILE_DIR="$profile_dir"
    "$CHROME" \
        --headless=new \
        --no-first-run \
        --disable-background-networking \
        --disable-gpu \
        --hide-scrollbars \
        --force-device-scale-factor=1 \
        --virtual-time-budget=1000 \
        --user-data-dir="$profile_dir" \
        --dump-dom \
        "file://$FIXTURE#$fragment-100" >"$dump_path" 2>"$log_path" &
    chrome_pid=$!
    ACTIVE_CHROME_PID="$chrome_pid"

    for _ in $(seq 1 100); do
        if [ -s "$dump_path" ]; then
            break
        fi
        if ! kill -0 "$chrome_pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    if [ ! -s "$dump_path" ]; then
        cat "$log_path" >&2
        exit 1
    fi

    kill "$chrome_pid" 2>/dev/null || true
    wait "$chrome_pid" 2>/dev/null || true
    ACTIVE_CHROME_PID=""

    assertion="$(rg -o 'data-fixture-assertion="[^"]+"' "$dump_path" | head -1 | cut -d'"' -f2 || true)"
    visible_count="$(rg -o 'data-fixture-visible-count="[0-9]+"' "$dump_path" | head -1 | cut -d'"' -f2 || true)"
    if [ "$assertion" != "ok:$fragment" ] || [ "$visible_count" != "1" ]; then
        cat "$log_path" >&2
        echo "ERROR: $fragment render selected $assertion with $visible_count visible surfaces" >&2
        exit 1
    fi
    rm -rf "$profile_dir"
    ACTIVE_PROFILE_DIR=""
}

image_dimensions() {
    local image="$1"
    if command -v sips >/dev/null 2>&1; then
        sips -g pixelWidth -g pixelHeight "$image" \
            | awk '/pixelWidth/ {width=$2} /pixelHeight/ {height=$2} END {printf "%sx%s", width, height}'
        return
    fi

    python3 - "$image" <<'PY'
import struct
import sys

with open(sys.argv[1], "rb") as image:
    image.seek(16)
    width, height = struct.unpack(">II", image.read(8))
print(f"{width}x{height}")
PY
}

verify_dimensions() {
    local output="$1"
    local size="$2"
    local expected="${size/,/x}"
    local actual
    actual="$(image_dimensions "$output")"
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $output is $actual; expected $expected" >&2
        exit 1
    fi
}

render() {
    local fragment="$1"
    local scale="$2"
    local size="$3"
    local output="$4"
    local profile_dir
    local chrome_pid
    local log_path

    profile_dir="$(mktemp -d -t agent-visor-screenshot.XXXXXX)"
    log_path="$profile_dir/chrome.log"
    ACTIVE_PROFILE_DIR="$profile_dir"
    rm -f "$output"
    "$CHROME" \
        --headless=new \
        --no-first-run \
        --disable-background-networking \
        --disable-gpu \
        --hide-scrollbars \
        --force-device-scale-factor=1 \
        --run-all-compositor-stages-before-draw \
        --virtual-time-budget=1000 \
        --user-data-dir="$profile_dir" \
        --window-size="$size" \
        --screenshot="$output" \
        "file://$FIXTURE#$fragment-$scale" >"$log_path" 2>&1 &
    chrome_pid=$!
    ACTIVE_CHROME_PID="$chrome_pid"

    for _ in $(seq 1 100); do
        if [ -s "$output" ]; then
            break
        fi
        sleep 0.1
    done

    if [ ! -s "$output" ]; then
        cat "$log_path" >&2
        echo "ERROR: Chrome did not render $output" >&2
        exit 1
    fi

    kill "$chrome_pid" 2>/dev/null || true
    wait "$chrome_pid" 2>/dev/null || true
    ACTIVE_CHROME_PID=""
    rm -rf "$profile_dir"
    ACTIVE_PROFILE_DIR=""
    verify_dimensions "$output" "$size"
}

assert_fixture_copy
mkdir -p "$PROJECT_DIR/screenshots"

# These four images are the tracked release-facing surfaces.
assert_surface menubar
render menubar 100 1800,84 "$PROJECT_DIR/screenshots/menubar-sessions.png"
assert_surface sessions
render sessions 100 1600,1000 "$PROJECT_DIR/screenshots/session-browser.png"
assert_surface chat
render chat 100 1600,1000 "$PROJECT_DIR/screenshots/chat.png"
assert_surface settings
render settings 100 1200,900 "$PROJECT_DIR/screenshots/settings.png"

# Verify the shared content scale without adding oversized QA artifacts to the
# release screenshots. Set KEEP_SCREENSHOT_QA=1 to inspect the generated files.
qa_dir="$(mktemp -d -t agent-visor-screenshot-qa.XXXXXX)"
cleanup_qa() {
    if [ "${KEEP_SCREENSHOT_QA:-0}" != "1" ]; then
        rm -rf "$qa_dir"
    else
        echo "Kept 250% QA screenshots in $qa_dir"
    fi
}
trap cleanup_qa EXIT

assert_surface menubar
render menubar 250 1800,84 "$qa_dir/menubar-250.png"
assert_surface sessions
render sessions 250 1600,1400 "$qa_dir/sessions-250.png"
assert_surface chat
render chat 250 1600,1400 "$qa_dir/chat-250.png"
assert_surface settings
render settings 250 1200,900 "$qa_dir/settings-250.png"

echo "Generated privacy-safe synthetic screenshots in $PROJECT_DIR/screenshots"
