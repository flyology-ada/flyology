#!/bin/sh
set -eu

comparison_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_root=$(CDPATH= cd -- "$comparison_root/../.." && pwd)
duration=${HTTP_BENCH_DURATION:-10s}
warmup=${HTTP_BENCH_WARMUP:-2s}
concurrencies=${HTTP_BENCH_CONCURRENCIES:-"1 8 32"}
trials=${HTTP_BENCH_TRIALS:-3}
capacity=${HTTP_BENCH_CAPACITY:-256}
base_port=${HTTP_BENCH_BASE_PORT:-18090}
cooldown=${HTTP_BENCH_COOLDOWN:-2}
include_churn=${HTTP_BENCH_INCLUDE_CHURN:-0}
verify_only=${HTTP_BENCH_VERIFY_ONLY:-0}
tiers=${HTTP_BENCH_TIERS:-"plain application"}
server_cpuset=${HTTP_BENCH_SERVER_CPUSET:-}
client_cpuset=${HTTP_BENCH_CLIENT_CPUSET:-}
output_root=${HTTP_BENCH_OUTPUT_ROOT:-"$project_root/build/http-comparison/results"}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_root="$output_root/$timestamp"
run_root="$result_root/runs"
resource_root="$result_root/resources"
log_root="$result_root/logs"

case "$include_churn:$verify_only" in
   0:0|0:1|1:0|1:1) ;;
   *) printf '%s\n' "HTTP_BENCH_INCLUDE_CHURN and HTTP_BENCH_VERIFY_ONLY must be 0 or 1" >&2; exit 2 ;;
esac

for tier in $tiers; do
   case "$tier" in
      plain|application) ;;
      *) printf '%s\n' "HTTP_BENCH_TIERS accepts plain and application" >&2; exit 2 ;;
   esac
done
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

flyology_binary="$project_root/showcases/bin/http_plain_benchmark_server"
flyology_app_binary="$project_root/showcases/bin/http_application_benchmark_server"
aws_binary="$comparison_root/servers/aws_plain/bin/aws_plain"
ews_binary="$comparison_root/servers/ews_plain/bin/ews_plain"
servletada_aws_binary="$comparison_root/servers/servletada_aws_app/bin/servletada_app"
servletada_ews_binary="$comparison_root/servers/servletada_ews_app/bin/servletada_app"
for binary in "$flyology_binary" "$flyology_app_binary" "$aws_binary" \
   "$ews_binary" "$servletada_aws_binary" "$servletada_ews_binary"; do
   if [ ! -x "$binary" ]; then
      printf '%s\n' "missing benchmark server: $binary" "run $comparison_root/scripts/build.sh first" >&2
      exit 1
   fi
done

mkdir -p "$run_root" "$resource_root" "$log_root"
HTTP_BENCH_MODE=${HTTP_BENCH_MODE:-local} \
HTTP_BENCH_CAPACITY="$capacity" \
HTTP_BENCH_CONCURRENCIES="$concurrencies" \
HTTP_BENCH_DURATION="$duration" \
HTTP_BENCH_CLIENT_CPUSET="$client_cpuset" \
HTTP_BENCH_SERVER_CPUSET="$server_cpuset" \
HTTP_BENCH_TIERS="$tiers" \
HTTP_BENCH_TRIALS="$trials" \
HTTP_BENCH_WARMUP="$warmup" \
   "$comparison_root/scripts/collect_metadata.py" >"$result_root/metadata.json"
cp "$comparison_root/workloads.conf" "$result_root/workloads.conf"
cp "$comparison_root/application-workloads.conf" \
   "$result_root/application-workloads.conf"

server_pid=
sampler_pid=
cleanup_server () {
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

server_order () {
   tier=$2
   if [ "$tier" = plain ]; then
      one="flyology-lightweight flyology-native aws ews"
      two="flyology-native ews flyology-lightweight aws"
      three="ews aws flyology-native flyology-lightweight"
      four="aws flyology-lightweight ews flyology-native"
   else
      one="flyology-app-lightweight flyology-app-native servletada-aws servletada-ews"
      two="flyology-app-native servletada-ews flyology-app-lightweight servletada-aws"
      three="servletada-ews servletada-aws flyology-app-native flyology-app-lightweight"
      four="servletada-aws flyology-app-lightweight servletada-ews flyology-app-native"
   fi
   case $((($1 - 1) % 4)) in
      0) printf '%s\n' "$one" ;;
      1) printf '%s\n' "$two" ;;
      2) printf '%s\n' "$three" ;;
      3) printf '%s\n' "$four" ;;
   esac
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

run_oha () {
   if [ -n "$client_cpuset" ]; then
      taskset -c "$client_cpuset" oha "$@"
   else
      oha "$@"
   fi
}

start_server () {
   server=$1
   port=$2
   log=$3
   case "$server" in
      flyology-lightweight)
         launch_server "$log" "$flyology_binary" lightweight "$port" "$capacity"
         ;;
      flyology-native)
         launch_server "$log" "$flyology_binary" native "$port" "$capacity"
         ;;
      aws)
         launch_server "$log" "$aws_binary" "$port" "$capacity"
         ;;
      ews)
         launch_server "$log" "$ews_binary" "$port"
         ;;
      flyology-app-lightweight)
         launch_server "$log" "$flyology_app_binary" lightweight "$port" "$capacity"
         ;;
      flyology-app-native)
         launch_server "$log" "$flyology_app_binary" native "$port" "$capacity"
         ;;
      servletada-aws)
         launch_server "$log" "$servletada_aws_binary" "$port" "$capacity"
         ;;
      servletada-ews)
         launch_server "$log" "$servletada_ews_binary" "$port" "$capacity"
         ;;
      *)
         printf '%s\n' "unknown server: $server" >&2
         exit 2
         ;;
   esac
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

