#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=/Users/yrashk/alr

cd "$project_root"

"$alr" build

"$project_root/scripts/prepare-rts.sh" >/dev/null
for test_main in io_smoke runtime_smoke tcp_native_smoke
do
  "$alr" exec -- gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P tests/runtime_smoke.gpr \
    "$test_main.adb"
  "$project_root/tests/bin/$test_main"
done
