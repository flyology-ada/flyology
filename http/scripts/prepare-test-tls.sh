#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures/tls"
CERTIFICATE="$FIXTURES/server-cert.pem"
PRIVATE_KEY="$FIXTURES/server-key.pem"

if [ -s "$CERTIFICATE" ] && [ -s "$PRIVATE_KEY" ]; then
  exit 0
fi

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required to prepare the TLS test fixture" >&2
  exit 1
}

umask 077
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
  -config "$FIXTURES/openssl.cnf" \
  -keyout "$PRIVATE_KEY" \
  -out "$CERTIFICATE" >/dev/null 2>&1
