#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if command -v gprbuild >/dev/null 2>&1; then
  build() {
    gprbuild "$@"
  }
elif command -v alr >/dev/null 2>&1; then
  build() {
    alr -C "$crate_root" exec -- gprbuild "$@"
  }
else
  printf '%s\n' "gprbuild is unavailable; run this script through alr test" >&2
  exit 1
fi

work_dir=$(mktemp -d)
cleanup_work_dir() {
  rm -rf "$work_dir"
}
trap cleanup_work_dir EXIT

build -q -p -P "$crate_root/tests/flyology_bench_tests.gpr"
# Redirect rather than pipe: a pipeline would report tee's exit status and
# hide a failing smoke test.
"$crate_root/tests/bin/flyology_bench_smoke" >"$work_dir/smoke.out"
cat "$work_dir/smoke.out"
"$crate_root/tests/bin/recording_smoke" >"$work_dir/recording.out"
cat "$work_dir/recording.out"
"$crate_root/tests/bin/sweeps_smoke" >"$work_dir/sweeps.out"
cat "$work_dir/sweeps.out"
if ! grep -q 'throughput availability' "$work_dir/sweeps.out" \
  || ! grep -q 'throughput_available' "$work_dir/sweeps.out" \
  || ! grep -q 'KiB' "$work_dir/sweeps.out" \
  || ! grep -q 'kitems' "$work_dir/sweeps.out" \
  || ! grep -q 'Mrecords' "$work_dir/sweeps.out" \
  || ! grep -Eq '[KMGTPE]iB/s' "$work_dir/sweeps.out" \
  || ! grep -Eq 'point_setup_failed.*wall_time_unavailable' \
       "$work_dir/sweeps.out"
then
  printf '%s\n' "sweep console lost availability or configured work scaling" >&2
  exit 1
fi
build -q -p -P "$crate_root/examples/flyology_bench_examples.gpr"
"$crate_root/examples/bin/basic"
"$crate_root/examples/bin/sweep_comparison" >"$work_dir/sweep-example.out"
if ! grep -q '^empirical paired sweep sorting/in_place ' \
  "$work_dir/sweep-example.out" \
  || ! grep -q 'reference rate availability' "$work_dir/sweep-example.out" \
  || ! grep -q 'throughput_available' "$work_dir/sweep-example.out" \
  || [ "$(grep -c '^empirical scaling sorting/in_place/' \
       "$work_dir/sweep-example.out")" -ne 2 ]
then
  printf '%s\n' "sweep example did not report paired time/throughput and two scaling analyses" >&2
  exit 1
fi
"$crate_root/examples/bin/recording_service" \
  >"$work_dir/recording-example.ansi"
escape=$(printf '\033')
if ! grep -Fq "${escape}[2K" "$work_dir/recording-example.ansi" \
  || ! grep -q 'fly recorder  elapsed ' "$work_dir/recording-example.ansi"
then
  printf '%s\n' "recording example did not render an in-place ANSI dashboard" >&2
  exit 1
fi

# Machine-readable output is a published interface, so its shape is checked
# rather than only printed. The example emits the multi-way schemas; the smoke
# test emits the single-measurement and paired-comparison schemas.
FLYOLOGY_BENCH_OUTPUT=csv "$crate_root/examples/bin/basic" \
  >"$work_dir/multi.csv"
FLYOLOGY_BENCH_OUTPUT=json "$crate_root/examples/bin/basic" \
  >"$work_dir/multi.json"
FLYOLOGY_BENCH_RECORDING_OUTPUT=json \
  "$crate_root/examples/bin/recording_service" \
  >"$work_dir/recording-example.jsonl"
awk '/^-- machine output begin --$/ { inside = 1; next }
     /^-- machine output end --$/ { inside = 0; next }
     inside { print }' "$work_dir/smoke.out" >"$work_dir/smoke.machine"
if [ ! -s "$work_dir/smoke.machine" ]; then
  printf '%s\n' "smoke test emitted no machine-readable section" >&2
  exit 1
fi
grep '^{' "$work_dir/smoke.machine" >"$work_dir/smoke.jsonl"
grep -v '^{' "$work_dir/smoke.machine" >"$work_dir/smoke.csv"

