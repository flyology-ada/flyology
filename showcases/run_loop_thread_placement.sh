#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

"$project_root/scripts/prepare-rts.sh" >/dev/null
if [ "$(uname -s)" = Darwin ]; then
  "$alr" exec -- gprbuild \
    --RTS="$project_root/build/rts" \
    -f -P "$project_root/showcases/showcases.gpr" \
    loop_thread_placement.adb -largs -nodefaultrpaths
else
  "$alr" exec -- gprbuild \
    --RTS="$project_root/build/rts" \
    -f -P "$project_root/showcases/showcases.gpr" \
    loop_thread_placement.adb
fi
"$project_root/showcases/bin/loop_thread_placement"
