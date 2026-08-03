#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
showcase_root="$project_root/showcases"
alr=$("$project_root/scripts/find-alr.sh")

"$project_root/scripts/prepare-rts.sh" >/dev/null
cd "$showcase_root"
if [ "$(uname -s)" = Darwin ]; then
  "$alr" exec -- gprbuild \
    --RTS="$project_root/build/rts" \
    -f -P showcases.gpr \
    loop_thread_placement.adb -largs -nodefaultrpaths
else
  "$alr" exec -- gprbuild \
    --RTS="$project_root/build/rts" \
    -f -P showcases.gpr \
    loop_thread_placement.adb
fi
"$project_root/showcases/bin/loop_thread_placement"
