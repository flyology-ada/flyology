#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
lock_file=/Users/yrashk/Projects/flyology-ada/flyology/.git/flyology-triage-tla-performance.lock

if [ "${1:-}" = --measure-only ]; then
  shift
  rounds=${1:-200000}
  warmup_rounds=${2:-200000}
  pairs=${3:-6}

  printf '%s\n' "measured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  uname -a
  sw_vers
  pmset -g batt
  pmset -g custom
  printf '%s\n' \
    "head=$(git -C "$project_root" rev-parse HEAD)" \
    "gnat_release=$("$project_root/scripts/gnat-native-release.sh" "$alr")" \
    "rounds=$rounds" \
    "warmup_rounds=$warmup_rounds" \
    "pairs=$pairs"

  pair=1
  while [ "$pair" -le "$pairs" ]; do
    if [ $((pair % 2)) -eq 1 ]; then
      order=control-treatment
    else
      order=treatment-control
    fi
    printf '%s\n' "pair=$pair order=$order"
    case "$order" in
      control-treatment)
        "$project_root/benchmarks/bin/native_rendezvous_lane_control" "$rounds" "$warmup_rounds"
        "$project_root/benchmarks/bin/native_rendezvous_lane_treatment" "$rounds" "$warmup_rounds"
        ;;
      treatment-control)
        "$project_root/benchmarks/bin/native_rendezvous_lane_treatment" "$rounds" "$warmup_rounds"
        "$project_root/benchmarks/bin/native_rendezvous_lane_control" "$rounds" "$warmup_rounds"
        ;;
    esac
    pair=$((pair + 1))
  done
  exit 0
fi

rounds=${1:-200000}
warmup_rounds=${2:-200000}
pairs=${3:-6}
for value in "$rounds" "$warmup_rounds" "$pairs"; do
  case "$value" in
    ''|*[!0-9]*|0)
      printf '%s\n' "rounds, warmup rounds, and pairs must be positive integers" >&2
      exit 2
      ;;
  esac
done

cd "$project_root"
"$alr" build --stop-after=generation >/dev/null
FLYOLOGY_DEFAULT=native "$project_root/scripts/prepare-rts.sh" >/dev/null

if [ "$(uname -s)" = Darwin ]; then
  compiler_sysroot=$("$alr" exec -- gcc -print-sysroot)
  if [ -z "$compiler_sysroot" ] || [ ! -d "$compiler_sysroot" ]; then
    current_sysroot=$(xcrun --sdk macosx --show-sdk-path)
    "$alr" exec -- env -u GPR_CONFIG gprbuild \
      --RTS="$project_root/build/rts" \
      -p -f -P benchmarks/flyology_runtime_bench.gpr \
      native_rendezvous_lane_control.adb \
      native_rendezvous_lane_treatment.adb \
      -largs "-Wl,-syslibroot,$current_sysroot" -nodefaultrpaths
  else
    "$alr" exec -- env -u GPR_CONFIG gprbuild \
      --RTS="$project_root/build/rts" \
      -p -f -P benchmarks/flyology_runtime_bench.gpr \
      native_rendezvous_lane_control.adb \
      native_rendezvous_lane_treatment.adb \
      -largs -nodefaultrpaths
  fi
else
  "$alr" exec -- env -u GPR_CONFIG gprbuild \
    --RTS="$project_root/build/rts" \
    -p -f -P benchmarks/flyology_runtime_bench.gpr \
    native_rendezvous_lane_control.adb \
    native_rendezvous_lane_treatment.adb
fi

exec /usr/bin/lockf "$lock_file" "$0" --measure-only "$rounds" "$warmup_rounds" "$pairs"
