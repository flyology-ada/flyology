#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf '%s\n' "usage: check-development-allocator-link.sh BINARY COMPILER_FAMILY" >&2
  exit 2
fi

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace="$project_root/tests/development"
lock_file="$workspace/alire/alire.lock"
binary=$1
compiler_family=$2

if [ ! -f "$binary" ]; then
  printf '%s\n' "behavioral link binary not found: $binary" >&2
  exit 1
fi

if grep -F '[[pins]]' "$project_root/alire.toml" >/dev/null; then
  printf '%s\n' "publishable root manifest contains a development pin" >&2
  exit 1
fi
if [ ! -f "$lock_file" ]; then
  printf '%s\n' "development workspace has no resolved Alire lock file" >&2
  exit 1
fi

allocator_link=$(awk '
  $0 == "[[solution.state]]" { wanted = 0; linked = 0; next }
  $0 == "crate = \"flyology_allocators\"" { wanted = 1; next }
  wanted && $0 == "[solution.state.link]" { linked = 1; next }
  wanted && linked && $0 ~ /^path = / {
    value = $0
    sub(/^[^\"]*\"/, "", value)
    sub(/\".*/, "", value)
    print value
    exit
  }
' "$lock_file")
if [ -z "$allocator_link" ]; then
  printf '%s\n' "development workspace did not path-link flyology_allocators" >&2
  exit 1
fi
resolved_allocator=$(CDPATH= cd -- "$workspace/$allocator_link" && pwd)
if [ "$resolved_allocator" != "$project_root/flyology_allocators" ]; then
  printf '%s\n' "development workspace resolved the wrong allocator: $resolved_allocator" >&2
  exit 1
fi

allocator_archive="$resolved_allocator/lib/libflyology_allocators.a"
"$resolved_allocator/scripts/check-atomic-store-c-boundary.sh" \
  "$allocator_archive" "$compiler_family"

symbols=$(nm -g "$binary")
case "$compiler_family" in
  gnat-13-14)
    for required_symbol in \
      flyology_atomic_store_release_u32 \
      flyology_atomic_store_release_u64 \
      flyology_allocators_atomic_store_release_u32
    do
      if ! printf '%s\n' "$symbols" | awk -v wanted="$required_symbol" '
        {
          name=$NF
          sub(/^_/, "", name)
          if (name == wanted && $(NF - 1) != "U") found = 1
        }
        END { exit found ? 0 : 1 }
      '; then
        printf '%s\n' \
          "GNAT 13-14 behavioral link omitted release-store leaf: $required_symbol" >&2
        exit 1
      fi
    done
    ;;
  gnat-15-plus)
    if printf '%s\n' "$symbols" | \
      grep -E '_?flyology(_allocators)?_atomic_store_release_' >/dev/null
    then
      printf '%s\n' "GNAT 15+ behavioral link retains a GNAT 13-14 release-store leaf" >&2
      exit 1
    fi
    ;;
  *)
    printf '%s\n' "unknown compiler family: $compiler_family" >&2
    exit 2
    ;;
esac

undefined=$(nm -u "$binary" | awk '{
  name=$NF
  sub(/^_/, "", name)
  print name
}')
if printf '%s\n' "$undefined" | grep -E '^__atomic_store_(n|4|8)$' >/dev/null; then
  printf '%s\n' "behavioral link retains an unresolved atomic-store builtin" >&2
  exit 1
fi
