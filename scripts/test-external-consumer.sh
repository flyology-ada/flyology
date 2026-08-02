#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_root="$project_root/tests/external_consumer"
alr=$("$project_root/scripts/find-alr.sh")
consumer_root=$(mktemp -d "${TMPDIR:-/tmp}/gnatevl-consumer.XXXXXX")

cleanup () {
  rm -rf -- "$consumer_root"
}
trap cleanup EXIT HUP INT TERM

cp -R "$fixture_root/." "$consumer_root/"
cd "$consumer_root"

"$alr" --non-interactive with gnatevl --use="$project_root"

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

for execution_default in native evented; do
  rts_root="$consumer_root/build/rts-$execution_default"
  ALR="$alr" \
  GNATEVL_CONSUMER_RTS="$rts_root" \
  GNATEVL_CONSUMER_DEFAULT="$execution_default" \
    "$alr" exec -- ./prepare-rts.sh

  run_gprbuild \
    --RTS="$rts_root" \
    -f \
    -P external_consumer.gpr
  "$consumer_root/build/bin/external_consumer" "$execution_default"
done
