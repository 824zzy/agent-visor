#!/bin/bash
# Create or verify the long-lived self-signed identity used for public releases.
#
# Creation is deliberately one-time. After the public SHA-1 is pinned in
# config/release-signing.env, a missing identity must be restored from backup;
# silently generating a replacement would break Accessibility grants for every
# installed copy of Agent Visor.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_PATH="$PROJECT_DIR/config/release-signing.env"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BACKUP_DIR="$PROJECT_DIR/.release-keys"
OPENSSL="/usr/bin/openssl"
EXPORTER="$SCRIPT_DIR/export-release-signing-identity.swift"

source "$CONFIG_PATH"
PINNED_RELEASE_SHA1="$(printf '%s' "$AGENT_VISOR_RELEASE_CERT_SHA1" | tr '[:lower:]' '[:upper:]')"

ensure_recovery_backup() {
    local certificate_sha1="$1"
    local p12_path="$BACKUP_DIR/AgentVisor-Release.p12"
    local password_path="$BACKUP_DIR/AgentVisor-Release.p12.password"

    if [[ -s "$p12_path" && -s "$password_path" ]]; then
        return 0
    fi
    if [[ -e "$p12_path" || -e "$password_path" ]]; then
        echo "ERROR: release identity recovery backup is incomplete." >&2
        echo "       Remove neither file; repair $BACKUP_DIR before continuing." >&2
        return 1
    fi

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    local temporary_p12="$BACKUP_DIR/.AgentVisor-Release.p12.tmp"
    local temporary_password="$BACKUP_DIR/.AgentVisor-Release.p12.password.tmp"
    local export_password
    export_password="$($OPENSSL rand -base64 36 | tr -d '\n')"
    printf '%s\n' "$export_password" > "$temporary_password"
    chmod 600 "$temporary_password"

    if ! /usr/bin/xcrun swift "$EXPORTER" \
        "$AGENT_VISOR_RELEASE_IDENTITY" \
        "$certificate_sha1" \
        "$temporary_p12" \
        "$temporary_password"; then
        rm -f "$temporary_p12" "$temporary_password"
        echo "ERROR: could not export the exact release identity recovery backup." >&2
        return 1
    fi

    chmod 600 "$temporary_p12"
    mv "$temporary_p12" "$p12_path"
    mv "$temporary_password" "$password_path"
    echo "Encrypted release identity backup created at $BACKUP_DIR"
}

identity_line() {
    security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
        | grep -F "\"$AGENT_VISOR_RELEASE_IDENTITY\"" \
        | head -1
}

trusted_identity_line() {
    local line
    line="$(identity_line)"
    if [[ -z "$line" || "$line" == *CSSMERR_TP_NOT_TRUSTED* ]]; then
        return 1
    fi
    printf '%s\n' "$line"
}

installed_sha1() {
    awk '{print toupper($2)}' <<<"$1"
}

if EXISTING_LINE="$(trusted_identity_line)" && [[ -n "$EXISTING_LINE" ]]; then
    EXISTING_SHA1="$(installed_sha1 "$EXISTING_LINE")"
    if [[ -n "$AGENT_VISOR_RELEASE_CERT_SHA1" \
        && "$EXISTING_SHA1" != "$PINNED_RELEASE_SHA1" ]]; then
        echo "ERROR: installed '$AGENT_VISOR_RELEASE_IDENTITY' does not match the pinned release certificate." >&2
        echo "       installed: $EXISTING_SHA1" >&2
        echo "       expected:  $PINNED_RELEASE_SHA1" >&2
        exit 1
    fi
    echo "Release identity is installed: $AGENT_VISOR_RELEASE_IDENTITY"
    echo "Certificate SHA-1: $EXISTING_SHA1"
    if [[ -z "$AGENT_VISOR_RELEASE_CERT_SHA1" ]]; then
        echo "Pin this value in config/release-signing.env before building a release."
    else
        ensure_recovery_backup "$EXISTING_SHA1"
    fi
    exit 0
fi

