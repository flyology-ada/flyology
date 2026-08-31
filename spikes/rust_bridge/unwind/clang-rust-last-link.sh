#!/bin/bash
set -eu

arguments=()
rust_library=
for argument in "$@"; do
   case "$argument" in
      */libflyology_rust_unwind_spike.a) rust_library=$argument ;;
      -static-libgcc) ;;
      *) arguments+=("$argument") ;;
   esac
done

if [ -z "$rust_library" ]; then
   echo "Rust static library argument was not found" >&2
   exit 1
fi

exec /usr/bin/clang "${arguments[@]}" "$rust_library"
