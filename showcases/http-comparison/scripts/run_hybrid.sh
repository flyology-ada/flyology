#!/bin/sh
set -eu

comparison_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_root=$(CDPATH= cd -- "$comparison_root/../.." && pwd)
duration=${HTTP_HYBRID_DURATION:-${HTTP_BENCH_DURATION:-10s}}
warmup=${HTTP_HYBRID_WARMUP:-${HTTP_BENCH_WARMUP:-2s}}
concurrencies=${HTTP_HYBRID_CONCURRENCIES:-"1 8 32 128"}
trials=${HTTP_HYBRID_TRIALS:-3}
workers=${HTTP_HYBRID_WORKERS:-"1 2 4 8"}
queue_capacity=${HTTP_HYBRID_QUEUE_CAPACITY:-128}
targets_us=${HTTP_HYBRID_TARGETS_US:-"500 2000 10000"}
capacity=${HTTP_HYBRID_HANDLER_CAPACITY:-256}
base_port=${HTTP_HYBRID_BASE_PORT:-18100}
cooldown=${HTTP_HYBRID_COOLDOWN:-2}
mixed=${HTTP_HYBRID_MIXED:-1}
mixed_cpu_concurrency=${HTTP_HYBRID_MIXED_CPU_CONCURRENCY:-32}
mixed_control_concurrency=${HTTP_HYBRID_MIXED_CONTROL_CONCURRENCY:-8}
verify_only=${HTTP_HYBRID_VERIFY_ONLY:-0}
server_cpuset=${HTTP_BENCH_SERVER_CPUSET:-}
client_cpuset=${HTTP_BENCH_CLIENT_CPUSET:-}
output_root=${HTTP_HYBRID_OUTPUT_ROOT:-"$project_root/build/http-comparison/hybrid-results"}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_root="$output_root/$timestamp"
run_root="$result_root/runs"
resource_root="$result_root/resources"
stats_root="$result_root/executor-stats"
log_root="$result_root/logs"
calibration="$result_root/calibration.json"
calibration_rows="$result_root/calibration.tsv"

case "$mixed:$verify_only" in
   0:0|0:1|1:0|1:1) ;;
   *) printf '%s\n' "HTTP_HYBRID_MIXED and HTTP_HYBRID_VERIFY_ONLY must be 0 or 1" >&2; exit 2 ;;
esac
if { [ -n "$server_cpuset" ] || [ -n "$client_cpuset" ]; } &&
   ! command -v taskset >/dev/null 2>&1; then
   printf '%s\n' "taskset is required when a benchmark CPU set is configured" >&2
   exit 1
fi
for command_name in cmp curl oha python3 rg; do
   if ! command -v "$command_name" >/dev/null 2>&1; then
      printf '%s\n' "$command_name is required" >&2
      exit 1
   fi
done

server_binary="$project_root/showcases/bin/http_hybrid_benchmark_server"
calibrator_binary="$project_root/showcases/bin/http_cpu_calibrator"
for binary in "$server_binary" "$calibrator_binary"; do
   if [ ! -x "$binary" ]; then
      printf '%s\n' "missing benchmark fixture: $binary" >&2
      printf '%s\n' "run $comparison_root/scripts/build.sh first" >&2
      exit 1
   fi
done

mkdir -p "$run_root" "$resource_root" "$stats_root" "$log_root"
set -- "$calibrator_binary" "$calibration" --targets-us $targets_us
if [ -n "$server_cpuset" ]; then
   set -- "$@" --cpuset "$server_cpuset"
fi
"$comparison_root/scripts/calibrate_cpu.py" "$@"
python3 - "$calibration" >"$calibration_rows" <<'PY'
import json
import sys
for item in json.load(open(sys.argv[1]))["calibration"]:
    print(f"{item['target_us']}|{item['iterations']}|{item['observed_us']}|{item['checksum']}")
PY

HTTP_BENCH_MODE=${HTTP_BENCH_MODE:-hybrid-local} \
HTTP_BENCH_CAPACITY="$capacity" \
HTTP_BENCH_CONCURRENCIES="$concurrencies" \
HTTP_BENCH_DURATION="$duration" \
HTTP_BENCH_CLIENT_CPUSET="$client_cpuset" \
HTTP_BENCH_SERVER_CPUSET="$server_cpuset" \
HTTP_BENCH_TIERS=hybrid \
HTTP_BENCH_TRIALS="$trials" \
HTTP_BENCH_WARMUP="$warmup" \
HTTP_HYBRID_WORKERS="$workers" \
HTTP_HYBRID_QUEUE_CAPACITY="$queue_capacity" \
HTTP_HYBRID_TARGETS_US="$targets_us" \
HTTP_HYBRID_COOLDOWN="$cooldown" \
HTTP_HYBRID_MIXED="$mixed" \
HTTP_HYBRID_MIXED_CPU_CONCURRENCY="$mixed_cpu_concurrency" \
HTTP_HYBRID_MIXED_CONTROL_CONCURRENCY="$mixed_control_concurrency" \
   "$comparison_root/scripts/collect_metadata.py" >"$result_root/metadata.json"

