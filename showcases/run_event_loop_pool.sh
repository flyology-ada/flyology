#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)
alr=${ALR:-"$HOME/alr"}
workers=${1:-1024}
rounds=${2:-20}
pool_size=${3:-4}

for value in "$workers" "$rounds" "$pool_size"; do
  case "$value" in
    ''|*[!0-9]*|0)
      printf '%s\n' "WORKERS, ROUNDS, and POOL_SIZE must be positive integers" >&2
      exit 2
      ;;
  esac
done
if [ "$pool_size" -gt 128 ]; then
  printf '%s\n' "POOL_SIZE cannot exceed 128" >&2
  exit 2
fi

required_descriptors=$((2 * workers + 64))
descriptor_limit=$(ulimit -n)
if [ "$descriptor_limit" != unlimited ] \
  && [ "$descriptor_limit" -lt "$required_descriptors" ]
then
  printf '%s\n' \
    "event-loop-pool showcase needs $required_descriptors descriptors; current limit is $descriptor_limit" \
    "Raise the descriptor limit or pass a smaller WORKERS value." >&2
  exit 2
fi

run_gprbuild () {
  if [ "$(uname -s)" = Darwin ]; then
    compiler_sysroot=$("$alr" exec -- gcc -print-sysroot)
    if [ -z "$compiler_sysroot" ] || [ ! -d "$compiler_sysroot" ]; then
      current_sysroot=$(xcrun --sdk macosx --show-sdk-path)
      "$alr" exec -- gprbuild "$@" \
        -largs "-Wl,-syslibroot,$current_sysroot" -nodefaultrpaths
      return
    fi
    "$alr" exec -- gprbuild "$@" -largs -nodefaultrpaths
    return
  fi
  "$alr" exec -- gprbuild "$@"
}

restore_default () {
  GNATEVL_DEFAULT=native GNATEVL_LOOP_POOL_SIZE=1 \
    "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1 || true
}
trap restore_default EXIT HUP INT TERM

cd "$project_root"
printf '%s\n' \
  "This compares one event-loop pthread with a round-robin pool under repeated socket-readiness waves." \
  "Groups are execution lanes, not physical-CPU pins; the OS decides where each loop pthread runs."

for loops in 1 "$pool_size"; do
  GNATEVL_DEFAULT=native \
  GNATEVL_LOOP_POOL_SIZE=$loops \
  GNATEVL_PLACEMENT=round_robin \
    "$project_root/scripts/prepare-rts.sh" >/dev/null
  run_gprbuild \
    --RTS="$project_root/build/rts" \
    -f \
    -P showcases/showcases.gpr \
    event_loop_pool.adb >/dev/null
  printf '\n== configured event loops: %s ==\n' "$loops"
  "$showcase_root/bin/event_loop_pool" "$workers" "$rounds"
done

printf '%s\n' \
  "Timing includes readiness delivery and task dispatch, not task creation." \
  "More loops permit parallel dispatch, but workload, kernel, and host scheduling determine whether that improves elapsed time."
