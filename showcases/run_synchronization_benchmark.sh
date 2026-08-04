#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

"$project_root/showcases/prepare-alire.sh" >/dev/null
FLYOLOGY_DEFAULT=lightweight FLYOLOGY_LOOP_POOL_SIZE=2 \
  "$project_root/showcases/prepare-rts.sh" >/dev/null
(
  cd "$project_root/showcases"
  FLYOLOGY_SHOWCASE_PROFILE=release \
    "$alr" exec -- env -u GPR_CONFIG gprbuild \
      --RTS="$project_root/build/rts" \
      -f \
      -P showcases.gpr \
      synchronization_benchmark.adb
)

"$project_root/showcases/bin/synchronization_benchmark" "$@"
