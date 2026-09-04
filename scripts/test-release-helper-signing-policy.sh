#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-signing.sh"

SELF_SIGNED_OUTER=$'Executable=/tmp/Agent Visor.app/Contents/MacOS/Agent Visor\nAuthority=AgentVisor Release\nTeamIdentifier=not set'
SELF_SIGNED_HELPER=$'Executable=/tmp/Agent Visor Native Helper.app/Contents/MacOS/AgentVisorNativeHelper\nAuthority=AgentVisor Release\nTeamIdentifier=not set'

release_validate_nested_signature \
    self-signed \
    "$SELF_SIGNED_OUTER" \
    "$SELF_SIGNED_HELPER" \
    "AgentVisor Release" \
    "not set"

if release_validate_nested_signature \
    self-signed \
    "$SELF_SIGNED_OUTER" \
    "${SELF_SIGNED_HELPER/Authority=AgentVisor Release/Authority=AgentVisor Other}" \
    "AgentVisor Release" \
    "not set" >/dev/null 2>&1; then
    echo "ERROR: helper with a different self-signed identity was accepted" >&2
    exit 1
fi

if release_validate_nested_signature \
    self-signed \
    "$SELF_SIGNED_OUTER" \
    "${SELF_SIGNED_HELPER/TeamIdentifier=not set/TeamIdentifier=OTHERTEAM}" \
    "AgentVisor Release" \
    "not set" >/dev/null 2>&1; then
    echo "ERROR: helper with a different self-signed TeamIdentifier was accepted" >&2
    exit 1
fi

DEVELOPER_ID_OUTER=$'Executable=/tmp/Agent Visor.app/Contents/MacOS/Agent Visor\nAuthority=Developer ID Application: Agent Visor LLC (A1B2C3D4E5)\nTeamIdentifier=A1B2C3D4E5'
DEVELOPER_ID_HELPER=$'Executable=/tmp/Agent Visor Native Helper.app/Contents/MacOS/AgentVisorNativeHelper\nAuthority=Developer ID Application: Agent Visor LLC (A1B2C3D4E5)\nTeamIdentifier=A1B2C3D4E5'

release_validate_nested_signature \
    developer-id \
    "$DEVELOPER_ID_OUTER" \
    "$DEVELOPER_ID_HELPER" \
    "" \
    "A1B2C3D4E5"

if release_validate_nested_signature \
    developer-id \
    "$DEVELOPER_ID_OUTER" \
    "${DEVELOPER_ID_HELPER/TeamIdentifier=A1B2C3D4E5/TeamIdentifier=OTHERTEAM}" \
    "" \
    "A1B2C3D4E5" \
    >/dev/null 2>&1; then
    echo "ERROR: helper with a different Developer ID TeamIdentifier was accepted" >&2
    exit 1
fi

ADHOC_INFO=$'Executable=/tmp/Agent Visor.app/Contents/MacOS/Agent Visor\nSignature=adhoc\nTeamIdentifier=not set'
ADHOC_HELPER_INFO=$'Executable=/tmp/Agent Visor Native Helper.app/Contents/MacOS/AgentVisorNativeHelper\nSignature=adhoc\nTeamIdentifier=not set'
release_validate_nested_signature ad-hoc "$ADHOC_INFO" "$ADHOC_HELPER_INFO"

echo "Release helper signing policy PASS: stable helper identity and TeamIdentifier continuity mutations were rejected."
