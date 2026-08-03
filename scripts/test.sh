#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

cd "$project_root"

#  DNS lifecycle regressions observe the receive-loop boundary. The project
#  default is false, so normal builds compile the observation calls away.
FLYOLOGY_DNS_TEST_HOOKS=true
export FLYOLOGY_DNS_TEST_HOOKS

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

FLYOLOGY_DEFAULT=lightweight "$project_root/scripts/prepare-rts.sh" >/dev/null
run_gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P tests/runtime_smoke.gpr \
  default_policy_smoke.adb
"$project_root/tests/bin/default_policy_smoke" lightweight

FLYOLOGY_DEFAULT=native "$project_root/scripts/prepare-rts.sh" >/dev/null
run_gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P tests/runtime_smoke.gpr \
  default_policy_smoke.adb
"$project_root/tests/bin/default_policy_smoke" native

if FLYOLOGY_LOOP_POOL_SIZE=0 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "invalid zero-sized event-loop pool was accepted" >&2
  exit 1
fi
if FLYOLOGY_PLACEMENT=unknown \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "unknown event-loop placement policy was accepted" >&2
  exit 1
fi
if FLYOLOGY_SANITIZER=unknown \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "unknown sanitizer configuration was accepted" >&2
  exit 1
fi
if FLYOLOGY_TEST_DENY_IO_URING=unknown \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "unknown io_uring test denial setting was accepted" >&2
  exit 1
fi
if FLYOLOGY_LOOP_PLACEMENT=unknown \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "unknown loop-thread placement was accepted" >&2
  exit 1
fi
if FLYOLOGY_LOOP_PLACEMENT=none FLYOLOGY_LOOP_PLACEMENT_MAP=0:0 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "loop-thread map without a policy was accepted" >&2
  exit 1
fi
if FLYOLOGY_LOOP_PLACEMENT=advisory FLYOLOGY_LOOP_PLACEMENT_MAP=0:0 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "zero Darwin advisory tag was accepted" >&2
  exit 1
fi
if FLYOLOGY_LOOP_PLACEMENT=advisory FLYOLOGY_LOOP_PLACEMENT_MAP=0:1,0:2 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
then
  printf '%s\n' "duplicate loop-thread map group was accepted" >&2
  exit 1
fi
case "$(uname -s):$(uname -m)" in
  Linux:*)
    if placement_error=$(FLYOLOGY_LOOP_PLACEMENT=strict \
      FLYOLOGY_LOOP_PLACEMENT_MAP=0:2147483647 \
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
    if FLYOLOGY_LOOP_PLACEMENT=advisory FLYOLOGY_LOOP_PLACEMENT_MAP=0:1 \
      "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1
    then
      printf '%s\n' "unsupported arm64 Darwin affinity tag was accepted" >&2
      exit 1
    fi
    ;;
esac

if [ "$(uname -s)" = Linux ]; then
  mkdir -p "$project_root/build/tests"
  cc -Wall -Wextra -Werror \
    "$project_root/tests/probes/linux_abi_probe.c" \
    "$project_root/runtime/native/platform.c" \
    -pthread \
    -o "$project_root/build/tests/linux_syscall_probe"
  "$project_root/build/tests/linux_syscall_probe"
fi

for test_main in \
  cancellation_wake_smoke \
  connection_lifecycle_smoke \
  descriptor_ownership_smoke \
  dns_smoke \
  dns_parser_smoke \
  execution_groups_smoke \
  fairness_smoke \
  file_cancellation_smoke \
  files_smoke \
  flyology-counter_policy_smoke \
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
  suspension_object_smoke \
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
      "$project_root/scripts/run-with-timeout.sh" 60 \
        "$project_root/tests/bin/$test_main"
      ;;
  esac
done

#  Exercise automatic placement separately because the pool policy is compiled
#  into the prepared RTS. The ordinary suite above intentionally retains the
#  compatibility default of one lazily created loop.
FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE=3 \
FLYOLOGY_PLACEMENT=round_robin \
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
  FLYOLOGY_DEFAULT=native \
  FLYOLOGY_LOOP_PLACEMENT="$loop_placement" \
  FLYOLOGY_LOOP_PLACEMENT_MAP="6:$loop_placement_value" \
    "$project_root/scripts/prepare-rts.sh" >/dev/null
  run_gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P tests/runtime_smoke.gpr \
    loop_thread_project_placement_smoke.adb
  "$project_root/tests/bin/loop_thread_project_placement_smoke"
fi

#  Transient accept behavior depends on errno results that are difficult to
#  produce deterministically from a client. Exercise the production retry,
#  deadline, cancellation, and structural-error paths through the test-only C
#  seam, with an outer timeout so a retry regression cannot hang CI.
FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE=1 \
FLYOLOGY_TEST_FAULTS=1 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
run_gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P tests/runtime_smoke.gpr \
  accept_transient_smoke.adb
"$project_root/scripts/run-with-timeout.sh" 30 \
  "$project_root/tests/bin/accept_transient_smoke"

#  Leave the worktree with the documented compatibility configuration.
FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE=1 \
FLYOLOGY_TEST_FAULTS=0 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null

#  Prove that a separate Alire workspace can locate the crate, prepare its own
#  runtime outside the dependency checkout, and build against only public GPR
#  and Ada interfaces.
ALR="$alr" "$project_root/scripts/test-external-consumer.sh"