# Every CSV row must carry exactly the columns its header declares, and the
# long-form metric schemas must agree between "available" and "status".
check_csv() {
  awk -v source="$1" '
    BEGIN { FS = ","; failures = 0; headers = 0; rows = 0 }
    $1 == "name" || $1 == "reference" {
      headers += 1
      expected = NF
      available_column = 0
      status_column = 0
      for (column = 1; column <= NF; column += 1) {
        if ($column == "available") { available_column = column }
        if ($column == "status") { status_column = column }
      }
      next
    }
    NF > 1 {
      rows += 1
      if (expected == 0) {
        printf "%s: row before any header: %s\n", source, $0 > "/dev/stderr"
        failures += 1
        next
      }
      if (NF != expected) {
        printf "%s: %d columns, header declares %d: %s\n",
          source, NF, expected, $0 > "/dev/stderr"
        failures += 1
      }
      if (status_column > 0) {
        status = $status_column
        if (status == "") {
          printf "%s: empty status: %s\n", source, $0 > "/dev/stderr"
          failures += 1
        }
        if (available_column > 0) {
          available = $available_column
          if (available == "true" && status != "collected") {
            printf "%s: available metric reports status %s\n",
              source, status > "/dev/stderr"
            failures += 1
          }
          if (available == "false" && status == "collected") {
            printf "%s: unavailable metric reports collected\n",
              source > "/dev/stderr"
            failures += 1
          }
        }
      }
    }
    END {
      if (headers == 0) {
        printf "%s: no CSV header found\n", source > "/dev/stderr"
        failures += 1
      }
      if (rows == 0) {
        printf "%s: no CSV rows found\n", source > "/dev/stderr"
        failures += 1
      }
      if (failures > 0) { exit 1 }
      printf "%s: %d CSV sections, %d rows verified\n", source, headers, rows
    }
  ' "$2"
}

check_csv multi-comparison "$work_dir/multi.csv"
check_csv measurement "$work_dir/smoke.csv"

awk '/^-- recording machine output begin --$/ { inside = 1; next }
     /^-- recording machine output end --$/ { inside = 0; next }
     inside { print }' "$work_dir/recording.out" >"$work_dir/recording.machine"
grep '^{' "$work_dir/recording.machine" >"$work_dir/recording.jsonl"
grep -v '^{' "$work_dir/recording.machine" >"$work_dir/recording.csv"
check_csv recording "$work_dir/recording.csv"

awk '/^-- sweep machine output begin --$/ { inside = 1; next }
     /^-- sweep machine output end --$/ { inside = 0; next }
     inside { print }' "$work_dir/sweeps.out" >"$work_dir/sweeps.machine"
grep '^{' "$work_dir/sweeps.machine" >"$work_dir/sweeps.jsonl"
grep -v '^{' "$work_dir/sweeps.machine" >"$work_dir/sweeps.csv"
awk '
  function csv_fields(line, i, ch, quoted, count) {
    quoted = 0
    count = 1
    for (i = 1; i <= length(line); i += 1) {
      ch = substr(line, i, 1)
      if (ch == "\"") {
        if (quoted && substr(line, i + 1, 1) == "\"") {
          i += 1
        } else {
          quoted = !quoted
        }
      } else if (ch == "," && !quoted) {
        count += 1
      }
    }
    return count
  }
  BEGIN { expected = 0; headers = 0; rows = 0; failures = 0 }
  substr($0, 1, 10) == "benchmark," {
    expected = csv_fields($0)
    headers += 1
    next
  }
  index($0, ",") > 0 {
    rows += 1
    actual = csv_fields($0)
    if (expected == 0 || actual != expected) {
      printf "sweep CSV column mismatch: expected %d, got %d: %s\n",
        expected, actual, $0 > "/dev/stderr"
      failures += 1
    }
  }
  END {
    if (headers != 3 || rows == 0) { failures += 1 }
    if (failures > 0) { exit 1 }
    printf "sweep: %d CSV sections, %d rows verified\n", headers, rows
  }
' "$work_dir/sweeps.csv"
if ! grep -q '^"group/case,""escaped""",count:1,' "$work_dir/sweeps.csv"
then
  printf '%s\n' "sweep CSV did not preserve escaped suite case identity" >&2
  exit 1