verify_response () {
   server=$1
   url=$2
   workload=$3
   expected_type=$4
   expected_bytes=$5
   body="$result_root/verify-$server-$workload.body"
   headers="$result_root/verify-$server-$workload.headers"
   curl --fail --silent --show-error --http1.1 --max-time 5 \
      --dump-header "$headers" --output "$body" "$url"
   actual_bytes=$(wc -c <"$body" | tr -d ' ')
   if [ "$actual_bytes" -ne "$expected_bytes" ]; then
      printf '%s\n' \
        "$server $workload returned $actual_bytes bytes, expected $expected_bytes" >&2
      exit 1
   fi
   if ! tr -d '\r' <"$headers" | rg -qi "^content-type:[[:space:]]*$expected_type([[:space:]]*;|[[:space:]]*$)"; then
      printf '%s\n' "$server $workload returned the wrong Content-Type" >&2
      sed -n '1,40p' "$headers" >&2
      exit 1
   fi
   case "$workload" in
      plaintext|routed-get)
         if ! printf '%s' "Hello, World!" | cmp -s - "$body"; then
            printf '%s\n' "$server returned the wrong plaintext bytes" >&2
            exit 1
         fi
         ;;
      response-1k)
         if [ "$(tr -d 'x' <"$body" | wc -c | tr -d ' ')" -ne 0 ]; then
            printf '%s\n' "$server returned the wrong 1 KiB response bytes" >&2
            exit 1
         fi
         ;;
   esac
}

run_measured () {
   trial=$1
   server=$2
   workload=$3
   concurrency=$4
   connection_mode=$5
   url=$6
   destination="$run_root/trial-$(printf '%02d' "$trial")__${server}__${workload}__c$(printf '%04d' "$concurrency")__${connection_mode}.json"
   keepalive_option=
   if [ "$connection_mode" = churn ]; then
      keepalive_option=--disable-keepalive
   fi
   printf 'trial=%s server=%s workload=%s concurrency=%s connections=%s\n' \
      "$trial" "$server" "$workload" "$concurrency" "$connection_mode"
   run_oha -z "$duration" -c "$concurrency" -w --no-tui --disable-color \
      --http-version 1.1 -r 0 -t 5s -j $keepalive_option \
      -o "$destination" "$url"
   "$comparison_root/scripts/check_oha.py" "$destination"
}

trial=1
while [ "$trial" -le "$trials" ]; do
   tier_offset=0
   for tier in $tiers; do
      if [ "$tier" = plain ]; then
         workload_file="$comparison_root/workloads.conf"
      else
         workload_file="$comparison_root/application-workloads.conf"
      fi
      ready_path=$(rg -v '^(#|$)' "$workload_file" \
         | sed -n '1s/^[^|]*|\([^|]*\).*/\1/p')
      offset=0
      for server in $(server_order "$trial" "$tier"); do
         port=$((base_port + (trial - 1) * 16 + tier_offset + offset))
         offset=$((offset + 1))
         server_log="$log_root/trial-$(printf '%02d' "$trial")-$server.log"
         resource_file="$resource_root/trial-$(printf '%02d' "$trial")-$server.json"
         start_server "$server" "$port" "$server_log"
         if ! await_ready "http://127.0.0.1:$port$ready_path"; then
            printf '%s\n' "$server did not become ready" >&2
            sed -n '1,160p' "$server_log" >&2
            exit 1
         fi

         while IFS='|' read -r workload path expected_type expected_bytes; do
            case "$workload" in ''|'#'*) continue ;; esac
            verify_response "$server" "http://127.0.0.1:$port$path" \
               "$workload" "$expected_type" "$expected_bytes"
         done <"$workload_file"

         if [ "$verify_only" -eq 0 ]; then
            "$comparison_root/scripts/sample_process.py" "$server_pid" "$resource_file" &
            sampler_pid=$!
            while IFS='|' read -r workload path expected_type expected_bytes; do
               case "$workload" in ''|'#'*) continue ;; esac
               run_oha -z "$warmup" -c 32 -w --no-tui --disable-color \
                  --http-version 1.1 -r 0 -t 5s \
                  "http://127.0.0.1:$port$path" >/dev/null
               for concurrency in $concurrencies; do
                  run_measured "$trial" "$server" "$workload" "$concurrency" \
                     keepalive "http://127.0.0.1:$port$path"
                  if [ "$include_churn" -eq 1 ] && [ "$workload" = plaintext ]; then
                     run_measured "$trial" "$server" "$workload" "$concurrency" \
                        churn "http://127.0.0.1:$port$path"
                  fi
               done
            done <"$workload_file"
         fi

         cleanup_server
         if [ "$cooldown" -gt 0 ] && [ "$verify_only" -eq 0 ]; then
            sleep "$cooldown"
         fi
      done
      tier_offset=$((tier_offset + 4))
   done
   trial=$((trial + 1))
done

rm -f "$result_root"/verify-*.body "$result_root"/verify-*.headers
trap - EXIT HUP INT TERM
if [ "$verify_only" -eq 0 ]; then
   "$comparison_root/scripts/summarize.py" "$result_root"
else
   printf '%s\n' "all benchmark adapters satisfy the response contract"
fi
printf '%s\n' "results: $result_root"
