#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SETUP_SCRIPT="$SCRIPT_DIR/release-sign-setup.sh"
EXPORT_SCRIPT="$SCRIPT_DIR/export-release-signing-identity.swift"
CONFIG_PATH="$PROJECT_DIR/config/release-signing.env"

source "$CONFIG_PATH"

if [[ "$AGENT_VISOR_RELEASE_IDENTITY" != "AgentVisor Release" ]]; then
    echo "ERROR: release identity name drifted" >&2
    exit 1
fi
if [[ ! "$AGENT_VISOR_RELEASE_CERT_SHA1" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "ERROR: release certificate SHA-1 is not pinned" >&2
    exit 1
fi

for required_source in \
    'AV_ALLOW_CREATE_RELEASE_IDENTITY' \
    'Do not generate a replacement identity' \
    '.release-keys' \
    '/usr/bin/openssl' \
    'security add-trusted-cert' \
    'CSSMERR_TP_NOT_TRUSTED'; do
    if ! grep -Fq "$required_source" "$SETUP_SCRIPT"; then
        echo "ERROR: release signing setup is missing: $required_source" >&2
        exit 1
    fi
done

if [[ ! -f "$EXPORT_SCRIPT" ]]; then
    echo "ERROR: partial keychain setup cannot create the required recovery backup" >&2
    exit 1
fi
/usr/bin/xcrun swiftc -typecheck "$EXPORT_SCRIPT"
for required_source in \
    'export-release-signing-identity.swift' \
    'AgentVisor-Release.p12.password'; do
    if ! grep -Fq "$required_source" "$SETUP_SCRIPT"; then
        echo "ERROR: release signing setup does not recover a missing P12 backup" >&2
        exit 1
    fi
done
for required_source in \
    'SecIdentityCreateWithCertificate' \
    'SecItemExport' \
    '.formatPKCS12'; do
    if ! grep -Fq "$required_source" "$EXPORT_SCRIPT"; then
        echo "ERROR: exact release identity exporter is missing: $required_source" >&2
        exit 1
    fi
done
if grep -Fq 'security export -t identities' "$SETUP_SCRIPT"; then
    echo "ERROR: setup exports unrelated keychain identities" >&2
    exit 1
fi

if grep -Eq 'security import .* -A|security import .*--all' "$SETUP_SCRIPT"; then
    echo "ERROR: release private key grants unrestricted application access" >&2
    exit 1
fi
if grep -Fq '^^}' "$SETUP_SCRIPT" "$SCRIPT_DIR/build.sh"; then
    echo "ERROR: release signing scripts require Bash 4 instead of macOS Bash" >&2
    exit 1
fi

echo "Release signing setup wiring PASS"
