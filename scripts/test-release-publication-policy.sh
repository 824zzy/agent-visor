#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/release-publication.sh"

adhoc_info=$'Executable=/tmp/Agent Visor.app/Contents/MacOS/Agent Visor\nSignature=adhoc\nTeamIdentifier=not set'
if [[ "$(release_distribution_mode "$adhoc_info")" != "ad-hoc" ]]; then
    echo "ERROR: ad-hoc release signature was not classified as ad-hoc" >&2
    exit 1
fi

developer_id_info=$'Executable=/tmp/Agent Visor.app/Contents/MacOS/Agent Visor\nAuthority=Developer ID Application: Agent Visor (ABCDE12345)\nTeamIdentifier=ABCDE12345'
if [[ "$(release_distribution_mode "$developer_id_info")" != "developer-id" ]]; then
    echo "ERROR: Developer ID release signature was not classified as developer-id" >&2
    exit 1
fi

unknown_info=$'Executable=/tmp/Agent Visor.app/Contents/MacOS/Agent Visor\nAuthority=Apple Development: Example (ABCDE12345)\nTeamIdentifier=ABCDE12345'
if release_distribution_mode "$unknown_info" >/dev/null 2>&1; then
    echo "ERROR: unsupported signing identity was accepted for release" >&2
    exit 1
fi

signed_cask=$'cask "agent-visor" do\n  app "Agent Visor.app"\nend'
if ! release_cask_preserves_signature "$signed_cask"; then
    echo "ERROR: a signature-preserving cask was rejected" >&2
    exit 1
fi

resigning_cask=$'postflight do\n  system_command "/usr/bin/codesign", args: ["--force", "--sign", "-"]\nend'
if release_cask_preserves_signature "$resigning_cask" >/dev/null 2>&1; then
    echo "ERROR: a cask that replaces the app signature was accepted" >&2
    exit 1
fi

quarantine_stripping_cask=$'postflight do\n  system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine"]\nend'
if release_cask_preserves_signature "$quarantine_stripping_cask" >/dev/null 2>&1; then
    echo "ERROR: a cask that strips Gatekeeper quarantine was accepted" >&2
    exit 1
fi

adhoc_cask=$'postflight do\n  system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine"]\n  system_command "/usr/bin/codesign", args: ["--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements,flags"]\nend'
if ! release_cask_supports_adhoc_install "$adhoc_cask"; then
    echo "ERROR: the established ad-hoc Homebrew installation path was rejected" >&2
    exit 1
fi

if release_cask_supports_adhoc_install "$signed_cask" >/dev/null 2>&1; then
    echo "ERROR: ad-hoc release accepted a cask without quarantine recovery and re-signing" >&2
    exit 1
fi

echo "Release publication policy PASS"
