#!/bin/sh
set -eu

: "${GNATEVL_ROOT:?Alire did not export GNATEVL_ROOT for the dependency}"
: "${GNATEVL_CONSUMER_RTS:?GNATEVL_CONSUMER_RTS is required}"
: "${GNATEVL_CONSUMER_DEFAULT:?GNATEVL_CONSUMER_DEFAULT is required}"

GNATEVL_RTS_DIR="$GNATEVL_CONSUMER_RTS" \
GNATEVL_DEFAULT="$GNATEVL_CONSUMER_DEFAULT" \
  "$GNATEVL_ROOT/scripts/prepare-rts.sh" >/dev/null
