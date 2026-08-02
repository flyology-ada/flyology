#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
comparison_connections=${1:-1000}
scale_connections=${2:-10000}

ulimit -n 65536 2>/dev/null || true

printf '%s\n' \
  "Both modes use real socket pairs and the same 32 KiB task stack." \
  "RSS includes the Ada task state common to both; compare OS threads and address space."

printf '%s\n' \
  "== evented scale run: $scale_connections live socket connections =="
"$showcase_root/bin/connection_density" evented "$scale_connections"

printf '\n%s\n' \
  "== same-load comparison: $comparison_connections connections =="
"$showcase_root/bin/connection_density" evented "$comparison_connections"
"$showcase_root/bin/connection_density" native "$comparison_connections"

printf '\n%s\n' \
  "The scale run does not create $scale_connections pthreads: that commonly exceeds host thread limits." \
  "Pass smaller or larger counts as: run_connection_density.sh COMPARISON SCALE."
