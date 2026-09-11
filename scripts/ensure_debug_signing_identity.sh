#!/usr/bin/env bash
# Create or reuse a stable local code-signing identity so Screen Recording
# and Microphone TCC survive Debug rebuilds. Ad-hoc (`codesign -s -`) keys
# TCC to the binary hash — every rebuild looks like a new app.
set -euo pipefail

NAME="${SCRUMTRACE_SIGN_IDENTITY:-ScrumTrace Debug}"
SUPPORT="${HOME}/Library/Application Support/ScrumTrace/signing"
P12="${SUPPORT}/ScrumTrace-Debug.p12"
PEM="${SUPPORT}/ScrumTrace-Debug.pem"
PASS="${SCRUMTRACE_SIGN_PASSWORD:-scrumtrace-debug}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ensure_debug_signing_identity.sh must run on macOS" >&2
  exit 2
fi

identity_present() {
  security find-identity -v -p codesigning 2>/dev/null | grep -F "$NAME" >/dev/null
}

trust_cert() {
  local cert="$1"
  if security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$cert"; then
    return 0
  fi
  # Headless/no GUI password: admin trust prompt (-d) is the next best option.
  if security add-trusted-cert -d -p codeSign -k "$KEYCHAIN" "$cert"; then
    return 0
  fi
  echo "trust the certificate in Keychain Access (Trust > Code Signing: Always Trust) and re-run" >&2
  exit 1
}

mkdir -p "$SUPPORT"

KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
if [[ ! -f "$KEYCHAIN" ]]; then
  KEYCHAIN="${HOME}/Library/Keychains/login.keychain"
fi

import_p12() {
  local file="$1"
  security import "$file" \
    -k "$KEYCHAIN" \
    -P "$PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productsign >/dev/null
}

if identity_present; then
  echo "$NAME"
  exit 0
fi

if [[ -f "$P12" ]]; then
  echo "re-importing $P12 into login keychain" >&2
  if import_p12 "$P12"; then
    if [[ -f "$PEM" ]]; then
      trust_cert "$PEM"
    fi
    if identity_present; then
      echo "$NAME"
      exit 0
    fi
  else
    echo "existing p12 rejected by security import; recreating with /usr/bin/openssl" >&2
  fi
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/scrumtrace-codesign.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

cat > "$WORKDIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_req
[ req_distinguished_name ]
CN = ${NAME}
O = ScrumTrace
[ v3_req ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -config "$WORKDIR/openssl.cnf" \
  -extensions v3_req >/dev/null 2>&1

/usr/bin/openssl pkcs12 -export \
  -inkey "$WORKDIR/key.pem" \
  -in "$WORKDIR/cert.pem" \
  -out "$WORKDIR/cert.p12" \
  -passout "pass:${PASS}" \
  -name "$NAME" >/dev/null 2>&1 \
|| openssl pkcs12 -export \
  -inkey "$WORKDIR/key.pem" \
  -in "$WORKDIR/cert.pem" \
  -out "$WORKDIR/cert.p12" \
  -passout "pass:${PASS}" \
  -name "$NAME" \
  -legacy >/dev/null

cp "$WORKDIR/cert.p12" "$P12"
import_p12 "$P12"
cp "$WORKDIR/cert.pem" "$PEM"
trust_cert "$PEM"

# Best-effort: let codesign use the key without a keychain prompt.
if [[ -t 0 ]]; then
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN" >/dev/null 2>&1 || true
fi

if ! identity_present; then
  echo "failed to install code-signing identity '$NAME'" >&2
  exit 1
fi

echo "created stable identity '$NAME' (reused across rebuilds)" >&2
echo "$NAME"
