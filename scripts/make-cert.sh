#!/bin/zsh
# Creates a local code signing certificate in the login keychain (once).
# With a stable signature, macOS keeps the Accessibility permission between builds.
set -euo pipefail
NAME="Notch Island Dev"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Certificate \"$NAME\" already exists."
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cfg" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
# Legacy PKCS#12 encryption, the one `security import` accepts on every macOS version.
openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -out "$tmp/id.p12" -passout pass:notch

security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P notch -T /usr/bin/codesign
echo "Created certificate \"$NAME\"."
