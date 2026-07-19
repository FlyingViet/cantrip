#!/bin/sh
# Creates a self-signed code-signing certificate so Cantrip keeps a stable
# identity across rebuilds (macOS permission grants survive).
# Usage: make-cert.sh "Cert Name"
set -e

CERTNAME="${1:-AgentSpotlight Dev}"

if security find-identity -v -p codesigning | grep -q "$CERTNAME"; then
    echo "Certificate '$CERTNAME' already exists."
    exit 0
fi

echo "Creating code-signing certificate '$CERTNAME'…"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERTNAME
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -config "$TMP/cert.conf" 2>/dev/null

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:cantrip-temp

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# -T pre-authorizes codesign so it can use the key without prompting.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P cantrip-temp \
    -T /usr/bin/codesign

# Trust it for code signing (may show a one-time system password dialog).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" || {
    echo "NOTE: trust step needs approval. If signing still fails, open"
    echo "Keychain Access → My Certificates → '$CERTNAME' → Trust →"
    echo "set 'Code Signing' to Always Trust."
}

echo "Done. '$CERTNAME' is ready."
