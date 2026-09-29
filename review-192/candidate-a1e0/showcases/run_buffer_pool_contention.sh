#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
pool_size=${1:-32}
iterations=${2:-20000}

for value in "$pool_size" "$iterations"; do
  case "$value" in
    ''|*[!0-9]*|0)
      printf '%s\n' "POOL_SIZE and ITERATIONS must be positive integers" >&2
      exit 2
      ;;
  esac
done
if [ "$pool_size" -gt 128 ]; then
  printf '%s\n' "POOL_SIZE cannot exceed 128" >&2
  exit 2
fi

restore_default () {
  FLYOLOGY_DEFAULT=native FLYOLOGY_LOOP_POOL_SIZE=1 \
    "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1 || true
}

"$showcase_root/prepare-alire.sh" >/dev/null
trap restore_default EXIT HUP INT TERM

FLYOLOGY_DEFAULT=lightweight \
FLYOLOGY_LOOP_POOL_SIZE=$pool_size \
FLYOLOGY_PLACEMENT=round_robin \
  "$project_root/scripts/prepare-rts.sh" >/dev/null

(
  cd "$showcase_root"
  "$alr" exec -- env -u GPR_CONFIG gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P showcases.gpr \
    buffer_pool_contention.adb
)

printf '%s\n' \
  'policy,workload,topology,first_group,last_group,groups,block_bytes,iterations_per_pair,total_handoffs,seconds,handoffs_per_second'

groups=1
while :; do
  for workload in churn touch; do
    for policy in shared partitioned; do
      "$showcase_root/bin/buffer_pool_contention" \
        "$policy" "$groups" "$iterations" "$workload"
    done
  done

  if [ "$groups" -eq "$pool_size" ]; then
    break
  fi
  groups=$((groups * 2))
  if [ "$groups" -gt "$pool_size" ]; then
    groups=$pool_size
  fi
done
