#!/usr/bin/env bash
# Create a stable local codesign identity once so TCC grants survive rebuilds.
set -euo pipefail

CERT_NAME="Kiln Local Codesign"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
WORKDIR="${TMPDIR:-/tmp}/kiln-codesign-$$"

# Prefer an already-valid codesigning identity.
if HASH=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Kiln Local Codesign/{print $1}' | awk '{print $2; exit}'); then
  if [[ -n "${HASH}" ]]; then
    echo "$HASH"
    exit 0
  fi
fi

mkdir -p "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

openssl genrsa -out "$WORKDIR/kiln.key" 2048 2>/dev/null
openssl req -new -key "$WORKDIR/kiln.key" -out "$WORKDIR/kiln.csr" \
  -subj "/CN=${CERT_NAME}/O=Kiln Dev/C=US" 2>/dev/null

cat > "$WORKDIR/ext.cnf" <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=codeSigning
EOF

openssl x509 -req -days 3650 \
  -in "$WORKDIR/kiln.csr" \
  -signkey "$WORKDIR/kiln.key" \
  -out "$WORKDIR/kiln.crt" \
  -extfile "$WORKDIR/ext.cnf" 2>/dev/null

EXPORT_OPTS=(-export -out "$WORKDIR/kiln.p12" -inkey "$WORKDIR/kiln.key" -in "$WORKDIR/kiln.crt" -passout pass:kiln-local)
if ! openssl pkcs12 "${EXPORT_OPTS[@]}" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 2>/dev/null; then
  openssl pkcs12 "${EXPORT_OPTS[@]}" -legacy 2>/dev/null || openssl pkcs12 "${EXPORT_OPTS[@]}" 2>/dev/null
fi

security import "$WORKDIR/kiln.p12" \
  -k "$KEYCHAIN" \
  -P kiln-local \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

security add-trusted-cert -d -r trustRoot -p codeSign \
  -k "$KEYCHAIN" "$WORKDIR/kiln.crt" >/dev/null 2>&1 || true

HASH=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Kiln Local Codesign/{print $1}' | awk '{print $2; exit}')
if [[ -z "${HASH}" ]]; then
  echo "Failed to create a trusted codesign identity for '$CERT_NAME'" >&2
  exit 1
fi
echo "$HASH"
