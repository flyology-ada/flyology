#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf '%s\n' "usage: check-atomic-store-c-boundary.sh ARCHIVE COMPILER_FAMILY" >&2
  exit 2
fi

archive=$1
compiler_family=$2

if [ ! -f "$archive" ]; then
  printf '%s\n' "atomic-store archive not found: $archive" >&2
  exit 1
fi

if ! symbol_table=$(nm -g "$archive"); then
  printf '%s\n' "could not inspect atomic-store archive: $archive" >&2
  exit 1
fi
symbols=$(printf '%s\n' "$symbol_table" | awk '
  /_?flyology_atomic_store_release_/ && $(NF - 1) != "U" {
    name=$NF
    sub(/^_/, "", name)
    print name
  }
' | sort -u)
compatibility_symbols=$(printf '%s\n' "$symbol_table" | awk '
  /_?flyology_atomic_store_release_/ {
    name=$NF
    sub(/^_/, "", name)
    print name
  }
' | sort -u)

expected='flyology_atomic_store_release_u32
flyology_atomic_store_release_u64'

case "$compiler_family" in
  gnat-13-14)
    if [ "$symbols" != "$expected" ]; then
      printf '%s\n' "GNAT 13-14 archive has an unexpected release-store C boundary:" >&2
      printf '%s\n' "$symbols" >&2
      exit 1
    fi
    ;;
  gnat-15-plus)
    if [ -n "$compatibility_symbols" ]; then
      printf '%s\n' "GNAT 15+ archive retains the GNAT 13-14 release-store C boundary:" >&2
      printf '%s\n' "$compatibility_symbols" >&2
      exit 1
    fi
    ;;
  *)
    printf '%s\n' "unknown compiler family: $compiler_family" >&2
    exit 2
    ;;
esac

if ! undefined_table=$(nm -u "$archive"); then
  printf '%s\n' "could not inspect atomic-store archive dependencies: $archive" >&2
  exit 1
fi
undefined=$(printf '%s\n' "$undefined_table" | awk '{
  name=$NF
  sub(/^_/, "", name)
  print name
}')

if printf '%s\n' "$undefined" | grep -E '^__atomic_store_(n|4|8)$' >/dev/null; then
  printf '%s\n' "production archive retains an unresolved atomic-store builtin" >&2
  exit 1
fi
