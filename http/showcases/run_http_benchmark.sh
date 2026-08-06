#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
showcase_root="$project_root/showcases"
alr=$("$project_root/scripts/find-alr.sh")
requests=${1:-100000}
concurrency=${2:-256}
handlers=${3:-256}
port=${4:-18080}
detected_cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || :)
if [ -z "$detected_cpus" ]; then
  detected_cpus=$(sysctl -n hw.logicalcpu 2>/dev/null || printf '%s' 1)
fi
loops=${5:-$detected_cpus}
trials=${6:-3}
warmup=${7:-10000}
profile=${8:-release}
cooldown=${9:-20}
warmup_concurrency=${10:-$concurrency}
server_log="$project_root/build/http-benchmark-server.log"
upload_body="$project_root/build/http-benchmark-upload.bin"

if ! command -v oha >/dev/null 2>&1; then
  printf '%s\n' "oha is required: https://github.com/hatoo/oha"
  exit 1
fi

if [ "$warmup_concurrency" -gt "$concurrency" ]; then
  warmup_concurrency=$concurrency
fi

case "$profile" in
  development|release) ;;
  *)
    printf '%s\n' "profile must be development or release"
    exit 1
    ;;
esac

cd "$project_root"
if [ "$profile" = release ]; then
  "$alr" build --release >/dev/null
else
  "$alr" build --development >/dev/null
fi
"$showcase_root/prepare-alire.sh" "$profile" >/dev/null
FLYOLOGY_DEFAULT=lightweight FLYOLOGY_LOOP_POOL_SIZE="$loops" \
  FLYOLOGY_RTS_DIR="$project_root/build/rts" \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
cd "$showcase_root"
FLYOLOGY_SHOWCASE_PROFILE="$profile" "$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P showcases.gpr \
  http_benchmark_server.adb \
  http_benchmark_runtime_probe.adb

observed_loops=$("$showcase_root/bin/http_benchmark_runtime_probe")
if [ "$observed_loops" -ne "$loops" ]; then
  printf '%s\n' \
    "linked runtime has $observed_loops event loops; expected $loops" >&2
  exit 1
fi

mkdir -p "$project_root/build"
dd if=/dev/zero of="$upload_body" bs=1024 count=32 2>/dev/null

run_case () {
  lane=$1
  trial=$2
  name=$3
  path=$4

  case "$name" in
    routed-get|middleware|admission)
      if [ "$warmup" -gt 0 ]; then
        oha -n "$warmup" -c "$warmup_concurrency" --no-tui \
          "http://127.0.0.1:$active_port$path" >/dev/null
      fi
      printf '\n-- %s --\n' "$name"
      printf '%s\n' \
        "command: oha -n $requests -c $concurrency --no-tui http://127.0.0.1:$active_port$path"
      oha -n "$requests" -c "$concurrency" --no-tui \
        "http://127.0.0.1:$active_port$path"
      ;;
    buffered)
      if [ "$warmup" -gt 0 ]; then
        oha -n "$warmup" -c "$warmup_concurrency" --no-tui \
          -m POST -T application/json -d '{"value":"flyology"}' \
          "http://127.0.0.1:$active_port$path" >/dev/null
      fi
      printf '\n-- %s --\n' "$name"
      printf '%s\n' \
        "command: oha -n $requests -c $concurrency --no-tui -m POST -T application/json -d {\"value\":\"flyology\"} http://127.0.0.1:$active_port$path"
      oha -n "$requests" -c "$concurrency" --no-tui \
        -m POST -T application/json -d '{"value":"flyology"}' \
        "http://127.0.0.1:$active_port$path"
      ;;
    streamed-upload)
      if [ "$warmup" -gt 0 ]; then
        oha -n "$warmup" -c "$warmup_concurrency" --no-tui \
          -m POST -T application/octet-stream -D "$upload_body" \
          "http://127.0.0.1:$active_port$path" >/dev/null
      fi
      printf '\n-- %s --\n' "$name"
      printf '%s\n' \
        "command: oha -n $requests -c $concurrency --no-tui -m POST -T application/octet-stream -D $upload_body http://127.0.0.1:$active_port$path"
      oha -n "$requests" -c "$concurrency" --no-tui \
        -m POST -T application/octet-stream -D "$upload_body" \
        "http://127.0.0.1:$active_port$path"
      ;;
  esac
}

run_lane () {
  lane=$1
  trial=$2
  if [ "$lane" = lightweight ]; then
    lane_offset=0
  else
    lane_offset=1
  fi
  active_port=$((port + (trial - 1) * 2 + lane_offset))
  : >"$server_log"
  "$project_root/showcases/bin/http_benchmark_server" \
    "$lane" 0 "$active_port" "$handlers" >"$server_log" 2>&1 &
  server_pid=$!
  cleanup() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  }
  trap cleanup EXIT INT TERM

  ready=false
  attempt=0
  while [ "$attempt" -lt 100 ]; do
    if rg -q "^READY $lane " "$server_log"; then
      ready=true
      break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 0.05
  done

  if [ "$ready" != true ]; then
    printf '%s\n' "HTTP benchmark server did not become ready: $lane"
    sed -n '1,120p' "$server_log"
    exit 1
  fi

  if [ "$lane" = lightweight ]; then
    execution_parallelism="$loops event-loop pthreads"
  else
    execution_parallelism="$handlers handler pthreads on $detected_cpus logical CPUs"
  fi
  printf '\n== HTTP/1.1 %s handlers, trial %s/%s ==\n' \
    "$lane" "$trial" "$trials"
  printf '%s\n' \
    "$(oha --version)" \
    "profile=$profile warmup=$warmup warmup_concurrency=$warmup_concurrency" \
    "cooldown_between_lanes=$cooldown seconds" \
    "requests=$requests concurrency=$concurrency handlers=$handlers" \
    "logical_cpus=$detected_cpus" \
    "port=$active_port" \
    "execution_parallelism=$execution_parallelism" \
    "upload_bytes=32768"

  run_case "$lane" "$trial" routed-get /route
  run_case "$lane" "$trial" middleware /middleware
  run_case "$lane" "$trial" buffered /buffered
  run_case "$lane" "$trial" streamed-upload /upload
  run_case "$lane" "$trial" admission /admission

  cleanup
  trap - EXIT INT TERM
  if [ "$cooldown" -gt 0 ]; then
    sleep "$cooldown"
  fi
}

trial=1
while [ "$trial" -le "$trials" ]; do
  if [ $((trial % 2)) -eq 1 ]; then
    run_lane lightweight "$trial"
    run_lane native "$trial"
  else
    run_lane native "$trial"
    run_lane lightweight "$trial"
  fi
  trial=$((trial + 1))
done
