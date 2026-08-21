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
printf '%s\n' "Running $crate_root/tests/bin/flyology_bench_smoke"
"$crate_root/tests/bin/flyology_bench_smoke" >"$work_dir/smoke.out" || {
  status=$?
  cat "$work_dir/smoke.out"
  exit "$status"
}
cat "$work_dir/smoke.out"
printf '%s\n' "Running $crate_root/tests/bin/recording_smoke"
"$crate_root/tests/bin/recording_smoke" >"$work_dir/recording.out" || {
  status=$?
  cat "$work_dir/recording.out"
  exit "$status"
}
cat "$work_dir/recording.out"
"$crate_root/tests/bin/flyology_bench-internal_statistics_smoke"
"$crate_root/tests/bin/custom_metrics_smoke" >"$work_dir/custom.out"
cat "$work_dir/custom.out"
grep -q 'flyology_bench.metrics.v2,"fake, timer",custom,primary_time' \
  "$work_dir/custom.out"
"$crate_root/tests/bin/baseline_gate_smoke" >"$work_dir/gate-smoke.out"
cat "$work_dir/gate-smoke.out"
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
"$crate_root/examples/bin/custom_metrics" >"$work_dir/custom-example.out"
grep -q 'cache_lookups' "$work_dir/custom-example.out"
grep -q '"timer_role":"primary_alternate"' "$work_dir/custom-example.out"
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

gate_baseline="$work_dir/example.baseline"
gate_identity='cpu=test-runner;policy=unplaced;switches=-O3;benchmark=v1'
if "$crate_root/examples/bin/baseline_gate" record "$gate_baseline" \
  >"$work_dir/gate-missing-identity.out" 2>&1
then
  printf '%s\n' "baseline example accepted a missing environment identity" >&2
  exit 1
fi
"$crate_root/examples/bin/baseline_gate" record "$gate_baseline" \
  "$gate_identity" \
  >"$work_dir/gate-record.out"
if "$crate_root/examples/bin/baseline_gate" check "$gate_baseline" \
  'cpu=other-runner;policy=unplaced;switches=-O3;benchmark=v1' \
  >"$work_dir/gate-incompatible.out" 2>&1
then
  printf '%s\n' "baseline example accepted an incompatible environment" >&2
  exit 1
fi
if ! grep -q 'status     | incompatible_baseline (rejected)' \
  "$work_dir/gate-incompatible.out"
then
  printf '%s\n' "baseline example did not report environment mismatch" >&2
  exit 1
fi
if FLYOLOGY_BENCH_OUTPUT=json \
  "$crate_root/examples/bin/baseline_gate" check "$gate_baseline" \
  "$gate_identity" >"$work_dir/gate.jsonl"
then
  :
elif ! grep -q '"status":"regression","rejected":true' \
  "$work_dir/gate.jsonl"
then
  printf '%s\n' "baseline JSON example failed without reporting regression" >&2
  exit 1
fi
if FLYOLOGY_BENCH_OUTPUT=csv \
  "$crate_root/examples/bin/baseline_gate" check "$gate_baseline" \
  "$gate_identity" >"$work_dir/gate.csv"
then
  :
elif ! grep -q ',regression,true,true,' "$work_dir/gate.csv"
then
  printf '%s\n' "baseline CSV example failed without reporting regression" >&2
  exit 1
fi
if FLYOLOGY_BENCH_GATE_REGRESSION=1 \
  "$crate_root/examples/bin/baseline_gate" check "$gate_baseline" \
  "$gate_identity" \
  >"$work_dir/gate-regression.out" 2>&1
then
  printf '%s\n' "baseline example accepted an established regression" >&2
  exit 1
fi
if ! grep -q 'status     | regression (rejected)' \
  "$work_dir/gate-regression.out"
