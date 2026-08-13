#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=${1:-$("$project_root/scripts/find-alr.sh")}

native_prefix=${GNAT_NATIVE_ALIRE_PREFIX:-}
flyology_prefix=${GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX:-}

if [ -z "$native_prefix" ] && [ -z "$flyology_prefix" ]; then
  #  The first call may synchronize a freshly copied consumer and print notes.
  #  Resolve from the Flyology crate, not an arbitrary caller crate whose
  #  lockfile may name a toolchain installation unavailable on this host.
  #  Alire recommends a second quiet printenv for machine parsing.
  compiler_environment=$(
    cd "$project_root"
    "$alr" --non-interactive printenv --unix >/dev/null
    "$alr" --non-interactive -q printenv --unix
  )
  native_prefix=$(printf '%s\n' "$compiler_environment" |
    sed -n 's/^export GNAT_NATIVE_ALIRE_PREFIX="\([^"]*\)"$/\1/p')
  flyology_prefix=$(printf '%s\n' "$compiler_environment" |
    sed -n 's/^export GNAT_FLYOLOGY_NATIVE_ALIRE_PREFIX="\([^"]*\)"$/\1/p')
fi

if [ -n "$native_prefix" ] && [ -n "$flyology_prefix" ] \
  && [ "$native_prefix" != "$flyology_prefix" ]; then
  printf '%s\n' \
    "Alire selected multiple Flyology-supported GNAT compiler prefixes" \
    "gnat_native: $native_prefix" \
    "gnat_flyology_native: $flyology_prefix" >&2
  exit 1
fi

compiler_prefix=${flyology_prefix:-$native_prefix}
compiler_package=${compiler_prefix##*/}
case "$compiler_package" in
  gnat_native_*_*|gnat_flyology_native_*_*) ;;
  *)
    printf '%s\n' \
      "Alire selected an unsupported GNAT compiler package: $compiler_prefix" \
      >&2
    exit 1
    ;;
esac

if [ ! -x "$compiler_prefix/bin/gcc" ]; then
  printf '%s\n' \
    "Alire did not select a usable Flyology-supported GNAT compiler: $compiler_prefix" \
    >&2
  exit 1
fi

printf '%s\n' "$compiler_prefix"
