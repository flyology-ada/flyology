#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

check_profile () {
  crate=$1
  config=$2

  if [ ! -f "$config" ]; then
    printf '%s\n' "development workspace omitted $crate configuration" >&2
    exit 1
  fi
  if ! grep -F 'Build_Profile : Build_Profile_Kind := "development";' \
    "$config" >/dev/null
  then
    printf '%s\n' "development workspace selected a non-development $crate profile" >&2
    exit 1
  fi
}

check_profile flyology "$project_root/config/flyology_config.gpr"
check_profile flyology_allocators \
  "$project_root/flyology_allocators/config/flyology_allocators_config.gpr"
