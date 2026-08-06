#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
coverage_root="$project_root/coverage"
prepared_rts="$coverage_root/rts"
pool_rts="$coverage_root/pool-rts"
fault_rts="$coverage_root/fault-rts"
instrumentation_rts="$coverage_root/gnatcov-rts"
trace_dir="$coverage_root/traces"
report_dir="$coverage_root/report"
coverage_subdir=flyology-coverage

cd "$project_root"

gnatcov=$("$alr" exec -- sh -c 'command -v gnatcov || true' | tail -n 1)
if [ -z "$gnatcov" ] || [ ! -x "$gnatcov" ]; then
  cat >&2 <<EOF
GNATcoverage is required but was not found in the Alire environment.
Install the gnatcov_bin tool crate into a tool prefix and add its bin directory
to PATH, for example:
  $alr install --prefix=/path/to/ada-tools gnatcov_bin
  PATH=/path/to/ada-tools/bin:\$PATH ./scripts/coverage.sh
EOF
  exit 1
fi

#  The path is fixed inside this checkout so cleanup cannot escape into a
#  caller-selected directory. Reports and traces are generated, never inputs.
rm -rf "$coverage_root"
mkdir -p "$trace_dir" "$report_dir"

#  A fresh Alire checkout has no generated config/flyology_config.* yet.
#  Generate only configuration sources; the instrumented build below remains
#  the sole library compilation measured by this workflow.
"$alr" build --stop-after=generation >/dev/null

configuration_count=0
execution_count=0

printf '%s\n' "coverage: preparing the native-default Flyology RTS"
FLYOLOGY_DEFAULT=native \
FLYOLOGY_RTS_DIR="$prepared_rts" \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
configuration_count=$((configuration_count + 1))

printf '%s\n' "coverage: preparing GNATcoverage support for the custom RTS"
"$alr" exec -- "$gnatcov" setup \
  --prefix="$instrumentation_rts" \
  --RTS="$prepared_rts" \
  --quiet

GPR_PROJECT_PATH="$instrumentation_rts/share/gpr${GPR_PROJECT_PATH:+:$GPR_PROJECT_PATH}"
LD_LIBRARY_PATH="$instrumentation_rts/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
DYLD_LIBRARY_PATH="$instrumentation_rts/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export GPR_PROJECT_PATH LD_LIBRARY_PATH DYLD_LIBRARY_PATH

#  The hooks make the same Ada library paths visible to the ordinary tests.
#  Fault injection remains disabled in the prepared runtime.
FLYOLOGY_DNS_TEST_HOOKS=true
FLYOLOGY_TLS_TEST_HOOKS=true
FLYOLOGY_CONNECTION_TEST_HOOKS=true
FLYOLOGY_WORKER_POOL_TEST_HOOKS=true
FLYOLOGY_WALL_CLOCK_TEST_HOOKS=true
export FLYOLOGY_DNS_TEST_HOOKS FLYOLOGY_TLS_TEST_HOOKS
export FLYOLOGY_CONNECTION_TEST_HOOKS
export FLYOLOGY_WORKER_POOL_TEST_HOOKS
export FLYOLOGY_WALL_CLOCK_TEST_HOOKS

printf '%s\n' "coverage: instrumenting Flyology-owned Ada library units"
"$alr" exec -- "$gnatcov" instrument \
  -P tests/runtime_smoke.gpr \
  --projects=flyology \
  --level=stmt+decision \
  --dump-trigger=main-end \
  --dump-channel=bin-file \
  --dump-filename-env-var=FLYOLOGY_COVERAGE_TRACE \
  --restricted-to-languages=Ada \
  --subdirs="$coverage_subdir" \
  --quiet \
  --warnings-as-errors

ordinary_mains='cancellation_wake_smoke
connection_lifecycle_smoke
connection_state_model
connection_tls_upgrade_smoke
concurrency_primitives_smoke
descriptor_ownership_smoke
dns_smoke
dns_parser_smoke
dns_parser_matrix
dormancy_smoke
execution_groups_smoke
fairness_smoke
file_cancellation_smoke
files_smoke
flyology-counter_policy_smoke
flyology-structured_server_policy-smoke
flyology-wall_clock_testing-smoke
flyology-wall_clock_policy-smoke
flyology-wall_clock_waits-smoke
io_smoke
io_starvation_smoke
lazy_event_start_smoke
lifecycle_smoke
loop_thread_placement_smoke
memory_regions_smoke
observability_native_smoke
observability_smoke
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
stack_size_parity_smoke
suspension_object_smoke
stall_watchdog_native_smoke
stall_watchdog_smoke
structured_server_smoke
structured_server_tls_smoke
thread_affinity_smoke
timer_heap_smoke
timer_set_smoke
tls_smoke
tls_state_model
tcp_native_smoke
wake_source_state_model
wait_any_smoke
wall_clock_wait_smoke'

