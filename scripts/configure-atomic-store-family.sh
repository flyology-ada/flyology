#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: configure-atomic-store-family.sh COMPILER_RELEASE" >&2
  exit 2
fi

compiler_release=$1
case "$compiler_release" in
  13.2.2|14.1.3|14.2.1)
    source_dir=src/atomic_stores/gnat-13-14/
    ;;
  15.1.2|15.3.1|16.1.0|16.2.0)
    source_dir=src/atomic_stores/gnat-15-plus/
    ;;
  *)
    printf '%s\n' "unsupported atomic-store compiler release: $compiler_release" >&2
    exit 1
    ;;
esac

printf '%s\n' \
  '--  Generated from the exact compiler identity validated by Flyology preparation.' \
  'abstract project Flyology_Atomic_Store_Config is' \
  "   Compiler_Release := \"$compiler_release\";" \
  "   Source_Dir := \"$source_dir\";" \
  'end Flyology_Atomic_Store_Config;'
