#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-identity-continuity.sh"

STABLE_REQUIREMENT='designated => identifier "com.824zzy.AgentVisor" and certificate leaf = H"0123456789abcdef0123456789abcdef01234567"'

release_identity_is_continuous \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    "$STABLE_REQUIREMENT" \
    "$STABLE_REQUIREMENT"

if release_identity_is_continuous \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    "$STABLE_REQUIREMENT" \
    'designated => cdhash H"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' >/dev/null 2>&1; then
    echo "ERROR: changed designated requirement was accepted" >&2
    exit 1
fi

if release_identity_is_continuous \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "$STABLE_REQUIREMENT" \
    "$STABLE_REQUIREMENT" >/dev/null 2>&1; then
    echo "ERROR: unchanged executable did not exercise an update" >&2
    exit 1
fi

echo "Release identity continuity policy PASS"
