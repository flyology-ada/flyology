#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
rts="$project_root/build/rts"
loop_pool_size=${FLYOLOGY_LOOP_POOL_SIZE:-2}
marker_value='Flyology prepared RTS version 1'

"$project_root/showcases/prepare-alire.sh" >/dev/null
FLYOLOGY_DEFAULT=lightweight FLYOLOGY_LOOP_POOL_SIZE="$loop_pool_size" \
  "$project_root/showcases/prepare-rts.sh" >/dev/null

if [ ! -f "$rts/.flyology-rts-root" ] \
  || [ "$(sed -n '1p' "$rts/.flyology-rts-root")" != "$marker_value" ] \
  || [ ! -f "$rts/adalib/libgnat.a" ] \
  || [ ! -f "$rts/adalib/libgnarl.a" ] \
  || [ ! -f "$rts/adainclude/s-stalib.adb" ]; then
  printf '%s\n' \
    "refusing to benchmark without a complete marker-verified Flyology RTS: $rts" >&2
  exit 1
fi
(
  cd "$project_root/showcases"
  FLYOLOGY_SHOWCASE_PROFILE=release \
    "$alr" exec -- env -u GPR_CONFIG gprbuild \
      --RTS="$rts" \
      -f \
      -P showcases.gpr \
      synchronization_benchmark.adb
)

printf '%s\n' \
  "flyology_commit=$(git -C "$project_root" rev-parse HEAD)" \
  "runtime=$rts" \
  "runtime_marker=$marker_value" \
  "execution_default=lightweight" \
  "loop_pool_size=$loop_pool_size" \
  "build_profile=release"
"$project_root/showcases/bin/synchronization_benchmark" "$@"
