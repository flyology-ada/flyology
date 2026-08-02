#!/bin/sh
set -eu

if [ "${GNATEVL_LONG_SOAK:-0}" != 1 ]; then
  printf '%s\n' \
    "long soak is opt-in; rerun with GNATEVL_LONG_SOAK=1" >&2
  exit 2
fi

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

: "${GNATEVL_STRESS_SEEDS:=101 211 307 401 503 601 701 809 907 1009 2003 3001 4001 5003 6007 7001}"
: "${GNATEVL_STRESS_BATCHES:=250}"
: "${GNATEVL_STRESS_WIDTH:=64}"
: "${GNATEVL_STRESS_TIMEOUT:=1800}"
: "${GNATEVL_STRESS_FAULTS:=0}"

export GNATEVL_STRESS_SEEDS GNATEVL_STRESS_BATCHES GNATEVL_STRESS_WIDTH
export GNATEVL_STRESS_TIMEOUT GNATEVL_STRESS_FAULTS

exec "$project_root/scripts/stress.sh"
