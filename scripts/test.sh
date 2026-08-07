#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
test_subdir=behavioral
connection_test_subdir=behavioral-connection-hooks
worker_pool_test_subdir=behavioral-worker-pool-hooks
structured_server_test_subdir=behavioral-structured-server-hooks
wall_clock_test_subdir=behavioral-wall-clock-hooks
test_bin="$project_root/tests/bin/$test_subdir"
connection_test_bin="$project_root/tests/bin/$connection_test_subdir"
worker_pool_test_bin="$project_root/tests/bin/$worker_pool_test_subdir"
wall_clock_test_bin="$project_root/tests/bin/$wall_clock_test_subdir"

cd "$project_root"

"$project_root/scripts/test-run-with-timeout.sh"

#  DNS lifecycle regressions observe the receive-loop boundary. The project
#  default is false, so normal builds compile the observation calls away.
FLYOLOGY_DNS_TEST_HOOKS=true
export FLYOLOGY_DNS_TEST_HOOKS

run_gprbuild () {
  if [ "$(uname -s)" = Darwin ]; then
    compiler_sysroot=$("$alr" exec -- gcc -print-sysroot)
    if [ -z "$compiler_sysroot" ] || [ ! -d "$compiler_sysroot" ]; then
      current_sysroot=$(xcrun --sdk macosx --show-sdk-path)
      "$alr" exec -- env -u GPR_CONFIG gprbuild "$@" \
        -largs "-Wl,-syslibroot,$current_sysroot" -nodefaultrpaths
      return
    fi
    "$alr" exec -- env -u GPR_CONFIG gprbuild "$@" -largs -nodefaultrpaths
    return
  fi
  "$alr" exec -- env -u GPR_CONFIG gprbuild "$@"
}

assert_archive_excludes () {
  archive=$1
  pattern=$2
  failure=$3
  if ! archive_symbols=$(nm -g "$archive"); then
    printf '%s\n' "failed to inspect production archive: $archive" >&2
    exit 1
  fi
  if printf '%s\n' "$archive_symbols" | grep -Ei "$pattern" >/dev/null; then
    printf '%s\n' "$failure" >&2
    exit 1
  fi
}

compile_test_mains () {
  test_build_subdir=$1
  test_mains=$2
  set --
  test_count=0
  for test_main in $test_mains; do
    set -- "$@" "$test_main.adb"
    test_count=$((test_count + 1))
  done
  printf '%s\n' "test: COMPILE $test_count programs"
  run_gprbuild \
    --RTS="$project_root/build/rts" \
    --subdirs="$test_build_subdir" \
    -f -c -r -p -j0 \
    -P tests/runtime_smoke.gpr \
    "$@"
}

link_test_mains () {
  test_build_subdir=$1
  test_rts=$2
  test_mains=$3
  set --
  test_count=0
  for test_main in $test_mains; do
    set -- "$@" "$test_main.adb"
    test_count=$((test_count + 1))
  done
  printf '%s\n' "test: LINK $test_count programs"
  run_gprbuild \
    --RTS="$test_rts" \
    --subdirs="$test_build_subdir" \
    -f -b -l -p -j0 \
    -P tests/runtime_smoke.gpr \
    "$@"
}

#  The controller test child lives under tests. Verify that the production
#  archive contains neither that child, controller observers, nor OpenSSL
#  lifetime telemetry.
FLYOLOGY_TLS_TEST_HOOKS=false
export FLYOLOGY_TLS_TEST_HOOKS
"$alr" build
assert_archive_excludes \
  "$project_root/lib/libFlyology.a" \
  'flyology__io__tls__testing|operation_is_active|queued_acquisitions|close_is_in_progress|generation_state|flyology_tls_openssl_live_modules|flyology_test_context_(probe|callback)|flyology_test_worker_|flyology_test_structured_server_' \
  "production library exposes test-only symbols"
FLYOLOGY_TLS_TEST_HOOKS=true
export FLYOLOGY_TLS_TEST_HOOKS
"$alr" build
assert_archive_excludes \
  "$project_root/lib/libFlyology.a" \
  'test_waiting_operations|test_operation_active|test_close_requested' \
  "production library exposes connection-controller test symbols"

FLYOLOGY_DEFAULT=native "$project_root/scripts/prepare-rts.sh" >/dev/null