then
  printf '%s\n' "baseline example did not report its rejected regression" >&2
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
    function parse_csv(line, values,    character, current, position, quoted,
                       total) {
      for (position in values) { delete values[position] }
      current = ""
      quoted = 0
      total = 1
      for (position = 1; position <= length(line); position += 1) {
        character = substr(line, position, 1)
        if (quoted) {
          if (character == "\"") {
            if (substr(line, position + 1, 1) == "\"") {
              current = current "\""
              position += 1
            } else {
              quoted = 0
            }
          } else {
            current = current character
          }
        } else if (character == ",") {
          values[total] = current
          total += 1
          current = ""
        } else if (character == "\"" && current == "") {
          quoted = 1
        } else {
          current = current character
        }
      }
      if (quoted) { return -1 }
      values[total] = current
      return total
    }

    BEGIN { failures = 0; headers = 0; rows = 0 }
    {
      fields = parse_csv($0, value)
      if (fields < 0) {
        printf "%s: unterminated quoted field: %s\n", source, $0 > "/dev/stderr"
        failures += 1
        next
      }
      if (value[1] == "name" || value[1] == "reference" ||
          value[1] == "schema") {
        headers += 1
        expected = fields
        available_column = 0
        status_column = 0
        for (column = 1; column <= fields; column += 1) {
          if (value[column] == "available") { available_column = column }
          if (value[column] == "status") { status_column = column }
        }
        next
      }
      if (fields <= 1) { next }
      rows += 1
      if (expected == 0) {
        printf "%s: row before any header: %s\n", source, $0 > "/dev/stderr"
        failures += 1
        next
      }
      if (fields != expected) {
        printf "%s: %d columns, header declares %d: %s\n",
          source, fields, expected, $0 > "/dev/stderr"
        failures += 1
      }
      if (status_column > 0) {
        status = value[status_column]
        if (status == "") {
          printf "%s: empty status: %s\n", source, $0 > "/dev/stderr"
          failures += 1
        }
        if (available_column > 0) {
          available = value[available_column]
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
awk '/^-- baseline gate machine output begin --$/ { inside = 1; next }
     /^-- baseline gate machine output end --$/ { inside = 0; next }
     inside { print }' "$work_dir/gate-smoke.out" >"$work_dir/gate-smoke.machine"
grep '^{' "$work_dir/gate-smoke.machine" >"$work_dir/gate-smoke.jsonl"
grep -v '^{' "$work_dir/gate-smoke.machine" >"$work_dir/gate-smoke.csv"
if ! grep -Fq '"gate,""case"' "$work_dir/gate-smoke.csv"
then
  printf '%s\n' "baseline gate CSV escaping failed validation" >&2
  exit 1
fi

awk '
  BEGIN { FS = ","; failures = 0 }
  NR == 1 {
    expected = NF
    if ($1 != "type" || $2 != "schema_version") { failures += 1 }
    next
  }
  NR == 2 {
    if (NF != expected || $1 != "baseline_gate" || $2 != "2") {
      failures += 1
    }
    next
  }
  END {
    if (NR != 2 || failures > 0) {
      print "baseline gate CSV schema failed validation" > "/dev/stderr"
      exit 1
    }
    print "baseline gate CSV verified"
  }
' "$work_dir/gate.csv"

awk '/^-- custom machine output begin --$/ { inside = 1; next }
     /^-- custom machine output end --$/ { inside = 0; next }
     inside && /^\{/ { print }' "$work_dir/custom.out" \
  >"$work_dir/custom.jsonl"
awk '/^-- custom machine output begin --$/ { inside = 1; next }
     /^-- custom machine output end --$/ { inside = 0; next }
     inside && !/^\{/ { print }' "$work_dir/custom.out" \
  >"$work_dir/custom.csv"
check_csv custom-metrics "$work_dir/custom.csv"
grep -q 'primary.*primary_time' "$work_dir/custom.out"
grep -q 'source.*deterministic_fake_ticks.*calibration harness wall' \
  "$work_dir/custom.out"
grep -q 'long_custom_metric_identity_over_32.*custom-units-per-batch' \
  "$work_dir/custom.out"
grep -q 'reference_resolution,contender_resolution,calibration_clock' \
  "$work_dir/custom.out"
grep -q 'failed_pair.*unavailable: reference counter reset; contender probe failed' \
  "$work_dir/custom.out"
grep -q 'failed_pair.*reference counter reset; contender probe failed' \
  "$work_dir/custom.out"
if command -v jq >/dev/null 2>&1; then
  jq -s -e '
    any(.[];
      .schema == "flyology_bench.metrics.v2"
      and .kind == "custom"
      and .axis == "primary_time"
      and .timer_role == "primary_alternate"
      and .timing_source == "deterministic_fake_ticks"
      and .calibration_clock == "harness_wall"
      and .resolution > 0
      and .resolution < 1)
    and any(.[];
      .schema == "flyology_bench.comparison_metrics.v2"
      and .kind == "custom"
      and .method == "relative percent"
      and .change == 60
      and .reference_resolution > 0
      and .contender_resolution > 0
      and (has("resolution") | not))
    and any(.[];
      .schema == "flyology_bench.metrics.v2"
      and .name == "failed_custom"
      and .kind == "custom"
      and .available == false
      and .status == "probe failed"
      and (has("mean") | not))
    and any(.[];
      .schema == "flyology_bench.comparison_metrics.v2"
      and .kind == "custom"
      and .axis == "failed_pair"
      and .available == false
      and .status == "reference counter reset; contender probe failed")
  ' "$work_dir/custom.jsonl" >/dev/null
else
  grep -q '"kind":"custom".*"timer_role":"primary_alternate"' \
    "$work_dir/custom.jsonl"
  grep -q '"calibration_clock":"harness_wall"' "$work_dir/custom.jsonl"
fi

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
if ! grep -q 'throughput_availability' "$work_dir/sweeps.csv" \
  || ! grep -q 'reference_throughput_availability' "$work_dir/sweeps.csv" \
  || ! grep -q 'contender_throughput_availability' "$work_dir/sweeps.csv"
then
  printf '%s\n' "sweep CSV lost exact throughput availability columns" >&2
  exit 1
fi

# At least one long-form metric section must exist, otherwise the checks above
# would pass over latency-only output.
if ! grep -q '^name,confidence_level_percent,bootstrap_resamples,axis,scope,unit,available,status,' "$work_dir/smoke.csv"
then
  printf '%s\n' "measurement metric CSV lost its status column" >&2
  exit 1
fi
if ! grep -q '^reference,contender,confidence_level_percent,bootstrap_resamples,axis,scope,unit,available,status,' \
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
      def statistics_ok:
        (.statistics.confidence_level_percent >= 50.0)
        and (.statistics.confidence_level_percent <= 99.9)
        and (.statistics.bootstrap_resamples >= 100)
        and (.statistics.bootstrap_resamples <= 10000);
      statistics_ok
      and
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
  jq -s -e '
    any(.[]; .statistics.bootstrap_resamples == 10000)
  ' "$work_dir/smoke.jsonl" >/dev/null \
    || { printf '%s\n' "maximum resample setting was not reported" >&2; exit 1; }
  while IFS= read -r line; do
    printf '%s\n' "$line" | jq -e . >/dev/null \
      || { printf '%s\n' "recording JSON object failed validation" >&2; exit 1; }
  done <"$work_dir/recording.jsonl"
  jq -s -e '
    any(.[];
      .sample_semantics == "individual_span"
      and .name == "fast\trequest"
      and .statistics.confidence_level_percent == 90.0
      and .statistics.bootstrap_resamples == 200
      and (.samples | length == 40)
      and all(.samples[];
        (.observation | type) == "number"
        and (.outcome == "success" or .outcome == "failure")
        and (.metrics | length > 0)
        and all(.metrics[]; has("axis") and has("status") and has("value"))))
    and any(.[];
      .comparison_design == "independent"
      and .statistics.confidence_level_percent == 80.0
      and .statistics.bootstrap_resamples == 150)
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
      and .statistics.confidence_level_percent == 95.0
      and .statistics.bootstrap_resamples == 2000
      and (.metrics | length > 0))
  ' "$work_dir/recording-example.jsonl" >/dev/null \
    || { printf '%s\n' "recording example JSON failed validation" >&2; exit 1; }
  check_json <"$work_dir/multi.json" \
    || { printf '%s\n' "multi-comparison JSON failed validation" >&2; exit 1; }
  jq -e '
    .type == "baseline_gate"
    and .schema_version == 2
    and (.status | type) == "string"
    and (.rejected | type) == "boolean"
    and (.compatible | type) == "boolean"
    and .bootstrap_method == "circular_block_mean_ratio"
    and .confidence_level_percent == 95
    and .bootstrap_resamples == 2000
    and .random_seed == 97
    and has("speedup_ci_low")
    and has("speedup_ci_high")
    and has("time_change_ci_low")
    and has("time_change_ci_high")
    and (.reason | type) == "string"
  ' "$work_dir/gate.jsonl" >/dev/null \
    || { printf '%s\n' "baseline gate JSON failed validation" >&2; exit 1; }
  jq -e '
    .type == "baseline_gate"
    and .current_name == "gate,\"case"
    and .status == "practical_equivalence"
    and .rejected == false
    and .random_seed == 103
    and (.time_change_ci_low | type) == "number"
    and (.time_change_ci_high | type) == "number"
  ' "$work_dir/gate-smoke.jsonl" >/dev/null \
    || { printf '%s\n' "escaped baseline gate JSON failed validation" >&2; exit 1; }
  jq -s -e '
    any(.[];
      .type == "sweep_point"
      and .benchmark == "group/case,\"escaped\""
      and .point == "count:1"
      and .parameter_value == 1
      and .work.available == true
      and .work.raw_value == 1
      and .sample_semantics == "per_operation_batch_mean"
      and .collection_available == true
      and .available == true
      and .throughput.availability == "throughput_available"
      and .throughput.direction == "higher_is_better")
    and any(.[];
      .type == "sweep_point"
      and .result_kind == "paired_comparison"
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
      and .work.display_scaling == null
      and .collection_available == false)
    and any(.[];
      .type == "sweep_point"
      and .benchmark == "group/dry"
      and .available == false
      and .status == "point_dry_run"
      and .median_elapsed_ns == null)
    and any(.[];
      .type == "empirical_scaling"
      and .status == "scaling_available"
      and .parameter_kind == "size"
      and .range_available == true
      and .selected_model == "linear"
      and (.models | length) == 6)
    and any(.[];
      .type == "empirical_scaling"
      and .benchmark == "group/empty"
      and .status == "too_few_distinct_points"
      and .parameter_kind == null
      and .range_available == false
      and .minimum_input == null
      and .maximum_input == null
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
    "$work_dir/gate.jsonl" "$work_dir/gate-smoke.jsonl" \
    "$work_dir/sweeps.jsonl"
fi
