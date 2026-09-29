#!/bin/sh
set -eu

if [ "${FLYOLOGY_LONG_SOAK:-0}" != 1 ]; then
  printf '%s\n' \
    "long soak is opt-in; rerun with FLYOLOGY_LONG_SOAK=1" >&2
  exit 2
fi

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

: "${FLYOLOGY_STRESS_SEEDS:=101 211 307 401 503 601 701 809 907 1009 2003 3001 4001 5003 6007 7001}"
: "${FLYOLOGY_STRESS_BATCHES:=250}"
: "${FLYOLOGY_STRESS_WIDTH:=64}"
: "${FLYOLOGY_STRESS_TIMEOUT:=1800}"
: "${FLYOLOGY_STRESS_FAULTS:=0}"

export FLYOLOGY_STRESS_SEEDS FLYOLOGY_STRESS_BATCHES FLYOLOGY_STRESS_WIDTH
export FLYOLOGY_STRESS_TIMEOUT FLYOLOGY_STRESS_FAULTS

exec "$project_root/scripts/stress.sh"