if [ "$(uname -s)" = Linux ]; then
  runtime_archive="$project_root/build/rts/adalib/libgnarl.a"
  poller_object_dir="$project_root/build/tests/poller-policy-symbols"
  if ! ar -t "$runtime_archive" | grep '^s-flypol[.]o$' >/dev/null; then
    printf '%s\n' "production runtime omitted s-flypol.o" >&2
    exit 1
  fi
  mkdir -p "$poller_object_dir"
  (
    cd "$poller_object_dir"
    ar -x "$runtime_archive" s-flypol.o
  )
  "$project_root/scripts/check-linux-poller-policy-inlining.sh" \
    "$poller_object_dir/s-flypol.o"
fi

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
if [ "$(uname -s)" = Darwin ]; then
  if missing_patch_error=$(FLYOLOGY_TEST_MISSING_MONOTONIC_PATCH=1 \
    "$project_root/scripts/prepare-rts.sh" 2>&1)
  then
    printf '%s\n' "missing Darwin monotonic patch was accepted" >&2
    exit 1
  fi
  case "$missing_patch_error" in
    *"required Darwin monotonic patch is missing"*) ;;
    *)
      printf '%s\n' \
        "missing Darwin monotonic patch had no clear diagnostic" >&2
      exit 1
      ;;
  esac
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

#  Runtime patch application must not depend on the caller's working
#  directory. The showcase crate invokes preparation as an Alire pre-build
#  action, so verify a nested invocation retains a patched GNARL bridge.
(
  cd "$project_root/showcases"
  FLYOLOGY_DEFAULT=native \
    "$project_root/scripts/prepare-rts.sh" >/dev/null
)
if ! nm -g "$project_root/build/rts/adalib/libgnarl.a" | \
     grep 'flyology_runtime_file_io' >/dev/null
then
  printf '%s\n' "nested RTS preparation omitted the Flyology file-I/O bridge" >&2
  exit 1
fi

if [ "$(uname -s)" = Linux ]; then
  mkdir -p "$project_root/build/tests"
  cc -Wall -Wextra -Werror \
    "$project_root/tests/probes/linux_abi_probe.c" \
    "$project_root/runtime/native/platform.c" \
    -pthread \
    -o "$project_root/build/tests/linux_syscall_probe"
  "$project_root/build/tests/linux_syscall_probe"
elif [ "$(uname -s)" = Darwin ]; then
  mkdir -p "$project_root/build/tests"
  cc -std=c11 -Wall -Wextra -Werror \
    "$project_root/tests/probes/darwin_monotonic_probe.c" \
    "$project_root/runtime/native/platform.c" \
    -pthread \
    -o "$project_root/build/tests/darwin_monotonic_probe"
  "$project_root/build/tests/darwin_monotonic_probe"
fi

ordinary_mains='cancellation_wake_smoke
buffer_channel_cancel_smoke
buffers_smoke
channel_reentrancy_child
channel_retention_smoke
closed_descriptor_wait_smoke
connection_admission_smoke
connection_driver_smoke
connection_driver_tls_smoke
connection_lifecycle_smoke
connection_state_model
connection_tls_upgrade_smoke
concurrency_primitives_smoke
context_abi_matrix
descriptor_ownership_smoke
dns_smoke
dns_parser_smoke
dns_parser_matrix
dns_resilience_smoke
dormancy_smoke
execution_groups_smoke
exception_traceback_smoke
fairness_smoke
file_cancellation_smoke
files_smoke
flyology-counter_policy_smoke
flyology-socket_policy-smoke
flyology-structured_server_policy-smoke
flyology-wall_clock_policy-smoke
flyology-wall_clock_waits-smoke
io_smoke
io_starvation_smoke
lazy_event_start_smoke
lifecycle_smoke
lifecycle_churn_smoke
loop_thread_placement_smoke
memory_regions_smoke
observability_native_smoke
observability_smoke
poller_policy_smoke
priority_semantics_smoke
process_exit_live_task_smoke
process_exec_child_smoke
process_lifecycle_smoke
ready_queue_smoke
runtime_smoke
semantic_parity_smoke
stack_guard_violation_child
stack_guard_smoke
stack_pool_smoke
stack_size_limits_child
stack_size_limits_smoke
stack_size_parity_smoke
suspension_object_smoke
task_scope_faults_smoke
task_scopes_smoke
task_results_smoke
task_result_abandon_smoke
stall_watchdog_native_smoke
stall_watchdog_smoke
structured_server_smoke
structured_server_tls_smoke
thread_affinity_smoke
timer_heap_smoke
timer_set_smoke
tls_smoke
tls_alpn_smoke
tls_state_model
tcp_native_smoke
wake_source_state_model
wait_any_smoke
wall_clock_wait_smoke'

