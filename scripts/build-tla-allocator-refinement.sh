#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

case "$#" in
  0) alire=${ALR:-$("$project_root/scripts/find-alr.sh")} ;;
  1) alire=$1 ;;
  *)
    printf '%s\n' "usage: build-tla-allocator-refinement.sh [ALR]" >&2
    exit 2
    ;;
esac

cd "$project_root"
"$alire" exec -- \
  "$project_root/flyology_allocators/scripts/configure-atomic-store-family.sh"
"$alire" exec -- gprbuild \
  -P flyology_allocators/tests/allocator_tests.gpr \
  -p allocator_refinement.adb
