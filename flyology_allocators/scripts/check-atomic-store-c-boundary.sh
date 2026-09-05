#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
   printf '%s\n' "usage: check-atomic-store-c-boundary.sh ARCHIVE" >&2
   exit 2
fi

archive=$1
symbols=$(nm -g "$archive" | awk '
   /_?flyology_allocators_atomic_store_release_/ && $(NF - 1) != "U" {
      name=$NF
      sub(/^_/, "", name)
      print name
   }
' | sort -u)

if [ "$symbols" != "flyology_allocators_atomic_store_release_u32" ]; then
   printf '%s\n' "unexpected standalone release-store C boundary: $symbols" >&2
   exit 1
fi

undefined=$(nm -u "$archive" | awk '{
   name=$NF
   sub(/^_/, "", name)
   print name
}')

if printf '%s\n' "$undefined" | grep -E '^__atomic_store_(n|4|8)$' >/dev/null; then
   printf '%s\n' "standalone archive retains an unresolved atomic-store builtin" >&2
   exit 1
fi
