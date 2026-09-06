#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary=${1:-}

if [ -z "$binary" ] || [ ! -x "$binary" ]; then
  printf '%s\n' "native CPU activation test executable is missing: $binary" >&2
  exit 1
fi
if [ "$(uname -s)" != Linux ]; then
  printf '%s\n' "native CPU activation test requires Linux" >&2
  exit 1
fi
if ! command -v taskset >/dev/null 2>&1; then
  printf '%s\n' "native CPU activation test requires taskset" >&2
  exit 1
fi

online_cpus=$(getconf _NPROCESSORS_ONLN)
allowed_list=$(awk '/^Cpus_allowed_list:/ { print $2; exit }' /proc/self/status)
positive_allowed_cpu=$(printf '%s\n' "$allowed_list" | awk -F, '
  {
    for (field_index = 1; field_index <= NF; field_index++) {
      split($field_index, limits, "-")
      first = limits[1] + 0
      last = limits[2] == "" ? first : limits[2] + 0
      for (cpu = first; cpu <= last; cpu++) {
        if (cpu > 0) {
          print cpu
          exit
        }
      }
    }
  }
')

if [ -n "$positive_allowed_cpu" ]; then
  runner_cpu=$positive_allowed_cpu
  excluded_ada_cpu=1
elif [ "$online_cpus" -gt 2 ]; then
  runner_cpu=0
  excluded_ada_cpu=2
else
  printf '%s\n' \
    "SKIP native CPU activation test: host cannot form the required excluded CPU set"
  exit 0
fi

if [ "$online_cpus" -le "$excluded_ada_cpu" ]; then
  printf '%s\n' \
    "native CPU activation precondition failed: online=$online_cpus selected=$excluded_ada_cpu" >&2
  exit 1
fi

printf 'native CPU activation: online=%s initial=%s runner=%s selected=%s\n' \
  "$online_cpus" "$allowed_list" "$runner_cpu" "$excluded_ada_cpu"
"$project_root/scripts/run-with-timeout.sh" 10 \
  taskset --cpu-list "$runner_cpu" \
  sh -c '
    allowed=$(awk "/^Cpus_allowed_list:/ { print \$2; exit }" /proc/self/status)
    if [ "$allowed" != "$1" ]; then
      printf "native CPU activation restriction failed: expected=%s actual=%s\n" \
        "$1" "$allowed" >&2
      exit 1
    fi
    exec "$2" "$3"
  ' sh "$runner_cpu" "$binary" "$excluded_ada_cpu"