set --
ordinary_count=0
for test_main in $ordinary_mains; do
  ordinary_count=$((ordinary_count + 1))
  set -- "$@" "$test_main.adb"
done

printf 'coverage: building %s instrumented portable test programs\n' \
  "$ordinary_count"
"$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$prepared_rts" \
  -f -p -q -j0 \
  -P tests/runtime_smoke.gpr \
  --subdirs="$coverage_subdir" \
  --src-subdirs=gnatcov-instr \
  --implicit-with=gnatcov_rts.gpr \
  "$@"

tls_library_dir=${FLYOLOGY_TEST_OPENSSL_DIR:-}
if [ -z "$tls_library_dir" ] && command -v pkg-config >/dev/null 2>&1; then
  tls_library_dir=$(pkg-config --variable=libdir openssl 2>/dev/null || :)
fi

for test_main in $ordinary_mains; do
  trace="$trace_dir/native-$test_main.srctrace"
  executable="$project_root/tests/bin/$coverage_subdir/$test_main"
  printf '%s\n' "coverage: RUN native/$test_main"
  case "$test_main" in
    dns_smoke)
      FLYOLOGY_COVERAGE_TRACE="$trace" \
        "$project_root/scripts/run-with-timeout.sh" 20 "$executable"
      ;;
    process_lifecycle_smoke|process_exit_live_task_smoke)
      FLYOLOGY_COVERAGE_TRACE="$trace" \
        "$project_root/scripts/run-with-timeout.sh" 10 "$executable"
      ;;
    tls_smoke)
      if [ -n "$tls_library_dir" ]; then
        FLYOLOGY_COVERAGE_TRACE="$trace" \
        FLYOLOGY_TEST_OPENSSL_DIR="$tls_library_dir" \
          "$project_root/scripts/run-with-timeout.sh" 90 "$executable"
      else
        FLYOLOGY_COVERAGE_TRACE="$trace" \
          "$project_root/scripts/run-with-timeout.sh" 90 "$executable"
      fi
      ;;
    *)
      FLYOLOGY_COVERAGE_TRACE="$trace" \
        "$project_root/scripts/run-with-timeout.sh" 90 "$executable"
      ;;
  esac
  if [ ! -s "$trace" ]; then
    printf '%s\n' \
      "coverage: native/$test_main produced no source trace" >&2
    exit 1
  fi
  execution_count=$((execution_count + 1))
done

#  These programs inspect and cross three automatic groups. Keep the ordinary
#  one-loop compatibility run intact, then relink only the pool-sensitive
#  programs against a three-loop RTS. The Flyology library instrumentation is
#  identical, so all traces consolidate into one report.
pool_mains='loop_pool_smoke
semantic_conformance_matrix
semantic_termination_matrix
topology_smoke'
printf '%s\n' "coverage: preparing the three-loop topology RTS"
FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE=3 \
FLYOLOGY_RTS_DIR="$pool_rts" \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
configuration_count=$((configuration_count + 1))
set --
for test_main in $pool_mains; do
  set -- "$@" "$test_main.adb"
done
printf '%s\n' "coverage: building three-loop topology programs"
"$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$pool_rts" \
  -f -p -q -j0 \
  -P tests/runtime_smoke.gpr \
  --subdirs="$coverage_subdir" \
  --src-subdirs=gnatcov-instr \
  --implicit-with=gnatcov_rts.gpr \
  "$@"
for test_main in $pool_mains; do
  trace="$trace_dir/pool-$test_main.srctrace"
  printf '%s\n' "coverage: RUN pool/$test_main"
  FLYOLOGY_COVERAGE_TRACE="$trace" \
    "$project_root/scripts/run-with-timeout.sh" 30 \
    "$project_root/tests/bin/$coverage_subdir/$test_main"
  if [ ! -s "$trace" ]; then
    printf '%s\n' \
      "coverage: pool/$test_main produced no source trace" >&2
    exit 1
  fi
  execution_count=$((execution_count + 1))
