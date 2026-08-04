#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

FLYOLOGY_DEFAULT=lightweight \
FLYOLOGY_LOOP_POOL_SIZE=2 \
  "$project_root/showcases/prepare-rts.sh" >/dev/null

(
  cd "$showcase_root"
  "$alr" exec -- env -u GPR_CONFIG gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P showcases.gpr \
    buffer_handoff.adb
)

printf '%s\n' '== buffer_handoff: same group =='
"$showcase_root/bin/buffer_handoff" same
printf '%s\n' '== buffer_handoff: cross group =='
"$showcase_root/bin/buffer_handoff" cross
