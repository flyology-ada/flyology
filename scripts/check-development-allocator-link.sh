#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: check-development-allocator-link.sh BINARY" >&2
  exit 2
fi

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace="$project_root/tests/development"
lock_file="$workspace/alire/alire.lock"
binary=$1

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
"$resolved_allocator/scripts/check-atomic-store-c-boundary.sh" "$allocator_archive"

symbols=$(nm -g "$binary")
if ! printf '%s\n' "$symbols" | awk '
  /_?flyology_allocators_atomic_store_release_u32$/ && $(NF - 1) != "U" { found = 1 }
  END { exit found ? 0 : 1 }
'; then
  printf '%s\n' "behavioral link did not include the local allocator release-store leaf" >&2
  exit 1
fi

undefined=$(nm -u "$binary" | awk '{
  name=$NF
  sub(/^_/, "", name)
  print name
}')
if printf '%s\n' "$undefined" | grep -E '^__atomic_store_(n|4|8)$' >/dev/null; then
  printf '%s\n' "behavioral link retains an unresolved atomic-store builtin" >&2
  exit 1
fi
