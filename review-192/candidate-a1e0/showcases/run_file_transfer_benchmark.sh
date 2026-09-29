#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
benchmark_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-file-transfer.XXXXXX")
benchmark_path="$benchmark_root/fixture.data"

cleanup () {
  rm -f -- "$benchmark_path"
  rmdir -- "$benchmark_root" 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

"$project_root/showcases/prepare-alire.sh" >/dev/null
FLYOLOGY_DEFAULT=native FLYOLOGY_LOOP_POOL_SIZE=1 \
   "$project_root/showcases/prepare-rts.sh" >/dev/null
(
  cd "$project_root"
  FLYOLOGY_SHOWCASE_PROFILE=release \
    "$alr" exec -- env -u GPR_CONFIG gprbuild \
      --RTS="$project_root/build/rts" \
      -q -f -p -P showcases/showcases.gpr file_transfer_benchmark.adb
)
FLYOLOGY_FILE_TRANSFER_BENCH_PATH="$benchmark_path" \
  "$project_root/showcases/bin/file_transfer_benchmark"