pool_mains='loop_pool_smoke
topology_smoke
semantic_conformance_matrix
semantic_termination_matrix'

fault_mains='accept_transient_smoke
connect_transient_smoke
structured_server_reuse_smoke
task_result_publication_smoke'

connection_hook_mains='connection_admission_smoke
connection_state_model
connection_tls_upgrade_smoke
descriptor_ownership_smoke'

worker_pool_hook_mains='concurrency_primitives_smoke
task_scope_faults_smoke'

structured_server_hook_mains=structured_server_abort_smoke

wall_clock_hook_mains=flyology-wall_clock_testing-smoke

ordinary_unhooked_mains=
for test_main in $ordinary_mains; do
  case "$test_main" in
    connection_admission_smoke|connection_state_model|connection_tls_upgrade_smoke|descriptor_ownership_smoke|concurrency_primitives_smoke|task_scope_faults_smoke)
      ;;
    *)
      ordinary_unhooked_mains="$ordinary_unhooked_mains
$test_main"
      ;;
  esac
done

all_test_mains="default_policy_smoke
$ordinary_unhooked_mains
$pool_mains
loop_thread_project_placement_smoke
$fault_mains"
if [ "$(uname -s)" = Linux ]; then
  all_test_mains="$all_test_mains
fault_injection_smoke
linux_poller_fairness_smoke"
fi

#  Compile each hook configuration into its own object directory. The hook
#  projects add different native controller objects, so combining them changes
#  the link closure and runtime behavior of otherwise unrelated tests. The
#  alternate RTS configurations change only private runtime policy units and
#  replace the contents of the same build/rts path. A fresh binder pass checks
#  each compiled ALI closure against the selected RTS before linking.
unset FLYOLOGY_CONNECTION_TEST_HOOKS || :
unset FLYOLOGY_WORKER_POOL_TEST_HOOKS || :
unset FLYOLOGY_STRUCTURED_SERVER_TEST_HOOKS || :
unset FLYOLOGY_WALL_CLOCK_TEST_HOOKS || :
compile_test_mains "$test_subdir" "$all_test_mains"

FLYOLOGY_CONNECTION_TEST_HOOKS=true
export FLYOLOGY_CONNECTION_TEST_HOOKS
compile_test_mains "$connection_test_subdir" "$connection_hook_mains"
unset FLYOLOGY_CONNECTION_TEST_HOOKS

FLYOLOGY_WORKER_POOL_TEST_HOOKS=true
export FLYOLOGY_WORKER_POOL_TEST_HOOKS
compile_test_mains "$worker_pool_test_subdir" "$worker_pool_hook_mains"
unset FLYOLOGY_WORKER_POOL_TEST_HOOKS

FLYOLOGY_STRUCTURED_SERVER_TEST_HOOKS=true
export FLYOLOGY_STRUCTURED_SERVER_TEST_HOOKS
compile_test_mains \
  "$structured_server_test_subdir" "$structured_server_hook_mains"
unset FLYOLOGY_STRUCTURED_SERVER_TEST_HOOKS

FLYOLOGY_WALL_CLOCK_TEST_HOOKS=true
export FLYOLOGY_WALL_CLOCK_TEST_HOOKS
compile_test_mains "$wall_clock_test_subdir" "$wall_clock_hook_mains"
unset FLYOLOGY_WALL_CLOCK_TEST_HOOKS

FLYOLOGY_DEFAULT=lightweight "$project_root/scripts/prepare-rts.sh" >/dev/null
link_test_mains \
  "$test_subdir" "$project_root/build/rts" default_policy_smoke
"$test_bin/default_policy_smoke" lightweight

FLYOLOGY_DEFAULT=native "$project_root/scripts/prepare-rts.sh" >/dev/null
native_mains="default_policy_smoke
$ordinary_unhooked_mains"
link_test_mains "$test_subdir" "$project_root/build/rts" "$native_mains"

FLYOLOGY_CONNECTION_TEST_HOOKS=true
export FLYOLOGY_CONNECTION_TEST_HOOKS
link_test_mains \
  "$connection_test_subdir" "$project_root/build/rts" "$connection_hook_mains"
unset FLYOLOGY_CONNECTION_TEST_HOOKS

FLYOLOGY_WORKER_POOL_TEST_HOOKS=true
export FLYOLOGY_WORKER_POOL_TEST_HOOKS
link_test_mains \
  "$worker_pool_test_subdir" "$project_root/build/rts" \
  "$worker_pool_hook_mains"
