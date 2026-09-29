#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)
runs=${1:-5}
csv=${2:-"${TMPDIR:-/tmp}/flyology-task-snapshot-contention.csv"}
small=${FLYOLOGY_SNAPSHOT_SMALL:-1000}
large=${FLYOLOGY_SNAPSHOT_LARGE:-10000}
window=${FLYOLOGY_SNAPSHOT_WINDOW:-0.200}
periodic_window=${FLYOLOGY_SNAPSHOT_PERIODIC_WINDOW:-1.000}
alr=$("$project_root/scripts/find-alr.sh")

case "$runs" in
  ''|*[!0-9]*|0)
    printf '%s\n' "snapshot benchmark runs must be a positive integer: $runs" >&2
    exit 2
    ;;
esac

for value in "$small" "$large"; do
  case "$value" in
    ''|*[!0-9]*|0|1)
      printf '%s\n' "snapshot benchmark counts must be integers greater than one: $value" >&2
      exit 2
      ;;
  esac
done

toolchain=$("$alr" exec -- gnatls --version | sed -n '1p')
platform=$(uname -s)
architecture=$(uname -m)

FLYOLOGY_DEFAULT=native FLYOLOGY_LOOP_POOL_SIZE=1 \
  FLYOLOGY_PLACEMENT=round_robin FLYOLOGY_LOOP_PLACEMENT=none \
  FLYOLOGY_SANITIZER=none FLYOLOGY_TEST_FAULTS=0 \
  "$showcase_root/prepare-rts.sh" >/dev/null
(
  cd "$showcase_root"
  "$alr" exec -- env -u GPR_CONFIG gprbuild \
    --RTS="$project_root/build/rts" -f \
    -P showcases.gpr task_snapshot_contention.adb >/dev/null
)

printf '%s\n' \
  'schema,run,operation,members,capacity,requested_interval_s,observation_wall_s,calls,call_throughput_s,call_p50_us,call_p95_us,call_p99_us,call_max_us,adjacent_baseline_dispatches_s,observation_dispatches_s,dispatch_rate_percent,configured_groups,requested_stack_bytes,toolchain,platform,architecture,runtime_default,placement,loop_placement,sanitizer,test_faults' >"$csv"

printf '%s\n' \
  "Flyology task-snapshot contention benchmark" \
  "toolchain=$toolchain platform=$platform architecture=$architecture" \
  "runs=$runs saturated_window=$window periodic_window=$periodic_window CSV=$csv"

run_case () {
  operation=$1
  members=$2
  capacity=$3
  interval=$4
  case_window=$5
  repeat=1
  while [ "$repeat" -le "$runs" ]; do
    row=$("$showcase_root/bin/task_snapshot_contention" \
      "$operation" "$members" "$capacity" "$case_window" "$repeat" \
      "$interval")
    printf '%s,%s,%s,"%s","%s","%s","native","round_robin","none","none","0"\n' \
      "$row" 1 16384 "$toolchain" "$platform" "$architecture" >>"$csv"
    repeat=$((repeat + 1))
  done
}

for members in "$small" "$large"; do
  run_case group "$members" 1 0.0 "$window"
  run_case tasks "$members" 1 0.0 "$window"
  run_case tasks "$members" 32 0.0 "$window"
  run_case tasks "$members" 256 0.0 "$window"
  run_case tasks "$members" "$members" 0.0 "$window"
  run_case tasks "$members" 32 0.010 "$periodic_window"
  run_case tasks "$members" "$members" 0.010 "$periodic_window"
done

printf '%s\n' "machine-readable results: $csv"
