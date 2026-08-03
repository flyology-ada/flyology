#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
server_log="$project_root/build/http-benchmark-server.log"

if ! command -v oha >/dev/null 2>&1; then
  printf '%s\n' "oha is required: https://github.com/hatoo/oha"
  exit 1
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
FLYOLOGY_DEFAULT=lightweight FLYOLOGY_LOOP_POOL_SIZE="$loops" \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
FLYOLOGY_SHOWCASE_PROFILE="$profile" "$alr" exec -- gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P showcases/showcases.gpr \
  http_server.adb

run_lane () {
  lane=$1
  trial=$2
  : >"$server_log"
  "$project_root/showcases/bin/http_server" \
    "$lane" 0 "$port" "$handlers" >"$server_log" 2>&1 &
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

  if [ "$warmup" -gt 0 ]; then
    oha -n "$warmup" -c "$concurrency" --no-tui \
      "http://127.0.0.1:$port/" >/dev/null
  fi

  if [ "$lane" = lightweight ]; then
    execution_parallelism="$loops event-loop pthreads"
  else
    execution_parallelism="$handlers handler pthreads on $detected_cpus logical CPUs"
  fi
  printf '\n== HTTP/1.1 %s handlers, trial %s/%s ==\n' \
    "$lane" "$trial" "$trials"
  printf '%s\n' \
    "oha $(oha --version)" \
    "profile=$profile warmup=$warmup" \
    "requests=$requests concurrency=$concurrency handlers=$handlers" \
    "execution_parallelism=$execution_parallelism" \
    "command: oha -n $requests -c $concurrency --no-tui http://127.0.0.1:$port/"
  oha -n "$requests" -c "$concurrency" --no-tui \
    "http://127.0.0.1:$port/"

  cleanup
  trap - EXIT INT TERM
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
