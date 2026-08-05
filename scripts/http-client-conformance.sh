#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
test_subdir=http-client-conformance
test_binary="$project_root/tests/bin/$test_subdir/http_client_smoke"

cd "$project_root"
"$alr" build

run_gprbuild () {
  if [ "$(uname -s)" = Darwin ]; then
    compiler_sysroot=$("$alr" exec -- gcc -print-sysroot)
    if [ -z "$compiler_sysroot" ] || [ ! -d "$compiler_sysroot" ]; then
      current_sysroot=$(xcrun --sdk macosx --show-sdk-path)
      "$alr" exec -- env -u GPR_CONFIG gprbuild "$@" \
        -largs "-Wl,-syslibroot,$current_sysroot" -nodefaultrpaths
      return
    fi
    "$alr" exec -- env -u GPR_CONFIG gprbuild "$@" \
      -largs -nodefaultrpaths
    return
  fi
  "$alr" exec -- env -u GPR_CONFIG gprbuild "$@"
}

run_gprbuild \
  --RTS="$project_root/build/alire-rts" \
  --subdirs="$test_subdir" \
  -f -p -P tests/runtime_smoke.gpr http_client_smoke.adb

"$test_binary"
printf '%s\n' "http client conformance baseline: PASS"