unset FLYOLOGY_WORKER_POOL_TEST_HOOKS

FLYOLOGY_WALL_CLOCK_TEST_HOOKS=true
export FLYOLOGY_WALL_CLOCK_TEST_HOOKS
link_test_mains \
  "$wall_clock_test_subdir" "$project_root/build/rts" \
  "$wall_clock_hook_mains"
unset FLYOLOGY_WALL_CLOCK_TEST_HOOKS

"$test_bin/default_policy_smoke" native
"$wall_clock_test_bin/flyology-wall_clock_testing-smoke"

for test_main in $ordinary_mains; do
  printf '%s\n' "test: BEGIN $test_main"
  case "$test_main" in
    connection_admission_smoke|connection_state_model|connection_tls_upgrade_smoke|descriptor_ownership_smoke)
      current_test_bin=$connection_test_bin
      ;;
    concurrency_primitives_smoke|task_scope_faults_smoke)
      current_test_bin=$worker_pool_test_bin
      ;;
    *)
      current_test_bin=$test_bin
      ;;
  esac
  case "$test_main" in
    channel_reentrancy_child)
      for model in lightweight native; do
        "$project_root/scripts/expect-blocked.sh" 1 \
          "$current_test_bin/$test_main" "$model"
      done
      ;;
    dns_smoke)
      "$project_root/scripts/run-with-timeout.sh" 20 \
        "$current_test_bin/$test_main"
      ;;
    dns_parser_matrix)
      "$project_root/scripts/run-with-timeout.sh" 20 \
        "$current_test_bin/$test_main"
      ;;
    dns_resilience_smoke)
      "$project_root/scripts/run-with-timeout.sh" 60 \
        "$current_test_bin/$test_main"
      ;;
    process_lifecycle_smoke|process_exit_live_task_smoke)
      "$project_root/scripts/run-with-timeout.sh" 10 \
        "$current_test_bin/$test_main"
      ;;
    connection_admission_smoke|connection_state_model|connection_tls_upgrade_smoke)
      "$project_root/scripts/run-with-timeout.sh" 30 \
        "$current_test_bin/$test_main"
      ;;
    tls_smoke)
      tls_library_dir=${FLYOLOGY_TEST_OPENSSL_DIR:-}
      if [ -z "$tls_library_dir" ] && command -v pkg-config >/dev/null 2>&1; then
        tls_library_dir=$(pkg-config --variable=libdir openssl 2>/dev/null || :)
      fi
      if [ -n "$tls_library_dir" ]; then
        tls_mismatch_dir="$project_root/build/tests/tls-mismatch"
        mkdir -p "$tls_mismatch_dir"
        case "$(uname -s)" in
          Darwin)
            cc -std=c11 -Wall -Wextra -Werror -dynamiclib \
              "$project_root/tests/fixtures/tls/mismatched_crypto.c" \
              -o "$tls_mismatch_dir/libcrypto.3.dylib"
            ln -sf "$tls_library_dir/libssl.3.dylib" \
              "$tls_mismatch_dir/libssl.3.dylib"
            ;;
          Linux)
            cc -std=c11 -Wall -Wextra -Werror -shared -fPIC \
              -Wl,-soname,libcrypto.so.3 \
              "$project_root/tests/fixtures/tls/mismatched_crypto.c" \
              -o "$tls_mismatch_dir/libcrypto.so.3"
            ln -sf "$tls_library_dir/libssl.so.3" \
              "$tls_mismatch_dir/libssl.so.3"
            ;;
        esac
        FLYOLOGY_TEST_OPENSSL_DIR="$tls_library_dir" \
        FLYOLOGY_TEST_OPENSSL_MISMATCH_DIR="$tls_mismatch_dir" \
          "$project_root/scripts/run-with-timeout.sh" 90 \
          "$current_test_bin/$test_main"
      else
        "$project_root/scripts/run-with-timeout.sh" 90 \
          "$current_test_bin/$test_main"
      fi
      ;;
    tls_state_model)
      "$project_root/scripts/run-with-timeout.sh" 30 \
        "$current_test_bin/$test_main"
      ;;
    *)
      "$project_root/scripts/run-with-timeout.sh" 60 \
        "$current_test_bin/$test_main"
      ;;
  esac
  printf '%s\n' "test: PASS $test_main"
done

