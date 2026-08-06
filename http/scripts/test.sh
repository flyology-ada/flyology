#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$http_root/scripts/find-alr.sh")
test_rts="$http_root/build/rts"

if [ -n "${FLYOLOGY_ROOT:-}" ]; then
  flyology_root=$FLYOLOGY_ROOT
elif [ -f "$http_root/../scripts/prepare-rts.sh" ]; then
  flyology_root=$(CDPATH= cd -- "$http_root/.." && pwd)
else
  printf '%s\n' "FLYOLOGY_ROOT is required to test flyology_http" >&2
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
    "$alr" exec -- env -u GPR_CONFIG gprbuild "$@" \
      -largs -nodefaultrpaths
    return
  fi
  "$alr" exec -- env -u GPR_CONFIG gprbuild "$@"
}

compile_and_link () {
  subdir=$1
  mains=$2
  set --
  count=0
  for main in $mains; do
    set -- "$@" "$main.adb"
    count=$((count + 1))
  done
  printf '%s\n' "flyology_http test: BUILD $count programs ($subdir)"
  run_gprbuild \
    --RTS="$test_rts" \
    --subdirs="$subdir" \
    -f -p -j0 \
    -P tests/http_tests.gpr \
    "$@"
}

cd "$http_root"
FLYOLOGY_TLS_TEST_HOOKS=true
export FLYOLOGY_TLS_TEST_HOOKS
"$alr" build
FLYOLOGY_RTS_DIR="$test_rts" \
FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE=1 \
  "$flyology_root/scripts/prepare-rts.sh" >/dev/null

ordinary_mains='flyology-rate_limit_policy_smoke
flyology-http_chunk_encoding-smoke
flyology-websocket_policy-smoke
flyology-http-decoded_path_policy-smoke
flyology-http-expect_policy-smoke
flyology-http-client_policy-smoke
flyology-http-route_parameter_policy-smoke
flyology-websocket_deflate_policy_smoke
buffers_smoke
tls_smoke
http_smoke
http_client_smoke
http_client_addressing
http_client_authentication
http_client_boundaries_smoke
http_client_body_adapters_smoke
http_client_upload_controls_smoke
http_client_streaming_smoke
http_client_rfc_corpus
http_client_parser_matrix
http_client_parser_randomized
http_client_pool_model
http_client_redirects
http_client_tls_closure
http_client_tls_smoke'

connection_hook_mains='http_client_pool_races
http_client_deadline_matrix
http_client_fragmentation'

unset FLYOLOGY_CONNECTION_TEST_HOOKS || :
compile_and_link behavioral "$ordinary_mains"

FLYOLOGY_CONNECTION_TEST_HOOKS=true
export FLYOLOGY_CONNECTION_TEST_HOOKS
compile_and_link behavioral-connection-hooks "$connection_hook_mains"
unset FLYOLOGY_CONNECTION_TEST_HOOKS
unset FLYOLOGY_TLS_TEST_HOOKS

for main in $ordinary_mains; do
  printf '%s\n' "flyology_http test: BEGIN $main"
  case "$main" in
    tls_smoke|http_client_tls_smoke|http_client_tls_closure)
      timeout=120
      ;;
    http_smoke)
      timeout=90
      ;;
    *)
      timeout=60
      ;;
  esac
  "$http_root/scripts/run-with-timeout.sh" \
    "$timeout" "$http_root/tests/bin/behavioral/$main"
  printf '%s\n' "flyology_http test: PASS $main"
done

for main in $connection_hook_mains; do
  "$http_root/scripts/run-with-timeout.sh" 30 \
    "$http_root/tests/bin/behavioral-connection-hooks/$main"
  printf '%s\n' "flyology_http test: PASS $main"
done

response_lifetime_log="$http_root/build/tests/http-client-response-lifetime.log"
body_lifetime_log="$http_root/build/tests/http-client-body-source-lifetime.log"
websocket_lifetime_log="$http_root/build/tests/websocket-pool-lifetime.log"
mkdir -p "$http_root/build/tests"

if run_gprbuild --RTS="$test_rts" --subdirs=compile-fail -c -p \
  -P tests/http_tests.gpr http_client_response_lifetime_fail.adb \
  >"$response_lifetime_log" 2>&1
then
  printf '%s\n' "HTTP response escaped its client's lifetime" >&2
  exit 1
fi
grep -E \
  '^http_client_response_lifetime_fail\.adb:[0-9]+:[0-9]+: error: .*accessibility.*return' \
  "$response_lifetime_log" >/dev/null

if run_gprbuild --RTS="$test_rts" --subdirs=compile-fail -c -p \
  -P tests/http_tests.gpr http_client_body_source_lifetime_fail.adb \
  >"$body_lifetime_log" 2>&1
then
  printf '%s\n' "HTTP body source escaped its borrowed payload" >&2
  exit 1
fi
grep -E \
  '^http_client_body_source_lifetime_fail\.adb:[0-9]+:[0-9]+: error: .*access discriminant.*statically too deep' \
  "$body_lifetime_log" >/dev/null

if run_gprbuild --RTS="$test_rts" --subdirs=compile-fail -c -p \
  -P tests/http_tests.gpr websocket_pool_lifetime_fail.adb \
  >"$websocket_lifetime_log" 2>&1
then
  printf '%s\n' "WebSocket session accepted a shorter-lived buffer pool" >&2
  exit 1
fi
grep -E \
  '^websocket_pool_lifetime_fail\.adb:[0-9]+:[0-9]+: error: .*(deeper level than allocator type|accessibility)$' \
  "$websocket_lifetime_log" >/dev/null

printf '%s\n' "Flyology HTTP behavioral suite passed"
