#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-build-mode.sh"

assert_equal() {
    local expected="$1"
    local actual="$2"
    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: expected '$expected', got '$actual'" >&2
        exit 1
    fi
}

assert_equal "local-adhoc" "$(release_build_mode "" "")"

if release_build_mode "Developer ID Application: Agent Visor (ABCDE12345)" "" >/dev/null 2>&1; then
    echo "ERROR: signing identity without Team ID was accepted" >&2
    exit 1
fi

if release_build_mode "AgentVisor Dev" "ABCDE12345" >/dev/null 2>&1; then
    echo "ERROR: local development identity was accepted for publication" >&2
    exit 1
fi

assert_equal \
    "developer-id" \
    "$(release_build_mode "Developer ID Application: Agent Visor (ABCDE12345)" "ABCDE12345")"

echo "Release build mode PASS"
