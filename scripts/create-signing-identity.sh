#!/bin/bash
# One-time setup: creates the self-signed "MacEQ Self-Signed" code-signing
# identity in the login keychain, for scripts/build-app.sh to sign with.
#
# Why: macOS remembers the system-audio permission against the app's code
# signature. An ad-hoc signature changes with every build, so every update
# re-asks. A certificate that stays the same across builds keeps the grant.
#
# codesign refuses untrusted identities, so this also trusts the certificate
# for code signing only (not TLS, not as a CA for anything else). macOS asks
# for your password for that step.
#
# Back the identity up afterwards: Keychain Access → login → My Certificates →
# "MacEQ Self-Signed" → File → Export Items… (.p12). Builds signed with a new
# identity count as a new app, so every user is asked for the permission
# once more.
set -euo pipefail

IDENTITY="MacEQ Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# 20 years: renewing changes the certificate, which costs every user one more
# permission prompt. The 398-day limit is for TLS certificates, not this.
VALID_DAYS=7300

# A second identity with the same name would make codesign's choice ambiguous
# and, if picked, silently change the app's identity.
if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "error: a certificate named '$IDENTITY' already exists in $KEYCHAIN" >&2
    security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY" >&2 || true
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# /usr/bin/openssl is LibreSSL, whose default PKCS#12 encryption is one
# `security import` reads (OpenSSL 3's default is not).
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days "$VALID_DAYS" \
    -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" 2>/dev/null

# The .p12 exists only to carry key + certificate into the keychain; its
# password never leaves this script.
P12_PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -name "$IDENTITY" \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -out "$WORK_DIR/identity.p12" -passout "pass:$P12_PASSWORD"

# -T lets codesign use the private key without a keychain prompt per build.
security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign

echo "Trusting '$IDENTITY' for code signing (macOS asks for your password)…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem"

if ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "error: '$IDENTITY' was imported but is not a valid code-signing identity:" >&2
    security find-identity -p codesigning >&2
    exit 1
fi

echo "Created '$IDENTITY'. scripts/build-app.sh now signs with it."
echo "Back it up: Keychain Access → login → My Certificates → '$IDENTITY' → File → Export Items…"
