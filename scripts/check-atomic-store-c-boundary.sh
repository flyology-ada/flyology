#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: check-atomic-store-c-boundary.sh ARCHIVE" >&2
  exit 2
fi

archive=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(dirname -- "$script_dir")

if grep -R -E -i 'Atomic_Store_(32|64)' "$project_root/src" >/dev/null 2>&1; then
  printf '%s\n' "Ada source bypasses the GNAT 13-compatible release-store boundary" >&2
  exit 1
fi

symbols=$(nm -g "$archive" | awk '
  /_?flyology_atomic_store_release_/ && $(NF - 1) != "U" {
    name=$NF
    sub(/^_/, "", name)
    print name
  }
' | sort -u)

expected='flyology_atomic_store_release_u32
flyology_atomic_store_release_u64'

if [ "$symbols" != "$expected" ]; then
  printf '%s\n' "unexpected release-store C boundary:" >&2
  printf '%s\n' "$symbols" >&2
  exit 1
fi

undefined=$(nm -u "$archive" | awk '{
  name=$NF
  sub(/^_/, "", name)
  print name
}')

if printf '%s\n' "$undefined" | grep -E '^__atomic_store_(n|4|8)$' >/dev/null; then
  printf '%s\n' "production archive retains an unresolved atomic-store builtin" >&2
  exit 1
fi
