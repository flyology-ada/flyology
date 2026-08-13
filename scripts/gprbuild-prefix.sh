#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=${1:-$("$project_root/scripts/find-alr.sh")}

if [ -n "${GPRBUILD_ALIRE_PREFIX:-}" ]; then
  gprbuild_prefix=$GPRBUILD_ALIRE_PREFIX
else
  #  Resolve the companion GPRbuild installation from the same Flyology
  #  environment that selects the supported GNAT provider. This also works
  #  when preparation is invoked directly rather than through `alr exec`.
  gprbuild_prefix=$(
    cd "$project_root"
    "$alr" --non-interactive printenv --unix >/dev/null
    "$alr" --non-interactive -q printenv --unix |
      sed -n 's/^export GPRBUILD_ALIRE_PREFIX="\([^"]*\)"$/\1/p'
  )
fi

if [ -z "$gprbuild_prefix" ] \
  || [ ! -x "$gprbuild_prefix/bin/gprconfig" ]; then
  printf '%s\n' \
    "Alire did not select a usable GPRbuild toolchain: $gprbuild_prefix" \
    >&2
  exit 1
fi

printf '%s\n' "$gprbuild_prefix"
