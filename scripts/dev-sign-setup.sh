#!/bin/bash
# One-time setup: create a stable self-signed code-signing cert in your
# login keychain. After this, scripts/dev-build.sh signs debug builds with
# the cert and macOS TCC permission grants persist across rebuilds.
#
# No Apple Developer account required. The cert is self-signed and never
# leaves your machine. macOS Gatekeeper still treats your debug build as
# "unknown developer" — but you launch via `open ...app` so Gatekeeper
# isn't in the picture for local dev.
#
# Idempotent: re-running detects an existing cert and exits cleanly.
#
# Env overrides:
#   AV_DEV_CERT — keychain identity name (default: "AgentVisor Dev")
set -e

CERT_NAME="${AV_DEV_CERT:-AgentVisor Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "Code-signing cert '$CERT_NAME' is already in your login keychain. Nothing to do."
    echo "Next: run scripts/dev-build.sh for debug builds."
    exit 0
fi

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "ERROR: '$CERT_NAME' exists but is not a valid code-signing identity." >&2
    echo "Remove that partial identity before running this setup again." >&2
    exit 1
fi

TMP="$(mktemp -d -t av-cert)"
trap "rm -rf '$TMP'" EXIT

KEY="$TMP/key.pem"
CRT="$TMP/cert.pem"
P12="$TMP/cert.p12"
P12_PASS="dev"

# Use a config file rather than -addext, for LibreSSL compatibility on
# stock macOS without Homebrew openssl.
cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = $CERT_NAME
[v3_req]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:FALSE
EOF

echo "==> Generating self-signed code-signing cert: $CERT_NAME (10-year validity)"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" -out "$CRT" \
    -days 3650 \
    -config "$TMP/openssl.cnf" -extensions v3_req

echo "==> Packaging into PKCS12 for keychain import..."
openssl pkcs12 -export \
    -inkey "$KEY" -in "$CRT" \
    -out "$P12" \
    -password "pass:$P12_PASS"

echo "==> Importing into login keychain (allowing codesign to use the key)..."
security import "$P12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign

echo "==> Trusting the certificate for code signing only..."
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$KEYCHAIN" \
    "$CRT"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "==> Done. '$CERT_NAME' is in your login keychain."
    echo "==> Now run scripts/dev-build.sh for debug builds."
    echo
    echo "First time codesign uses the key, macOS may ask for your login password."
    echo "Click 'Always Allow' so future builds run unattended."
else
    echo "ERROR: import succeeded but find-identity does not see the cert." >&2
    exit 1
fi
