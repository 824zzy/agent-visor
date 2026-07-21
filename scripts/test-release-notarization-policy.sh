#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-notarization.sh"

accepted_assessment=$'/tmp/Agent Visor.app: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Agent Visor (ABCDE12345)'
accepted_staple=$'Processing: /tmp/Agent Visor.app\nThe validate action worked!'

if ! release_notarization_is_accepted "$accepted_assessment" "$accepted_staple"; then
    echo "ERROR: accepted notarization evidence was rejected" >&2
    exit 1
fi

developer_id_only=$'/tmp/Agent Visor.app: accepted\nsource=Developer ID\norigin=Developer ID Application: Agent Visor (ABCDE12345)'
if release_notarization_is_accepted "$developer_id_only" "$accepted_staple" >/dev/null 2>&1; then
    echo "ERROR: an unstapled Developer ID assessment was accepted" >&2
    exit 1
fi

missing_ticket=$'Processing: /tmp/Agent Visor.app\nCloudKit query failed'
if release_notarization_is_accepted "$accepted_assessment" "$missing_ticket" >/dev/null 2>&1; then
    echo "ERROR: missing staple evidence was accepted" >&2
    exit 1
fi

rejected_assessment=$'/tmp/Agent Visor.app: rejected\nsource=Unnotarized Developer ID'
if release_notarization_is_accepted "$rejected_assessment" "$accepted_staple" >/dev/null 2>&1; then
    echo "ERROR: a rejected Gatekeeper assessment was accepted" >&2
    exit 1
fi

echo "Release notarization policy PASS"
