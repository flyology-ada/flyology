#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=${ALR:-"$HOME/alr"}

cd "$project_root"

run_gprbuild () {
  if [ "$(uname -s)" = Darwin ]; then
    compiler_sysroot=$("$alr" exec -- gcc -print-sysroot)
    if [ -z "$compiler_sysroot" ] || [ ! -d "$compiler_sysroot" ]; then
      current_sysroot=$(xcrun --sdk macosx --show-sdk-path)
      "$alr" exec -- gprbuild "$@" \
        -largs "-Wl,-syslibroot,$current_sysroot" -nodefaultrpaths
      return
    fi
    "$alr" exec -- gprbuild "$@" -largs -nodefaultrpaths
    return
  fi
  "$alr" exec -- gprbuild "$@"
}

"$alr" build

GNATEVL_DEFAULT=evented "$project_root/scripts/prepare-rts.sh" >/dev/null
run_gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P tests/runtime_smoke.gpr \
  default_policy_smoke.adb
"$project_root/tests/bin/default_policy_smoke" evented

GNATEVL_DEFAULT=native "$project_root/scripts/prepare-rts.sh" >/dev/null
run_gprbuild \
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
  lazy_event_start_smoke \
  lifecycle_smoke \
  observability_native_smoke \
  observability_smoke \
  ready_queue_smoke \
  runtime_smoke \
  semantic_parity_smoke \
  stack_size_parity_smoke \
  thread_affinity_smoke \
  timer_heap_smoke \
  tcp_native_smoke
do
  run_gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P tests/runtime_smoke.gpr \
    "$test_main.adb"
  "$project_root/tests/bin/$test_main"
done
