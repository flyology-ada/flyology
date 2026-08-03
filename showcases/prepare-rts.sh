#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

#  The kitchen-sink server is intended to demonstrate concurrent lightweight
#  request handling, so its automatic group pool follows the host's online CPU
#  count. Keep an explicit environment override for reproducible benchmarks
#  and clamp automatic detection to Flyology's shared-group limit.
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

FLYOLOGY_LOOP_POOL_SIZE=$loop_pool_size \
  "$project_root/scripts/prepare-rts.sh"
