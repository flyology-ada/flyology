#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=${ALR:-"$HOME/alr"}

cd "$project_root"

"$alr" build

GNATEVL_DEFAULT=evented "$project_root/scripts/prepare-rts.sh" >/dev/null
"$alr" exec -- gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P tests/runtime_smoke.gpr \
  default_policy_smoke.adb
"$project_root/tests/bin/default_policy_smoke" evented

GNATEVL_DEFAULT=native "$project_root/scripts/prepare-rts.sh" >/dev/null
"$alr" exec -- gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P tests/runtime_smoke.gpr \
  default_policy_smoke.adb
"$project_root/tests/bin/default_policy_smoke" native

for test_main in \
  connection_lifecycle_smoke \
  execution_groups_smoke \
  fairness_smoke \
  files_smoke \
  io_smoke \
  io_starvation_smoke \
  lifecycle_smoke \
  runtime_smoke \
  stack_size_parity_smoke \
  timer_heap_smoke \
  tcp_native_smoke
do
  "$alr" exec -- gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P tests/runtime_smoke.gpr \
    "$test_main.adb"
  "$project_root/tests/bin/$test_main"
done
