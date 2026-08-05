#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
test_subdir=http-client-conformance

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
  -f -p -P tests/runtime_smoke.gpr \
  http_client_smoke.adb http_client_parser_matrix.adb \
  http_client_pool_model.adb http_client_tls_smoke.adb

"$project_root/tests/bin/$test_subdir/http_client_smoke"
"$project_root/tests/bin/$test_subdir/http_client_parser_matrix"
"$project_root/tests/bin/$test_subdir/http_client_pool_model"
"$project_root/tests/bin/$test_subdir/http_client_tls_smoke"

lifetime_log="$project_root/build/tests/http-client-response-lifetime.log"
mkdir -p "$(dirname -- "$lifetime_log")"
if run_gprbuild \
  --RTS="$project_root/build/alire-rts" \
  --subdirs=http-client-compile-fail \
  -c -p -P tests/runtime_smoke.gpr \
  http_client_response_lifetime_fail.adb >"$lifetime_log" 2>&1
then
  printf '%s\n' "HTTP response escaped its client's lifetime" >&2
  exit 1
fi
if ! grep -E \
  '^http_client_response_lifetime_fail\.adb:[0-9]+:[0-9]+: error: .*accessibility.*return' \
  "$lifetime_log" >/dev/null
then
  cat "$lifetime_log" >&2
  printf '%s\n' "HTTP response lifetime fixture failed unexpectedly" >&2
  exit 1
fi

printf '%s\n' "http client deterministic conformance: PASS"
