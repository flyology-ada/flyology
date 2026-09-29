#!/bin/sh
#  Build and run the runtime benchmarks that guard the per-fiber
#  nested-subprogram trampoline cursor.
#
#  Usage:
#    scripts/bench-runtime.sh                run and print results
#    scripts/bench-runtime.sh save DIR       persist timing baselines
#    scripts/bench-runtime.sh check DIR      compare against saved baselines
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
cd "$project_root"

mode=${1:-report}
baseline_dir=${2:-}
case "$mode" in
  report) ;;
  save|check)
    if [ -z "$baseline_dir" ]; then
      printf '%s\n' "usage: bench-runtime.sh $mode <baseline-directory>" >&2
      exit 2
    fi
    mkdir -p "$baseline_dir"
    baseline_dir=$(CDPATH= cd -- "$baseline_dir" && pwd)
    ;;
  *)
    printf '%s\n' "usage: bench-runtime.sh [report|save DIR|check DIR]" >&2
    exit 2
    ;;
esac

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

FLYOLOGY_DEFAULT=native "$project_root/scripts/prepare-rts.sh" >/dev/null

run_gprbuild \
  --RTS="$project_root/build/rts" \
  -p -j0 \
  -P benchmarks/flyology_runtime_bench.gpr

bench_bin="$project_root/benchmarks/bin"

printf '%s\n' "bench: timing"
case "$mode" in
  report) "$bench_bin/runtime_callback_bench" ;;
  save)   "$bench_bin/runtime_callback_bench" save "$baseline_dir" ;;
  check)  "$bench_bin/runtime_callback_bench" check "$baseline_dir" ;;
esac

#  The idle-path rate is what the loop's utilization accounting is charged for,
#  so report it next to the cost of one clock reading above.
printf '%s\n' "bench: idle path"
"$bench_bin/idle_wait_rate" "${FLYOLOGY_BENCH_IDLE_WINDOW:-2.0}"

#  Memory is reported as the difference between fibers that hold a callback and
#  fibers that do not, which isolates the trampoline page from the fiber stack.
printf '%s\n' "bench: memory"
"$bench_bin/fiber_trampoline_memory" "${FLYOLOGY_BENCH_FIBERS:-512}" without
"$bench_bin/fiber_trampoline_memory" "${FLYOLOGY_BENCH_FIBERS:-512}" with
