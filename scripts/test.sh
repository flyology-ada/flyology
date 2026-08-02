#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

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
if GNATEVL_SANITIZER=unknown \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "unknown sanitizer configuration was accepted" >&2
  exit 1
fi
if GNATEVL_LOOP_PLACEMENT=unknown \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "unknown loop-thread placement was accepted" >&2
  exit 1
fi
if GNATEVL_LOOP_PLACEMENT=none GNATEVL_LOOP_PLACEMENT_MAP=0:0 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "loop-thread map without a policy was accepted" >&2
  exit 1
fi
if GNATEVL_LOOP_PLACEMENT=advisory GNATEVL_LOOP_PLACEMENT_MAP=0:0 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "zero Darwin advisory tag was accepted" >&2
  exit 1
fi
if GNATEVL_LOOP_PLACEMENT=advisory GNATEVL_LOOP_PLACEMENT_MAP=0:1,0:2 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "duplicate loop-thread map group was accepted" >&2
  exit 1
fi
case "$(uname -s):$(uname -m)" in
  Linux:*)
    if placement_error=$(GNATEVL_LOOP_PLACEMENT=strict \
      GNATEVL_LOOP_PLACEMENT_MAP=0:2147483647 \
      "$project_root/scripts/prepare-rts.sh" 2>&1)
    then
      printf '%s\n' "unavailable Linux placement CPU was accepted" >&2
      exit 1
    fi
    case "$placement_error" in
      *"outside this process's allowed Linux set"*) ;;
      *)
        printf '%s\n' "unavailable Linux CPU had no clear diagnostic" >&2
        exit 1
        ;;
    esac
    ;;
  Darwin:arm64)
    if GNATEVL_LOOP_PLACEMENT=advisory GNATEVL_LOOP_PLACEMENT_MAP=0:1 \
      "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
    then
      printf '%s\n' "unsupported arm64 Darwin affinity tag was accepted" >&2
      exit 1
    fi
    ;;
esac

for test_main in \
  cancellation_wake_smoke \
  connection_lifecycle_smoke \
  descriptor_ownership_smoke \
  dns_smoke \
  dns_parser_smoke \
  execution_groups_smoke \
  fairness_smoke \
  files_smoke \
  io_smoke \
  io_starvation_smoke \
  lazy_event_start_smoke \
  lifecycle_smoke \
  loop_thread_placement_smoke \
  observability_native_smoke \
  observability_smoke \
  priority_semantics_smoke \
  process_exit_live_task_smoke \
  process_exec_child_smoke \
  process_lifecycle_smoke \
  ready_queue_smoke \
  runtime_smoke \
  semantic_parity_smoke \
  stack_pool_smoke \
  stack_size_parity_smoke \
  stall_watchdog_native_smoke \
  stall_watchdog_smoke \
  structured_server_smoke \
  thread_affinity_smoke \
  timer_heap_smoke \
  tcp_native_smoke \
  wait_any_smoke
do
  run_gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P tests/runtime_smoke.gpr \
    "$test_main.adb"
  case "$test_main" in
    dns_smoke)
      "$project_root/scripts/run-with-timeout.sh" 20 \
        "$project_root/tests/bin/$test_main"
      ;;
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

#  Exercise a compiled project-level policy independently from the public
#  pre-start API. Darwin tags are advisory; Linux masks are strict and use the
#  first CPU from this process's allowed set.
case "$(uname -s)" in
  Darwin)
    if [ "$(uname -m)" = arm64 ]; then
      loop_placement=none
    else
      loop_placement=advisory
      loop_placement_value=77
    fi
    ;;
  Linux)
    loop_placement=strict
    loop_placement_value=$(awk '/Cpus_allowed_list:/ {
      split($2, ranges, ","); split(ranges[1], first, "-"); print first[1]; exit
    }' /proc/self/status)
    ;;
esac
if [ "$loop_placement" != none ]; then
  GNATEVL_DEFAULT=native \
  GNATEVL_LOOP_PLACEMENT="$loop_placement" \
  GNATEVL_LOOP_PLACEMENT_MAP="6:$loop_placement_value" \
    "$project_root/scripts/prepare-rts.sh" >/dev/null
  run_gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P tests/runtime_smoke.gpr \
    loop_thread_project_placement_smoke.adb
  "$project_root/tests/bin/loop_thread_project_placement_smoke"
fi

#  Leave the worktree with the documented compatibility configuration.
GNATEVL_DEFAULT=native \
GNATEVL_LOOP_POOL_SIZE=1 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null

#  Prove that a separate Alire workspace can locate the crate, prepare its own
#  runtime outside the dependency checkout, and build against only public GPR
#  and Ada interfaces.
ALR="$alr" "$project_root/scripts/test-external-consumer.sh"
