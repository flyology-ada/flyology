#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
pool_size=${1:-4}
operations=${2:-1000}

for value in "$pool_size" "$operations"; do
  case "$value" in
    ''|*[!0-9]*|0)
      printf '%s\n' "POOL_SIZE and OPERATIONS must be positive integers" >&2
      exit 2
      ;;
  esac
done
if [ "$pool_size" -gt 128 ]; then
  printf '%s\n' "POOL_SIZE cannot exceed 128" >&2
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
  FLYOLOGY_DEFAULT=native FLYOLOGY_LOOP_POOL_SIZE=1 \
    "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1 || true
}
trap restore_default EXIT HUP INT TERM

cd "$project_root"
FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE=$pool_size \
FLYOLOGY_PLACEMENT=round_robin \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
run_gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P showcases/showcases.gpr \
  thread_per_core.adb >/dev/null

printf '%s\n' \
  "Execution groups are scheduling and ownership shards, not physical-core IDs." \
  "The native client sends rendezvous messages; lightweight clients send messages and cross shards."
"$showcase_root/bin/thread_per_core" "$operations"
