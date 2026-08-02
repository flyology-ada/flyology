#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
comparison_connections=${1:-1000}
scale_connections=${2:-10000}

case "$comparison_connections" in
  ''|*[!0-9]*|0)
    printf '%s\n' "COMPARISON must be a positive integer: $comparison_connections" >&2
    exit 2
    ;;
esac
case "$scale_connections" in
  ''|*[!0-9]*|0)
    printf '%s\n' "SCALE must be a positive integer: $scale_connections" >&2
    exit 2
    ;;
esac

if [ "$comparison_connections" -gt "$scale_connections" ]; then
  largest_run=$comparison_connections
else
  largest_run=$scale_connections
fi
required_descriptors=$((2 * largest_run + 64))
descriptor_limit=$(ulimit -n)

if [ "$descriptor_limit" != unlimited ] \
  && [ "$descriptor_limit" -lt "$required_descriptors" ]
then
  ulimit -n "$required_descriptors" 2>/dev/null || true
  descriptor_limit=$(ulimit -n)
fi

if [ "$descriptor_limit" != unlimited ] \
  && [ "$descriptor_limit" -lt "$required_descriptors" ]
then
  printf '%s\n' \
    "connection-density showcase needs at least $required_descriptors open descriptors; current limit is $descriptor_limit." \
    "Raise the file-descriptor limit or pass a smaller SCALE (and COMPARISON)." >&2
  exit 2
fi

printf '%s\n' \
  "Both modes use real socket pairs and request the same 16 KiB task stack." \
  "The sample is taken after every task reaches its receive-call boundary." \
  "RSS includes the Ada task state common to both; compare OS threads and address space."

printf '%s\n' \
  "== lightweight scale run: $scale_connections live socket connections =="
"$showcase_root/bin/connection_density" lightweight "$scale_connections"

printf '\n%s\n' \
  "== same-load comparison: $comparison_connections connections =="
"$showcase_root/bin/connection_density" lightweight "$comparison_connections"
"$showcase_root/bin/connection_density" native "$comparison_connections"

printf '\n%s\n' \
  "The scale run does not create $scale_connections pthreads: that commonly exceeds host thread limits." \
  "Pass smaller or larger counts as: run_connection_density.sh COMPARISON SCALE."