if security find-certificate -c "$AGENT_VISOR_RELEASE_IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    CERT_SHA1="$({
        security find-certificate -c "$AGENT_VISOR_RELEASE_IDENTITY" -Z "$KEYCHAIN" \
            | sed -n 's/^SHA-1 hash: //p' \
            | head -1
    })"
    if [[ -z "$AGENT_VISOR_RELEASE_CERT_SHA1" \
        || "$CERT_SHA1" != "$PINNED_RELEASE_SHA1" ]]; then
        echo "ERROR: an untrusted certificate named '$AGENT_VISOR_RELEASE_IDENTITY' exists," >&2
        echo "       but it does not match the pinned release identity." >&2
        exit 1
    fi

    PARTIAL_CERT="$(mktemp -t av-release-cert-existing).pem"
    trap 'rm -f "$PARTIAL_CERT"' EXIT
    security find-certificate -c "$AGENT_VISOR_RELEASE_IDENTITY" -p "$KEYCHAIN" > "$PARTIAL_CERT"
    ensure_recovery_backup "$CERT_SHA1"
    echo "The pinned certificate is installed but not yet trusted for code signing."
    echo "macOS will request administrator approval to complete setup."
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$PARTIAL_CERT"

    TRUSTED_LINE="$(trusted_identity_line || true)"
    if [[ -z "$TRUSTED_LINE" ]]; then
        echo "ERROR: the certificate was trusted but is still not a valid signing identity." >&2
        exit 1
    fi
    echo "Release identity is now trusted: $AGENT_VISOR_RELEASE_IDENTITY"
    echo "Certificate SHA-1: $(installed_sha1 "$TRUSTED_LINE")"
    exit 0
fi

if [[ -n "$AGENT_VISOR_RELEASE_CERT_SHA1" ]]; then
    echo "ERROR: the pinned release identity is missing from the login keychain." >&2
    echo "       Restore .release-keys/AgentVisor-Release.p12 using the separately" >&2
    echo "       backed-up recovery password. Do not generate a replacement identity." >&2
    exit 1
fi

if [[ "${AV_ALLOW_CREATE_RELEASE_IDENTITY:-0}" != "1" ]]; then
    echo "ERROR: no release identity is installed and no certificate is pinned." >&2
    echo "       Set AV_ALLOW_CREATE_RELEASE_IDENTITY=1 only for the initial signing ceremony." >&2
    exit 1
fi

TMP="$(mktemp -d -t av-release-cert)"
trap 'rm -rf "$TMP"' EXIT
KEY="$TMP/key.pem"
CRT="$TMP/cert.pem"
P12="$TMP/cert.p12"
P12_PASSWORD="$($OPENSSL rand -base64 36 | tr -d '\n')"

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = $AGENT_VISOR_RELEASE_IDENTITY
[v3_req]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:FALSE
EOF

echo "Creating the one-time '$AGENT_VISOR_RELEASE_IDENTITY' certificate..."
$OPENSSL req -x509 -newkey rsa:3072 -nodes \
    -keyout "$KEY" -out "$CRT" \
    -days 3650 \
    -config "$TMP/openssl.cnf" -extensions v3_req

printf '%s\n' "$P12_PASSWORD" > "$TMP/p12-password"
$OPENSSL pkcs12 -export \
    -inkey "$KEY" -in "$CRT" \
    -out "$P12" \
    -passout "file:$TMP/p12-password"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
cp "$P12" "$BACKUP_DIR/AgentVisor-Release.p12"
printf '%s\n' "$P12_PASSWORD" > "$BACKUP_DIR/AgentVisor-Release.p12.password"
chmod 600 \
    "$BACKUP_DIR/AgentVisor-Release.p12" \
    "$BACKUP_DIR/AgentVisor-Release.p12.password"

security import "$P12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASSWORD" \
    -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CRT"

CREATED_LINE="$(identity_line)"
if [[ -z "$CREATED_LINE" ]]; then
    echo "ERROR: certificate import completed but codesign cannot find the identity." >&2
    exit 1
fi
CREATED_SHA1="$(installed_sha1 "$CREATED_LINE")"

echo
echo "Release identity created: $AGENT_VISOR_RELEASE_IDENTITY"
echo "Certificate SHA-1: $CREATED_SHA1"
echo "Encrypted recovery files: $BACKUP_DIR"
echo
echo "Required next step: pin $CREATED_SHA1 in config/release-signing.env."
echo "Back up the P12 and password separately before publishing the first release."
