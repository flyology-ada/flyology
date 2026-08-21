#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
library_log=$(mktemp "${TMPDIR:-/tmp}/flyology-library-proof.XXXXXX")
runtime_log=$(mktemp "${TMPDIR:-/tmp}/flyology-runtime-proof.XXXXXX")
debug_log=$(mktemp "${TMPDIR:-/tmp}/flyology-debug-proof.XXXXXX")
benchmark_log=$(mktemp "${TMPDIR:-/tmp}/flyology-benchmark-proof.XXXXXX")

cleanup_logs()
{
  rm -f "$library_log" "$runtime_log" "$debug_log" "$benchmark_log"
}

trap cleanup_logs EXIT
trap 'exit 1' HUP INT TERM

run_gnatprove()
{
  log=$1
  shift
  if ! "$alr" gnatprove "$@" >"$log" 2>&1; then
    cat "$log"
    return 1
  fi
  cat "$log"
  if grep -Eq ':[[:space:]]+(low|medium|high|warning):' "$log"; then
    printf '%s\n' \
      "GNATprove reported an unproved check or warning" >&2
    return 1
  fi
}

cd "$project_root"
"$alr" build --stop-after=generation

cd "$project_root/proof"
run_gnatprove "$library_log" \
  -P "$project_root/flyology.gpr" \
  --mode=all \
  --level=1 \
  -j0 \
  --output=oneline \
  --output-header \
  --report=all \
  -f \
  -u \
  flyology-shared_memory_policy.adb \
  flyology-data_structures-clock_policy.adb \
  flyology-data_structures-policy.adb \
  flyology-capacity_policy.adb \
  flyology-channel_policy.adb \
  flyology-counter_policy.adb \
  flyology-connection_policy.adb \
  flyology-dns_policy.adb \
  flyology-placement_policy.adb \
  flyology-topology_policy.adb \
  flyology-time_math.adb \
  flyology-wall_clock_native_policy.adb \
  flyology-wall_clock_policy.adb \
  flyology-tls_policy.adb \
  flyology-tls_openssl_policy.adb \
  flyology-structured_server_policy.adb \
  flyology-task_scope_policy.adb \
  flyology-supervision_policy.adb \
  flyology-worker_pool_policy.adb \
  flyology-native_executor_policy.adb \
  flyology-file_open_policy.adb \
  flyology-file_transfer_policy.adb \
  flyology-file_timeout_policy.adb \
  flyology-timer_set_policy.adb \
  flyology-socket_policy.adb \
  flyology-wait_policy.adb

run_gnatprove "$runtime_log" \
  -P "$project_root/proof/runtime_policy.gpr" \
  --mode=all \
  --level=1 \
  -j0 \
  --output=oneline \
  --output-header \
  --report=all \
  -f \
  -u s-flscpo.adb s-flpopo.adb s-ftrepo.adb s-flstpo.adb s-fszcpo.adb

run_gnatprove "$debug_log" \
  -P "$project_root/flyology_debug/flyology_debug.gpr" \
  --mode=all \
  --level=1 \
  -j0 \
  --output=oneline \
  --output-header \
  --report=all \
  -f \
  -u flyology_debug-internal-ring_policy.adb

run_gnatprove "$benchmark_log" \
  -P "$project_root/flyology_bench/flyology_bench.gpr" \
  --mode=all \
  --level=1 \
  -j0 \
  --output=oneline \
  --output-header \
  --report=all \
  -f \
  -u flyology_bench-baseline_math.adb

printf '%s\n' "Flyology SPARK proof suite passed"
