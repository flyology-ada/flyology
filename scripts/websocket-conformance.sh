#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
profile=${1:-core}
lane=${2:-lightweight}
port=${FLYOLOGY_WEBSOCKET_PORT:-18081}
image=${FLYOLOGY_AUTOBAHN_IMAGE:-crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074}
transport=plain

case "$profile:$lane" in
  core:lightweight)
    spec=fuzzingclient.json
    report_name=core-lightweight
    ;;
  core:native)
    spec=fuzzingclient-native.json
    report_name=core-native
    ;;
  core-wss:lightweight)
    spec=fuzzingclient-wss.json
    report_name=core-lightweight-wss
    transport=tls
    ;;
  core-wss:native)
    spec=fuzzingclient-wss-native.json
    report_name=core-native-wss
    transport=tls
    ;;
  limits:lightweight)
    spec=fuzzingclient-limits.json
    report_name=limits-lightweight
    ;;
  limits:native)
    spec=fuzzingclient-limits-native.json
    report_name=limits-native
    ;;
  compression:lightweight)
    spec=fuzzingclient-compression.json
    report_name=compression-lightweight
    ;;
  compression:native)
    spec=fuzzingclient-compression-native.json
    report_name=compression-native
    ;;
  compression-wss:lightweight)
    spec=fuzzingclient-compression-wss.json
    report_name=compression-lightweight-wss
    transport=tls
    ;;
  compression-wss:native)
    spec=fuzzingclient-compression-wss-native.json
    report_name=compression-native-wss
    transport=tls
    ;;
  performance:lightweight)
    spec=fuzzingclient-performance.json
    report_name=performance-lightweight
    ;;
  performance:native)
    spec=fuzzingclient-performance-native.json
    report_name=performance-native
    ;;
  performance-wss:lightweight)
    spec=fuzzingclient-performance-wss.json
    report_name=performance-lightweight-wss
    transport=tls
    ;;
  performance-wss:native)
    spec=fuzzingclient-performance-wss-native.json
    report_name=performance-native-wss
    transport=tls
    ;;
  *)
    printf '%s\n' \
      "usage: $0 {core lightweight|core native|core-wss lightweight|core-wss native|limits lightweight|limits native|compression lightweight|compression native|compression-wss lightweight|compression-wss native|performance lightweight|performance native|performance-wss lightweight|performance-wss native}" >&2
    exit 2
    ;;
esac

if [ "$port" != 18081 ]; then
  printf '%s\n' \
    "FLYOLOGY_WEBSOCKET_PORT currently must be 18081 (the pinned specs use it)" >&2
  exit 2
fi

report_dir="$project_root/build/autobahn/$report_name"
server_log="$report_dir/server.log"
suite_log="$report_dir/autobahn.log"
server="$project_root/tests/bin/autobahn/websocket_conformance_server"
server_pid=

cleanup () {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

cd "$project_root"
"$alr" build --release
release_config="$project_root/config/flyology_config.gpr"
if ! grep -Eq 'Build_Profile[^:]*:[^=]*=[[:space:]]*"release"' "$release_config" ||
   ! grep -q '"-O3"' "$release_config"
then
  printf '%s\n' \
    "Alire did not generate the expected release/-O3 project configuration" >&2
  exit 1
fi
FLYOLOGY_DEFAULT=lightweight FLYOLOGY_LOOP_POOL_SIZE=1 \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
"$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$project_root/build/rts" \
  --subdirs=autobahn \
  -f -p \
  -P tests/runtime_smoke.gpr \
  websocket_conformance_server.adb \
  -cargs:Ada -O3

mkdir -p "$report_dir"
find "$report_dir" -type f -delete
{
  printf '%s\n' '{'
  printf '%s\n' '  "buildProfile": "release",'
  printf '%s\n' '  "libraryProfileSource": "Alire --release",'
  printf '%s\n' '  "adaOptimization": "-O3",'
  printf '  "profile": "%s",\n' "$profile"
  printf '  "lane": "%s"\n' "$lane"
  printf '%s\n' '}'
} >"$report_dir/run-metadata.json"
"$server" "$lane" "$port" 32 "$transport" \
  "$project_root/tests/fixtures/tls/server-cert.pem" \
  "$project_root/tests/fixtures/tls/server-key.pem" \
  "${FLYOLOGY_OPENSSL_LIBRARY_DIR:-}" >"$server_log" 2>&1 &
server_pid=$!

ready=false
for attempt in $(seq 1 100); do
  if grep '^READY ' "$server_log" >/dev/null 2>&1; then
    ready=true
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if [ "$ready" != true ]; then
  cat "$server_log" >&2
  exit 1
fi

if ! docker run --rm --platform linux/amd64 --network host \
  -v "$project_root/tests/autobahn:/config:ro" \
  -v "$report_dir:/reports" \
  "$image" \
  wstest -m fuzzingclient -s "/config/$spec" >"$suite_log" 2>&1
then
  cat "$suite_log" >&2
  exit 1
fi

if ! kill -0 "$server_pid" 2>/dev/null; then
  printf '%s\n' "WebSocket conformance server exited during the run" >&2
  cat "$server_log" >&2
  exit 1
fi

behavior_counts=$(sed -n \
  's/^   "behavior": "\([^"]*\)",/\1/p' \
  "$report_dir"/*_case_*.json | sort | uniq -c)
close_counts=$(sed -n \
  's/^   "behaviorClose": "\([^"]*\)",/\1/p' \
  "$report_dir"/*_case_*.json | sort | uniq -c)
unexpected_behavior=$(sed -n \
  's/^   "behavior": "\([^"]*\)",/\1/p' \
  "$report_dir"/*_case_*.json | \
  awk '$1 != "OK" && $1 != "NON-STRICT" && $1 != "INFORMATIONAL" {n++}
       END {print n + 0}')
unexpected_close=$(sed -n \
  's/^   "behaviorClose": "\([^"]*\)",/\1/p' \
  "$report_dir"/*_case_*.json | \
  awk '$1 != "OK" && $1 != "NON-STRICT" && $1 != "INFORMATIONAL" {n++}
       END {print n + 0}')

printf '%s\n' "Autobahn behavior verdicts ($profile, $lane):"
printf '%s\n' "$behavior_counts"
printf '%s\n' "Autobahn close verdicts ($profile, $lane):"
printf '%s\n' "$close_counts"
printf '%s\n' "HTML report: $report_dir/index.html"

if [ "$unexpected_behavior" -ne 0 ] || [ "$unexpected_close" -ne 0 ]; then
  exit 1
fi
