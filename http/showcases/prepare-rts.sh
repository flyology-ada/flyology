#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
http_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)

if [ -n "${FLYOLOGY_ROOT:-}" ]; then
  flyology_root=$FLYOLOGY_ROOT
else
  flyology_root=$(CDPATH= cd -- "$http_root/.." && pwd)
fi

if [ -n "${FLYOLOGY_LOOP_POOL_SIZE:-}" ]; then
  loop_pool_size=$FLYOLOGY_LOOP_POOL_SIZE
else
  loop_pool_size=$(getconf _NPROCESSORS_ONLN 2>/dev/null || :)
  if [ -z "$loop_pool_size" ]; then
    loop_pool_size=$(sysctl -n hw.logicalcpu 2>/dev/null || printf '%s' 1)
  fi
  if [ "$loop_pool_size" -gt 128 ]; then
    loop_pool_size=128
  fi
fi

FLYOLOGY_RTS_DIR="$http_root/build/rts" \
FLYOLOGY_LOOP_POOL_SIZE=$loop_pool_size \
  "$flyology_root/scripts/prepare-rts.sh"
