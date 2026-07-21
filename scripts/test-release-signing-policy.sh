#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-signing.sh"

ADHOC_INFO=$'Executable=/tmp/Agent Visor.app/Contents/MacOS/Agent Visor\nIdentifier=com.824zzy.AgentVisor\nSignature=adhoc\nTeamIdentifier=not set'
ADHOC_REQUIREMENT='# designated => cdhash H"2eb34dbdae9ad6c1ae1634456b7990b0fb7458ee"'

if release_signature_is_stable "$ADHOC_INFO" "$ADHOC_REQUIREMENT" >/dev/null 2>&1; then
    echo "ERROR: ad-hoc signatures must not be publishable" >&2
    exit 1
fi

DEVELOPMENT_INFO=$'Executable=/tmp/Agent Visor.app/Contents/MacOS/Agent Visor\nIdentifier=com.824zzy.AgentVisor\nAuthority=AgentVisor Dev\nTeamIdentifier=LOCALDEV'
DEVELOPMENT_REQUIREMENT='designated => anchor trusted and identifier "com.824zzy.AgentVisor"'

if release_signature_is_stable "$DEVELOPMENT_INFO" "$DEVELOPMENT_REQUIREMENT" >/dev/null 2>&1; then
    echo "ERROR: local development identities must not be publishable" >&2
    exit 1
fi

SELF_SIGNED_SHA1="0123456789ABCDEF0123456789ABCDEF01234567"
SELF_SIGNED_INFO=$'Executable=/tmp/Agent Visor.app/Contents/MacOS/Agent Visor\nIdentifier=com.824zzy.AgentVisor\nAuthority=AgentVisor Release\nTeamIdentifier=not set'
SELF_SIGNED_REQUIREMENT='designated => identifier "com.824zzy.AgentVisor" and certificate leaf = H"0123456789abcdef0123456789abcdef01234567"'

release_signature_is_stable \
    "$SELF_SIGNED_INFO" \
    "$SELF_SIGNED_REQUIREMENT" \
    "AgentVisor Release" \
    "$SELF_SIGNED_SHA1"

if release_signature_is_stable \
    "$SELF_SIGNED_INFO" \
    "$SELF_SIGNED_REQUIREMENT" \
    "AgentVisor Release" \
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" >/dev/null 2>&1; then
    echo "ERROR: self-signed release with an unpinned certificate leaf was accepted" >&2
    exit 1
fi

DEVELOPER_ID_INFO=$'Executable=/tmp/Agent Visor.app/Contents/MacOS/Agent Visor\nIdentifier=com.824zzy.AgentVisor\nAuthority=Developer ID Application: Agent Visor LLC (A1B2C3D4E5)\nTeamIdentifier=A1B2C3D4E5'
DEVELOPER_ID_REQUIREMENT='designated => anchor apple generic and identifier "com.824zzy.AgentVisor" and certificate leaf[subject.OU] = A1B2C3D4E5'

release_signature_is_stable "$DEVELOPER_ID_INFO" "$DEVELOPER_ID_REQUIREMENT"

echo "Release signing policy PASS"
