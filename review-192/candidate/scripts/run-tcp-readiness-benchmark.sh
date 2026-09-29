#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
loops=${1:-1}
connections=${2:-16}
requests=${3:-500000}
output=${4:-"$project_root/build/tcp-readiness-oha.json"}

for value in "$loops" "$connections" "$requests"; do
  case "$value" in
    ''|*[!0-9]*|0)
      printf '%s\n' "loops, connections, and requests must be positive integers" >&2
      exit 2
      ;;
  esac
done
if [ "$loops" -gt 128 ] || [ "$connections" -gt 4096 ]; then
  printf '%s\n' "loops cannot exceed 128 and connections cannot exceed 4096" >&2
  exit 2
fi
if [ "$requests" -lt "$connections" ]; then
  printf '%s\n' "requests must be at least connections" >&2
  exit 2
fi
if ! command -v oha >/dev/null 2>&1; then
  printf '%s\n' "oha is required for the TCP readiness benchmark" >&2
  exit 2
fi

alr=$("$project_root/scripts/find-alr.sh")
#  A fresh checkout has no generated config/flyology_config.* yet. Generate
#  configuration sources before preparing or selecting the benchmark RTS.
"$alr" build --stop-after=generation >/dev/null

mkdir -p "$(dirname -- "$output")" "$project_root/build/tcp-readiness"
server_log="$project_root/build/tcp-readiness/server-$loops-$connections.log"
server_time="$project_root/build/tcp-readiness/server-$loops-$connections.time"
client_time="$project_root/build/tcp-readiness/oha-$loops-$connections.time"

FLYOLOGY_DEFAULT=native \
FLYOLOGY_LOOP_POOL_SIZE="$loops" \
FLYOLOGY_PLACEMENT=round_robin \
  "$project_root/scripts/prepare-rts.sh" >/dev/null
rts="$project_root/build/rts"
if [ ! -f "$rts/.flyology-rts-root" ]; then
  printf '%s\n' "refusing to benchmark without Flyology custom RTS marker: $rts/.flyology-rts-root" >&2
  exit 1
fi

(
  cd "$project_root"
  if [ -n "${FLYOLOGY_GPRBUILD:-}" ]; then
    compiler_prefix=$("$project_root/scripts/gnat-native-prefix.sh" "$alr")
    env -u GPR_CONFIG \
      PATH="$compiler_prefix/bin:$PATH" \
      "$FLYOLOGY_GPRBUILD" \
      --RTS="$rts" -q -f -p -P benchmarks/tcp_readiness_benchmark.gpr \
      -largs -nodefaultrpaths
  else
    "$alr" exec -- env -u GPR_CONFIG gprbuild \
      --RTS="$rts" -q -f -p -P benchmarks/tcp_readiness_benchmark.gpr
  fi
)

/usr/bin/time -lp \
  "$project_root/benchmarks/bin/tcp_readiness_benchmark" "$connections" \
  >"$server_log" 2>"$server_time" &
server_pid=$!
cleanup () {
  if kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

port=
attempt=0
while [ "$attempt" -lt 500 ]; do
  port=$(sed -n 's/^ready port= *\([0-9][0-9]*\).*/\1/p' "$server_log" | head -n 1)
  [ -n "$port" ] && break
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$server_log" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.01
done
if [ -z "$port" ]; then
  printf '%s\n' "server did not publish its port" >&2
  exit 1
fi

/usr/bin/time -lp oha --no-tui --disable-color --http-version 1.1 \
  -j -n "$requests" -c "$connections" "http://127.0.0.1:$port/" \
  >"$output" 2>"$client_time"
wait "$server_pid"
trap - EXIT HUP INT TERM
cat "$server_log"
printf '%s\n' "server_resource_usage:"
cat "$server_time"
printf '%s\n' "oha_resource_usage:"
cat "$client_time"
jq \
  '{summary, latencyPercentiles, responseTimeHistogram, statusCodeDistribution}' \
  "$output"