server_pid=
sampler_pid=
cpu_load_pid=
cleanup_server () {
   if [ -n "$cpu_load_pid" ]; then
      kill -TERM "$cpu_load_pid" 2>/dev/null || true
      wait "$cpu_load_pid" 2>/dev/null || true
      cpu_load_pid=
   fi
   if [ -n "$sampler_pid" ]; then
      kill -TERM "$sampler_pid" 2>/dev/null || true
      wait "$sampler_pid" 2>/dev/null || true
      sampler_pid=
   fi
   if [ -n "$server_pid" ]; then
      kill -TERM "$server_pid" 2>/dev/null || true
      wait "$server_pid" 2>/dev/null || true
      server_pid=
   fi
}
trap cleanup_server EXIT HUP INT TERM

run_oha () {
   if [ -n "$client_cpuset" ]; then
      taskset -c "$client_cpuset" oha "$@"
   else
      oha "$@"
   fi
}

launch_server () {
   log=$1
   shift
   if [ -n "$server_cpuset" ]; then
      taskset -c "$server_cpuset" "$@" >"$log" 2>&1 &
   else
      "$@" >"$log" 2>&1 &
   fi
   server_pid=$!
}

await_ready () {
   url=$1
   attempt=0
   while [ "$attempt" -lt 200 ]; do
      if curl --fail --silent --show-error --max-time 1 "$url" >/dev/null 2>&1; then
         return
      fi
      if ! kill -0 "$server_pid" 2>/dev/null; then
         return 1
      fi
      attempt=$((attempt + 1))
      sleep 0.05
   done
   return 1
}

configurations="inline"
for worker_count in $workers; do
   configurations="$configurations hybrid-w$worker_count"
done
configurations="$configurations fully-native"

rotated_configurations () {
   trial=$1
   set -- $configurations
   count=$#
   offset=$(((trial - 1) % count))
   index=0
   while [ "$index" -lt "$count" ]; do
      wanted=$(((offset + index) % count + 1))
      eval "value=\${$wanted}"
      printf '%s\n' "$value"
      index=$((index + 1))
   done
}

verify_body () {
   verify_url=$1
   verify_expected=$2
   verify_output=$3
   verify_headers=$4
   curl --fail --silent --show-error --http1.1 --max-time 30 \
      --dump-header "$verify_headers" --output "$verify_output" "$verify_url"
   if ! cmp -s "$verify_expected" "$verify_output"; then
      printf '%s\n' "response mismatch for $verify_url" >&2
      exit 1
   fi
   if ! tr -d '\r' <"$verify_headers" | \
      rg -qi '^content-type:[[:space:]]*text/plain'; then
      printf '%s\n' "wrong Content-Type for $verify_url" >&2
      exit 1
   fi
}

run_measured () {
   trial=$1
   variant=$2
   target=$3
   worker_count=$4
   queue=$5
   workload=$6
   concurrency=$7
   url=$8
   destination="$run_root/trial-$(printf '%02d' "$trial")__${variant}__us${target}__w${worker_count}__q${queue}__${workload}__c$(printf '%04d' "$concurrency").json"
   printf 'trial=%s variant=%s target_us=%s workers=%s queue=%s workload=%s concurrency=%s\n' \
      "$trial" "$variant" "$target" "$worker_count" "$queue" "$workload" "$concurrency"
   run_oha -z "$duration" -c "$concurrency" -w --no-tui --disable-color \
      --http-version 1.1 -r 0 -t 30s -j -o "$destination" "$url"
   "$comparison_root/scripts/check_oha.py" "$destination"
}

