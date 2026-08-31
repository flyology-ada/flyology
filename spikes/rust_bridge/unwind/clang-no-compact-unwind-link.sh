#!/bin/bash
set -eu

arguments=()
for argument in "$@"; do
   if [ "$argument" != -static-libgcc ]; then
      arguments+=("$argument")
   fi
done

exec /usr/bin/clang -Wl,-no_compact_unwind "${arguments[@]}"