fi
if ! grep -q '^group/maximum,size:18446744073709551615,size,18446744073709551615,maximum,ordinary_measurement,true,bytes,bytes,18446744073709551615,' \
  "$work_dir/sweeps.csv"
then
  printf '%s\n' "sweep CSV lost an exact maximum parameter or work value" >&2
  exit 1
fi
if ! grep -q 'throughput_availability' "$work_dir/sweeps.csv" \
  || ! grep -q 'reference_throughput_availability' "$work_dir/sweeps.csv" \
  || ! grep -q 'contender_throughput_availability' "$work_dir/sweeps.csv"
then
  printf '%s\n' "sweep CSV lost exact throughput availability columns" >&2
  exit 1
fi

# At least one long-form metric section must exist, otherwise the checks above
# would pass over latency-only output.
if ! grep -q '^name,axis,scope,unit,available,status,' "$work_dir/smoke.csv"
then
  printf '%s\n' "measurement metric CSV lost its status column" >&2
  exit 1
fi
if ! grep -q '^reference,contender,axis,scope,unit,available,status,' \
  "$work_dir/multi.csv"
then
  printf '%s\n' "comparison metric CSV lost its status column" >&2
  exit 1
fi

# jq gives a real parse rather than a structural approximation. It is not a
# build dependency of the crate, so awk covers the same invariants when jq is
# absent; the Linux validation image installs jq so that path always runs.
if command -v jq >/dev/null 2>&1; then
  check_json() {
    jq -e '
      def metric_ok:
        (has("axis") and has("status") and (.status | type) == "string")
        and (.available == (.status == "collected"));
      def metrics_ok:
        (length > 0) and all(metric_ok);
      if .type == "multi_comparison" then
        (.reference.metrics | metrics_ok)
        and (.contenders | length > 0)
        and all(.contenders[];
                (.metrics | metrics_ok)
                and (.comparison_metrics | metrics_ok))
      elif .type == "comparison" then
        .metrics | metrics_ok
      else
        .metrics | metrics_ok
      end
    ' >/dev/null
  }
  while IFS= read -r line; do
    printf '%s\n' "$line" | check_json \
      || { printf '%s\n' "smoke JSON object failed validation" >&2; exit 1; }
  done <"$work_dir/smoke.jsonl"
  while IFS= read -r line; do
    printf '%s\n' "$line" | jq -e . >/dev/null \
      || { printf '%s\n' "recording JSON object failed validation" >&2; exit 1; }
  done <"$work_dir/recording.jsonl"
  jq -s -e '
    any(.[];
      .sample_semantics == "individual_span"
      and .name == "fast\trequest"
      and (.samples | length == 40)
      and all(.samples[];
        (.observation | type) == "number"
        and (.outcome == "success" or .outcome == "failure")
        and (.metrics | length > 0)
        and all(.metrics[]; has("axis") and has("status") and has("value"))))
    and any(.[];
      .comparison_design == "independent"
      and .wall_comparison_available == false
      and .speedup == null
      and .relative_change_percent == null)
    and any(.[];
      .comparison_design == "independent"
      and any(.metrics[]; .available == false
        and has("reference_status") and has("contender_status")))
  ' "$work_dir/recording.jsonl" >/dev/null \
    || { printf '%s\n' "recording alignment/status JSON failed validation" >&2; exit 1; }
  jq -s -e '
    length == 4
    and all(.[];
      .sample_semantics == "individual_span"
      and .observed > 0
      and (.metrics | length > 0))
  ' "$work_dir/recording-example.jsonl" >/dev/null \
    || { printf '%s\n' "recording example JSON failed validation" >&2; exit 1; }
  check_json <"$work_dir/multi.json" \
    || { printf '%s\n' "multi-comparison JSON failed validation" >&2; exit 1; }
  jq -s -e '
    any(.[];
      .type == "sweep_point"
      and .benchmark == "group/case,\"escaped\""
      and .point == "count:1"
      and .parameter_value == 1
      and .parameter_value_exact == "1"
      and .work.available == true
      and .work.raw_value == 1
      and .work.raw_value_exact == "1"
      and .sample_semantics == "per_operation_batch_mean"
      and .collection_available == true
      and .available == true
      and .throughput.availability == "throughput_available"
      and .throughput.direction == "higher_is_better")
    and any(.[];
      .type == "sweep_point"
      and .result_kind == "paired_comparison"
      and .parameter_value_exact == "1"
      and .work.raw_value_exact == "1"
      and .collection_available == true
      and (.paired_verdict | type) == "string"
      and .reference.throughput_availability == "throughput_available"
      and .contender.throughput_availability == "throughput_available"
      and .reference.operations_ci_low != null
      and .contender.work_ci_high != null)
    and any(.[];
      .type == "sweep_point"
      and .benchmark == "group/failure"
      and .point == "count:2"
      and .work.available == true
      and .collection_available == false
      and .available == false
      and .status == "point_setup_failed"
      and (.failure | contains("bad, \"point\""))
      and .median_elapsed_ns == null
      and .throughput.availability == "wall_time_unavailable"
      and .throughput.operations_per_second == null)
    and any(.[];
      .type == "sweep_point"
      and .benchmark == "group/work_failure"
      and .point == "count:2"
      and .work.available == false
      and .work.kind == null
      and .work.unit == null
      and .work.raw_value == null
      and .work.raw_value_exact == null
      and .work.display_scaling == null
      and .collection_available == false)
    and any(.[];
      .type == "sweep_point"
      and .benchmark == "group/dry"
      and .available == false
      and .status == "point_dry_run"
      and .median_elapsed_ns == null)
    and any(.[];
      .type == "sweep_point"
      and .benchmark == "group/maximum"
      and .point == "size:18446744073709551615"
      and .parameter_value_exact == "18446744073709551615"
      and .work.raw_value_exact == "18446744073709551615"
      and .status == "point_dry_run")
    and any(.[];
      .type == "empirical_scaling"
      and .status == "scaling_available"
      and .parameter_kind == "size"
      and .range_available == true
      and .selected_model == "linear"
      and (.models | length) == 6)
    and any(.[];
      .type == "empirical_scaling"
      and .benchmark == "group/inadequate"
      and .status == "no_adequate_model"
      and .selected_model == null
      and all(.models[]; .selected == false))
    and any(.[];
      .type == "empirical_scaling"
      and .benchmark == "group/boundary"
      and .status == "degenerate_input_range"
      and .minimum_input_exact == "9007199254740993"
      and .maximum_input_exact == "18014398509481985")
    and any(.[];
      .type == "empirical_scaling"
      and .benchmark == "group/empty"
      and .status == "too_few_distinct_points"
      and .parameter_kind == null
      and .range_available == false
      and .minimum_input == null
      and .minimum_input_exact == null
      and .maximum_input == null
      and .maximum_input_exact == null
      and any(.models[]; .model == "linear" and .nominal_exponent == 1)
      and any(.models[]; .model == "quadratic" and .nominal_exponent == 2)
      and any(.models[]; .model == "cubic" and .nominal_exponent == 3))
  ' "$work_dir/sweeps.jsonl" >/dev/null \
    || { printf '%s\n' "sweep JSON/schema integration failed validation" >&2; exit 1; }
  printf 'JSON verified with jq\n'
else
  awk '
    BEGIN { failures = 0; objects = 0 }
    {
      objects += 1
      if ($0 !~ /^\{/ || $0 !~ /\}$/) {
        printf "JSON object %d is not a single complete line\n",
          objects > "/dev/stderr"
        failures += 1
      }
      opens = gsub(/\{/, "{")
      closes = gsub(/\}/, "}")
      if (opens != closes) {
        printf "JSON object %d has %d open and %d close braces\n",
          objects, opens, closes > "/dev/stderr"
        failures += 1
      }
      if ($0 !~ /"status":/) {
        printf "JSON object %d carries no metric status\n",
          objects > "/dev/stderr"
        failures += 1
      }
    }
    END {
      if (objects == 0) {
        printf "no JSON objects found\n" > "/dev/stderr"
        failures += 1
      }
      if (failures > 0) { exit 1 }
      printf "JSON verified with awk (%d objects); install jq for a full parse\n",
        objects
    }
  ' "$work_dir/smoke.jsonl" "$work_dir/recording.jsonl" \
    "$work_dir/recording-example.jsonl" "$work_dir/multi.json" \
    "$work_dir/sweeps.jsonl"
fi
