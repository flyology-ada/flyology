#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

"$project_root/showcases/prepare-alire.sh" >/dev/null
FLYOLOGY_DEFAULT=native \
  "$project_root/showcases/prepare-rts.sh" >/dev/null
(
  cd "$project_root/showcases"
  "$alr" exec -- env -u GPR_CONFIG gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P data_structures_allocator_memory.gpr
)

runner=$project_root/showcases/bin/data_structures_allocator_memory
printf 'Built runnable allocator memory trace: %s\n' "$runner"
"$runner" "$@"
