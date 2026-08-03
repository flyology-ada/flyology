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
server_log="$project_root/build/http-benchmark-server.log"

if ! command -v oha >/dev/null 2>&1; then
  printf '%s\n' "oha is required: https://github.com/hatoo/oha"
  exit 1
fi

cd "$project_root"
FLYOLOGY_DEFAULT=lightweight FLYOLOGY_LOOP_POOL_SIZE="$loops" \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
"$alr" exec -- gprbuild \
  --RTS="$project_root/build/rts" \
  -P showcases/showcases.gpr \
  http_server.adb

for lane in lightweight native; do
  : >"$server_log"
  "$project_root/showcases/bin/http_server" \
    "$lane" "$requests" "$port" "$handlers" >"$server_log" 2>&1 &
  server_pid=$!
  cleanup() {
    kill "$server_pid" 2>/dev/null || true
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
  printf '\n== HTTP/1.1 %s handlers ==\n' "$lane"
  printf '%s\n' \
    "oha $(oha --version)" \
    "requests=$requests concurrency=$concurrency handlers=$handlers" \
    "execution_parallelism=$execution_parallelism" \
    "command: oha -n $requests -c $concurrency --no-tui http://127.0.0.1:$port/"
  oha -n "$requests" -c "$concurrency" --no-tui \
    "http://127.0.0.1:$port/"

  wait "$server_pid"
  trap - EXIT INT TERM
done
