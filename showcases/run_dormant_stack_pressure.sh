#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_count=${1:-128}
pressure_mib=${2:-64}

for value in "$task_count" "$pressure_mib"
do
  case "$value" in
    ''|*[!0-9]*|0)
      printf '%s\n' "arguments must be positive integers: $value" >&2
      exit 2
      ;;
  esac
done

printf '%s\n' \
  "Each process parks $task_count timer-only lightweight tasks with 256 KiB of touched stack." \
  "It allocates and touches $pressure_mib MiB temporarily, then reports RSS and maximum timer wake lateness." \
  "MADV_COLD is a reclaim-priority hint: compare repeated runs under representative host or cgroup pressure."

printf '\n%s\n' "== prompt policy =="
"$showcase_root/bin/dormant_stack_pressure" \
  prompt "$task_count" "$pressure_mib"

printf '\n%s\n' "== reclaimable policy =="
"$showcase_root/bin/dormant_stack_pressure" \
  reclaimable "$task_count" "$pressure_mib"
