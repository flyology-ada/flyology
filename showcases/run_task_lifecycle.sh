#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)
runs=${1:-5}
csv=${2:-"${TMPDIR:-/tmp}/flyology-task-lifecycle.csv"}
small=${FLYOLOGY_LIFECYCLE_SMALL:-1000}
large=${FLYOLOGY_LIFECYCLE_LARGE:-10000}
native=${FLYOLOGY_LIFECYCLE_NATIVE:-1000}
alr=$("$project_root/scripts/find-alr.sh")

for value in "$runs" "$small" "$large" "$native"; do
  case "$value" in
    ''|*[!0-9]*|0)
      printf '%s\n' "lifecycle benchmark counts must be positive integers: $value" >&2
      exit 2
      ;;
  esac
done

toolchain=$("$alr" exec -- gnatls --version | sed -n '1p')
platform=$(uname -s)
architecture=$(uname -m)

printf '%s\n' \
  'schema,run,model,placement,mode,count,configured_groups,observed_groups,requested_stack_bytes,creators,window,creation_wall_s,creation_throughput_s,start_p50_us,start_p95_us,start_p99_us,completion_wall_s,completion_throughput_s,completion_p50_us,completion_p95_us,completion_p99_us,finalization_wall_s,finalization_throughput_s,finalization_p50_us,finalization_p95_us,finalization_p99_us,reap_wall_s,total_wall_s,rss_before_bytes,rss_sample_peak_bytes,rss_process_peak_bytes,virtual_before_bytes,virtual_sample_peak_bytes,threads_before,threads_peak,stacks_before,stacks_peak,stacks_after,arenas_peak,stack_usable_bytes_peak,stack_reserved_bytes_peak,arena_maps,arena_unmaps,stack_reuses,stack_discards,exactly_once,toolchain,platform,architecture,runtime_default,placement_policy,loop_placement,sanitizer,test_faults' >"$csv"

prepare () {
  groups=$1
  FLYOLOGY_DEFAULT=native FLYOLOGY_LOOP_POOL_SIZE=$groups \
    FLYOLOGY_PLACEMENT=round_robin \
    FLYOLOGY_LOOP_PLACEMENT=none FLYOLOGY_SANITIZER=none \
    FLYOLOGY_TEST_FAULTS=0 \
    "$project_root/showcases/prepare-rts.sh" >/dev/null
  (
    cd "$showcase_root"
    "$alr" exec -- env -u GPR_CONFIG gprbuild \
      --RTS="$project_root/build/rts" \
      -f \
      -P showcases.gpr task_lifecycle.adb >/dev/null
  )
}

run_case () {
  groups=$1
  model=$2
  placement=$3
  mode=$4
  count=$5
  creators=$6
  repeat=1
  while [ "$repeat" -le "$runs" ]; do
    row=$("$showcase_root/bin/task_lifecycle" \
      "$model" "$placement" "$mode" "$count" "$groups" \
      "$creators" "$repeat")
    printf '%s,"%s","%s","%s","native","round_robin","none","none","0"\n' \
      "$row" "$toolchain" "$platform" "$architecture" >>"$csv"
    repeat=$((repeat + 1))
  done
}

printf '%s\n' \
  "Flyology task-lifecycle benchmark" \
  "toolchain=$toolchain platform=$platform architecture=$architecture" \
  "runs=$runs CSV=$csv"

prepare 1
for mode in cold warm; do
  run_case 1 lightweight automatic "$mode" "$small" 1
  run_case 1 lightweight automatic "$mode" "$large" 1
  run_case 1 lightweight automatic "$mode" "$large" 4
  run_case 1 native automatic "$mode" "$native" 1
done

prepare 4
for mode in cold warm; do
  run_case 4 lightweight automatic "$mode" "$small" 1
  run_case 4 lightweight automatic "$mode" "$large" 1
  run_case 4 lightweight automatic "$mode" "$large" 4
  run_case 4 lightweight explicit "$mode" "$small" 1
  run_case 4 lightweight explicit "$mode" "$large" 1
  run_case 4 lightweight explicit "$mode" "$large" 4
done

printf '%s\n' "machine-readable results: $csv"
