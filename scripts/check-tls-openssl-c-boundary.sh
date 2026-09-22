#!/bin/sh
set -eu

archive=$1
symbols=$(nm -u "$archive")
if printf '%s\n' "$symbols" | grep -E '[[:space:]]_?(BIO_|SSL_|ERR_|OPENSSL_)' >/dev/null; then
  printf '%s\n' 'OpenSSL functions must be resolved through the provider module table' >&2
  exit 1
fi
