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

if GNATEVL_LOOP_POOL_SIZE=0 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "invalid zero-sized event-loop pool was accepted" >&2
  exit 1
fi
if GNATEVL_PLACEMENT=unknown \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "unknown event-loop placement policy was accepted" >&2
  exit 1
fi

for test_main in \
  cancellation_wake_smoke \
  connection_lifecycle_smoke \
  descriptor_ownership_smoke \
  execution_groups_smoke \
  fairness_smoke \
  files_smoke \
  io_smoke \
  io_starvation_smoke \
  lazy_event_start_smoke \
  lifecycle_smoke \
  observability_native_smoke \
  observability_smoke \
  priority_semantics_smoke \
  process_exit_live_task_smoke \
  process_exec_child_smoke \
  process_lifecycle_smoke \
  ready_queue_smoke \
  runtime_smoke \
  semantic_parity_smoke \
  stack_size_parity_smoke \
  stall_watchdog_native_smoke \
  stall_watchdog_smoke \
  thread_affinity_smoke \
  timer_heap_smoke \
  tcp_native_smoke
do
  run_gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P tests/runtime_smoke.gpr \
    "$test_main.adb"
  case "$test_main" in
    process_lifecycle_smoke|process_exit_live_task_smoke)
      "$project_root/scripts/run-with-timeout.sh" 10 \
        "$project_root/tests/bin/$test_main"
      ;;
    *)
      "$project_root/tests/bin/$test_main"
      ;;
  esac
done

#  Exercise automatic placement separately because the pool policy is compiled
#  into the prepared RTS. The ordinary suite above intentionally retains the
#  compatibility default of one lazily created loop.
GNATEVL_DEFAULT=native \
GNATEVL_LOOP_POOL_SIZE=3 \
GNATEVL_PLACEMENT=round_robin \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
run_gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P tests/runtime_smoke.gpr \
  loop_pool_smoke.adb
"$project_root/tests/bin/loop_pool_smoke"

#  Leave the worktree with the documented compatibility configuration.
GNATEVL_DEFAULT=native \
GNATEVL_LOOP_POOL_SIZE=1 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
