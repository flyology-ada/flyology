#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CRATE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ -n "${FLYOLOGY_ALLOCATORS_TARGET:-}" ]; then
   compiler="$FLYOLOGY_ALLOCATORS_TARGET-gcc"
else
   compiler=gcc
fi

compiler_version=$("$compiler" -dumpfullversion)
case "$compiler_version" in
   13.2.0|14.1.0|14.2.0)
      source_dir=src/atomic_stores/gnat-13-14/
      languages='("Ada", "C")'
      ;;
   15.0.1|15.1.0|15.3.0|16.1.0|16.2.0)
      source_dir=src/atomic_stores/gnat-15-plus/
      languages='("Ada")'
      ;;
   *)
      printf '%s\n' "unsupported standalone allocator compiler version: $compiler_version" >&2
      exit 1
      ;;
esac

mkdir -p "$CRATE_ROOT/config"
config_file="$CRATE_ROOT/config/flyology_allocators_atomic_store_config.gpr"
config_temp=$(mktemp "$CRATE_ROOT/config/.flyology_allocators_atomic_store_config.gpr.XXXXXX")
trap 'rm -f -- "$config_temp"' EXIT HUP INT TERM
printf '%s\n' \
   '--  Generated from the compiler selected by the standalone build.' \
   'abstract project Flyology_Allocators_Atomic_Store_Config is' \
   "   Compiler_Version := \"$compiler_version\";" \
   "   Languages := $languages;" \
   "   Source_Dir := \"$source_dir\";" \
   'end Flyology_Allocators_Atomic_Store_Config;' >"$config_temp"
mv "$config_temp" "$config_file"
trap - EXIT HUP INT TERM
