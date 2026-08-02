#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=${1:-$("$project_root/scripts/find-alr.sh")}

if [ -n "${GNAT_NATIVE_ALIRE_PREFIX:-}" ]; then
  compiler_prefix=$GNAT_NATIVE_ALIRE_PREFIX
else
  #  The first call may synchronize a freshly copied consumer and print notes.
  #  Alire explicitly recommends a second quiet printenv for machine parsing.
  "$alr" --non-interactive printenv --unix >/dev/null
  compiler_prefix=$("$alr" --non-interactive -q printenv --unix |
    sed -n 's/^export GNAT_NATIVE_ALIRE_PREFIX="\([^"]*\)"$/\1/p')
fi

compiler_package=${compiler_prefix##*/}
case "$compiler_package" in
  gnat_native_13.2.2_*) printf '%s\n' 13.2.2 ;;
  gnat_native_14.1.3_*) printf '%s\n' 14.1.3 ;;
  gnat_native_14.2.1_*) printf '%s\n' 14.2.1 ;;
  gnat_native_15.1.2_*) printf '%s\n' 15.1.2 ;;
  gnat_native_15.3.1_*) printf '%s\n' 15.3.1 ;;
  gnat_native_16.1.0_*) printf '%s\n' 16.1.0 ;;
  *)
    printf '%s\n' \
      "unsupported or unidentified Alire gnat_native prefix: $compiler_prefix" \
      >&2
    exit 1
    ;;
esac