#  Exercise automatic placement separately because the pool policy is compiled
#  into the prepared RTS. The ordinary suite above intentionally retains the
#  compatibility default of one lazily created loop.
FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE=3 \
FLYOLOGY_PLACEMENT=round_robin \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
link_test_mains "$test_subdir" "$project_root/build/rts" "$pool_mains"
"$test_bin/loop_pool_smoke"
"$test_bin/topology_smoke"
"$project_root/scripts/run-with-timeout.sh" 30 \
  "$test_bin/semantic_conformance_matrix"
"$project_root/scripts/run-with-timeout.sh" 30 \
  "$test_bin/semantic_termination_matrix"

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
  link_test_mains \
    "$test_subdir" "$project_root/build/rts" \
    loop_thread_project_placement_smoke
  "$test_bin/loop_thread_project_placement_smoke"
fi

#  Transient accept behavior depends on errno results that are difficult to
#  produce deterministically from a client. Exercise the production retry,
#  deadline, cancellation, and structural-error paths through the test-only C
#  seam, with an outer timeout so a retry regression cannot hang CI.
FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE=1 \
FLYOLOGY_TEST_FAULTS=1 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
if [ "$(uname -s)" = Linux ]; then
  fault_mains="$fault_mains
linux_poller_fairness_smoke
fault_injection_smoke"
fi
link_test_mains "$test_subdir" "$project_root/build/rts" "$fault_mains"
FLYOLOGY_STRUCTURED_SERVER_TEST_HOOKS=true
export FLYOLOGY_STRUCTURED_SERVER_TEST_HOOKS
link_test_mains \
  "$structured_server_test_subdir" "$project_root/build/rts" \
  "$structured_server_hook_mains"
unset FLYOLOGY_STRUCTURED_SERVER_TEST_HOOKS
"$project_root/scripts/run-with-timeout.sh" 30 \
  "$test_bin/accept_transient_smoke"
"$project_root/scripts/run-with-timeout.sh" 30 \
  "$test_bin/connect_transient_smoke"
"$project_root/scripts/run-with-timeout.sh" 30 \
  "$test_bin/structured_server_reuse_smoke"
"$project_root/scripts/run-with-timeout.sh" 30 \
  "$test_bin/task_result_publication_smoke"
"$project_root/scripts/run-with-timeout.sh" 30 \
  "$project_root/tests/bin/$structured_server_test_subdir/structured_server_abort_smoke"

#  A capable Linux host must prove both initialization-fallback boundaries in
#  fresh processes.  Forced-native runs cannot reach these post-setup seams.
if [ "$(uname -s)" = Linux ] && \
   [ "${FLYOLOGY_EXPECT_FILE_BACKEND:-}" = io-uring ]
then
  "$project_root/scripts/run-with-timeout.sh" 30 \
    "$test_bin/fault_injection_smoke" \
    file-uring-probe-fallback
  "$project_root/scripts/run-with-timeout.sh" 30 \
    "$test_bin/fault_injection_smoke" \
    file-uring-post-setup-fallback
  "$project_root/scripts/run-with-timeout.sh" 30 \
    "$test_bin/fault_injection_smoke" \
    file-uring-last-fiber
fi

#  The two Linux file backends answer cancellation through different kernel
#  contracts, so the backend cancellation case runs against whichever one this
#  configuration selected rather than against io_uring alone.
if [ "$(uname -s)" = Linux ]; then
  "$project_root/scripts/run-with-timeout.sh" 30 \
    "$test_bin/fault_injection_smoke" \
    file-backend-cancel
fi

#  Exercise the Linux batch boundary with a queued file completion, socket
#  readiness, and a cross-thread eventfd wake in every iteration. The same
#  deterministic test runs against io_uring and the forced native-AIO lane.
if [ "$(uname -s)" = Linux ]; then
  "$project_root/scripts/run-with-timeout.sh" 60 \
    "$test_bin/linux_poller_fairness_smoke"
fi

unset FLYOLOGY_CONNECTION_TEST_HOOKS || :
unset FLYOLOGY_WORKER_POOL_TEST_HOOKS || :
unset FLYOLOGY_STRUCTURED_SERVER_TEST_HOOKS || :

#  Leave the worktree with the documented compatibility configuration.
FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE=1 \
FLYOLOGY_TEST_FAULTS=0 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null

#  Prove that a separate Alire workspace can locate the crate, prepare its own
#  runtime outside the dependency checkout, and build against only public GPR
#  and Ada interfaces.
ALR="$alr" "$project_root/scripts/test-external-consumer.sh"