done

#  The runtime fault seam deterministically produces accept retry and listener
#  cleanup outcomes that portable clients cannot request from the host kernel.
#  Only the two public socket/server policy tests use this configuration.
fault_mains='accept_transient_smoke
structured_server_reuse_smoke'
printf '%s\n' "coverage: preparing the portable fault-policy RTS"
FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE=1 \
FLYOLOGY_TEST_FAULTS=1 \
FLYOLOGY_RTS_DIR="$fault_rts" \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
configuration_count=$((configuration_count + 1))
set --
for test_main in $fault_mains; do
  set -- "$@" "$test_main.adb"
done
printf '%s\n' "coverage: building portable fault-policy programs"
"$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$fault_rts" \
  -f -p -q -j0 \
  -P tests/runtime_smoke.gpr \
  --subdirs="$coverage_subdir" \
  --src-subdirs=gnatcov-instr \
  --implicit-with=gnatcov_rts.gpr \
  "$@"
for test_main in $fault_mains; do
  trace="$trace_dir/fault-$test_main.srctrace"
  printf '%s\n' "coverage: RUN fault/$test_main"
  FLYOLOGY_COVERAGE_TRACE="$trace" \
    "$project_root/scripts/run-with-timeout.sh" 30 \
    "$project_root/tests/bin/$coverage_subdir/$test_main"
  if [ ! -s "$trace" ]; then
    printf '%s\n' \
      "coverage: fault/$test_main produced no source trace" >&2
    exit 1
  fi
  execution_count=$((execution_count + 1))
done

all_programs="$ordinary_mains
$pool_mains
$fault_mains"
program_count=$(printf '%s\n' "$all_programs" | awk '
  NF && !seen[$1]++ { count++ }
  END { print count + 0 }
')

printf 'coverage: consolidating %s executions from %s configurations\n' \
  "$execution_count" "$configuration_count"
"$alr" exec -- "$gnatcov" coverage \
  -P tests/runtime_smoke.gpr \
  --projects=flyology \
  --level=stmt+decision \
  --subdirs="$coverage_subdir" \
  --restricted-to-languages=Ada \
  --excluded-source-files='flyology_config.*' \
  --annotate=report,xcov+ \
  --output-dir="$report_dir" \
  --output="$report_dir/details.txt" \
  --dump-units-to="$report_dir/units.txt" \
  --quiet \
  --warnings-as-errors \
  "$trace_dir"/*.srctrace

stats_summary () {
  label=$1
  stats_file=$2
  stats_line=$(awk '/^Global:$/ { getline; print; exit }' "$stats_file")
  if [ -z "$stats_line" ]; then
    printf '%s\n' "coverage: no global $label statistics were produced" >&2
    exit 1
  fi
  uncovered=$(printf '%s\n' "$stats_line" | sed -E 's/.*- *([0-9]+)%.*/\1/')
  partial=$(printf '%s\n' "$stats_line" | sed -E 's/.*! *([0-9]+)%.*/\1/')
  covered=$(printf '%s\n' "$stats_line" | sed -E 's/.*\+ *([0-9]+)%.*/\1/')
  obligations=$(printf '%s\n' "$stats_line" | sed -E 's/.*out of ([0-9]+) obligations.*/\1/')
  printf '%s: covered %s%%, partial %s%%, uncovered %s%% (%s obligations)\n' \
    "$label" "$covered" "$partial" "$uncovered" "$obligations"
}

tool_version=$("$gnatcov" --version | sed -n '1p')
{
  printf '%s\n' "Flyology source coverage"
  printf 'tool: %s\n' "$tool_version"
  printf '%s\n' "level: statement + decision"
  printf '%s\n' "scope: Ada units owned by the Flyology library project"
  printf 'programs: %s distinct portable behavioral programs\n' \
    "$program_count"
  printf 'executions: %s instrumented runs\n' "$execution_count"
  printf 'configurations: %s prepared runtime configurations\n' \
    "$configuration_count"
  stats_summary statements "$report_dir/stats/stmt.index"
  stats_summary decisions "$report_dir/stats/decision.index"
  printf '%s\n' "excluded: generated configuration, prepared RTS, C bridge, assembly, tests"
  printf '%s\n' "details: report/details.txt and report/*.xcov"
} >"$coverage_root/summary.txt"

cat "$coverage_root/summary.txt"
printf 'coverage: reports written under %s\n' "$coverage_root"
