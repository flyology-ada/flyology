#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=${1:-$("$project_root/scripts/find-alr.sh")}

if [ -n "${GNAT_NATIVE_ALIRE_PREFIX:-}" ]; then
  compiler_prefix=$GNAT_NATIVE_ALIRE_PREFIX
else
  #  The first call may synchronize a freshly copied consumer and print notes.
  #  Resolve from the Flyology crate, not an arbitrary caller crate whose
  #  lockfile may name a toolchain installation unavailable on this host.
  #  Alire recommends a second quiet printenv for machine parsing.
  compiler_prefix=$(
    cd "$project_root"
    "$alr" --non-interactive printenv --unix >/dev/null
    "$alr" --non-interactive -q printenv --unix |
      sed -n 's/^export GNAT_NATIVE_ALIRE_PREFIX="\([^"]*\)"$/\1/p'
  )
fi

if [ -z "$compiler_prefix" ] || [ ! -x "$compiler_prefix/bin/gcc" ]; then
  printf '%s\n' \
    "Alire did not select a usable gnat_native compiler: $compiler_prefix" \
    >&2
  exit 1
fi

printf '%s\n' "$compiler_prefix"
