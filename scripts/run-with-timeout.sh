#!/bin/sh
set -u

if [ "$#" -lt 2 ]; then
  printf '%s\n' "usage: run-with-timeout.sh SECONDS COMMAND [ARG ...]" >&2
  exit 2
fi

perl=$(command -v perl 2>/dev/null || true)
if [ -z "$perl" ]; then
  printf '%s\n' \
    "run-with-timeout.sh: Perl 5 with core POSIX support is required" >&2
  exit 2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$perl" "$script_dir/run-with-timeout.pl" "$@"
