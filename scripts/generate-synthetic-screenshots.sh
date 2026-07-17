#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE="$SCRIPT_DIR/screenshot-fixtures/agent-visor-synthetic.html"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

if [ ! -x "$CHROME" ]; then
    echo "ERROR: Google Chrome is required at $CHROME" >&2
    exit 1
fi

render() {
    local fragment="$1"
    local size="$2"
    local output="$3"
    local profile_dir
    local chrome_pid
    local log_path

    profile_dir="$(mktemp -d -t agent-visor-screenshot.XXXXXX)"
    log_path="$profile_dir/chrome.log"
    rm -f "$output"
    "$CHROME" \
        --headless=new \
        --no-first-run \
        --disable-background-networking \
        --disable-gpu \
        --hide-scrollbars \
        --force-device-scale-factor=1 \
        --user-data-dir="$profile_dir" \
        --window-size="$size" \
        --screenshot="$output" \
        "file://$FIXTURE#$fragment" >"$log_path" 2>&1 &
    chrome_pid=$!

    for _ in $(jot 100); do
        if [ -s "$output" ]; then
            break
        fi
        sleep 0.1
    done

    if [ ! -s "$output" ]; then
        cat "$log_path" >&2
        kill "$chrome_pid" 2>/dev/null || true
        wait "$chrome_pid" 2>/dev/null || true
        rm -rf "$profile_dir"
        echo "ERROR: Chrome did not render $output" >&2
        exit 1
    fi

    kill "$chrome_pid" 2>/dev/null || true
    wait "$chrome_pid" 2>/dev/null || true
    rm -rf "$profile_dir"
}

mkdir -p "$PROJECT_DIR/screenshots"
render menubar 1800,84 "$PROJECT_DIR/screenshots/menubar-sessions.png"
render browser 1600,1000 "$PROJECT_DIR/screenshots/session-browser.png"

echo "Generated privacy-safe synthetic screenshots in $PROJECT_DIR/screenshots"