run_mixed () {
   trial=$1
   variant=$2
   target=$3
   worker_count=$4
   queue=$5
   cpu_url=$6
   control_url=$7
   cpu_destination="$run_root/trial-$(printf '%02d' "$trial")__${variant}__us${target}__w${worker_count}__q${queue}__mixed-cpu__c$(printf '%04d' "$mixed_cpu_concurrency").json"
   control_destination="$run_root/trial-$(printf '%02d' "$trial")__${variant}__us${target}__w${worker_count}__q${queue}__mixed-control__c$(printf '%04d' "$mixed_control_concurrency").json"
   if [ -n "$client_cpuset" ]; then
      taskset -c "$client_cpuset" oha -z "$duration" \
         -c "$mixed_cpu_concurrency" -w --no-tui --disable-color \
         --http-version 1.1 -r 0 -t 30s -j -o "$cpu_destination" \
         "$cpu_url" &
   else
      oha -z "$duration" -c "$mixed_cpu_concurrency" -w --no-tui \
         --disable-color --http-version 1.1 -r 0 -t 30s -j \
         -o "$cpu_destination" "$cpu_url" &
   fi
   cpu_load_pid=$!
   sleep 0.2
   run_oha -z "$duration" -c "$mixed_control_concurrency" -w --no-tui \
      --disable-color --http-version 1.1 -r 0 -t 30s -j \
      -o "$control_destination" "$control_url"
   wait "$cpu_load_pid"
   cpu_load_pid=
   "$comparison_root/scripts/check_oha.py" "$cpu_destination"
   "$comparison_root/scripts/check_oha.py" "$control_destination"
}

max_target=$(printf '%s\n' $targets_us | tail -1)
trial=1
while [ "$trial" -le "$trials" ]; do
   while IFS='|' read -r target iterations observed_us checksum; do
      expected_file="$result_root/expected-us${target}.txt"
      printf 'iterations=%s checksum=%s' \
         "$iterations" "$checksum" >"$expected_file"
      for configuration in $(rotated_configurations "$trial"); do
         case "$configuration" in
            inline)
               variant=inline
               worker_count=0
               server_worker_count=1
               queue=0
               route=/cpu-inline
               server_variant=inline
               ;;
            fully-native)
               variant=fully-native
               worker_count=0
               server_worker_count=1
               queue=0
               route=/cpu-inline
               server_variant=fully-native
               ;;
            hybrid-w*)
               variant=hybrid
               worker_count=${configuration#hybrid-w}
               server_worker_count=$worker_count
               queue=$queue_capacity
               route=/cpu-native
               server_variant=hybrid
               ;;
         esac
         port=$((base_port + trial))
         key="trial-$(printf '%02d' "$trial")__${variant}__us${target}__w${worker_count}__q${queue}"
         log="$log_root/$key.log"
         launch_server "$log" "$server_binary" "$server_variant" "$port" \
            "$capacity" "$server_worker_count" "$queue" "$iterations"
         if ! await_ready "http://127.0.0.1:$port/io-control"; then
            printf '%s\n' "$configuration did not become ready" >&2
            sed -n '1,160p' "$log" >&2
            exit 1
         fi
         printf '%s' control >"$result_root/control.txt"
         verify_body "http://127.0.0.1:$port/io-control" \
            "$result_root/control.txt" "$result_root/verify.body" \
            "$result_root/verify.headers"
         verify_body "http://127.0.0.1:$port$route" "$expected_file" \
            "$result_root/verify.body" "$result_root/verify.headers"
         if [ "$variant" = hybrid ]; then
            verify_body "http://127.0.0.1:$port/cpu-inline" "$expected_file" \
               "$result_root/verify.body" "$result_root/verify.headers"
         fi

         if [ "$verify_only" -eq 0 ]; then
            "$comparison_root/scripts/sample_process.py" \
               "$server_pid" "$resource_root/$key.json" &
            sampler_pid=$!
            run_oha -z "$warmup" -c 32 -w --no-tui --disable-color \
               --http-version 1.1 -r 0 -t 30s \
               "http://127.0.0.1:$port$route" >/dev/null
            for concurrency in $concurrencies; do
               run_measured "$trial" "$variant" "$target" "$worker_count" \
                  "$queue" cpu "$concurrency" \
                  "http://127.0.0.1:$port$route"
            done
            if [ "$mixed" -eq 1 ] && [ "$target" -eq "$max_target" ]; then
               run_mixed "$trial" "$variant" "$target" "$worker_count" \
                  "$queue" "http://127.0.0.1:$port$route" \
                  "http://127.0.0.1:$port/io-control"
            fi
         fi

         curl --fail --silent --show-error --max-time 5 \
            "http://127.0.0.1:$port/executor-stats" \
            >"$stats_root/$key.json"
         python3 -m json.tool "$stats_root/$key.json" >/dev/null
         cleanup_server
         if [ "$cooldown" -gt 0 ] && [ "$verify_only" -eq 0 ]; then
            sleep "$cooldown"
         fi
      done
   done <"$calibration_rows"
   trial=$((trial + 1))
done

rm -f "$result_root"/verify.body "$result_root"/verify.headers \
   "$result_root"/control.txt "$result_root"/expected-us*.txt
trap - EXIT HUP INT TERM
if [ "$verify_only" -eq 0 ]; then
   "$comparison_root/scripts/summarize_hybrid.py" "$result_root"
else
   printf '%s\n' "all hybrid benchmark variants satisfy the response contract"
fi
printf '%s\n' "results: $result_root"
