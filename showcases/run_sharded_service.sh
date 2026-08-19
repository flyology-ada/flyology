#!/bin/sh
set -eu

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
shard_count=${1:-4}
calls=${2:-5000}

for value in "$shard_count" "$calls"; do
  case "$value" in
    ''|*[!0-9]*|0)
      printf '%s\n' "SHARDS and CALLS must be positive integers" >&2
      exit 2
      ;;
  esac
done
if [ "$shard_count" -gt 128 ]; then
  printf '%s\n' "SHARDS cannot exceed 128" >&2
  exit 2
fi

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

restore_default () {
  FLYOLOGY_DEFAULT=native FLYOLOGY_LOOP_POOL_SIZE=1 \
    "$project_root/scripts/prepare-rts.sh" >/dev/null 2>&1 || true
}

"$showcase_root/prepare-alire.sh" >/dev/null
trap restore_default EXIT HUP INT TERM

cd "$showcase_root"
FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE=$shard_count \
FLYOLOGY_PLACEMENT=round_robin \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
run_gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P showcases.gpr \
  sharded_service.adb >/dev/null

printf '%s\n' \
  "One service instance per shard. Borrow_Local reaches the caller's own" \
  "instance directly; Invoke_On reaches any other shard through a rendezvous." \
  "Absolute times move with machine load; compare the rows, not the numbers." \
  ""
"$showcase_root/bin/sharded_service" "$shard_count" "$calls"
