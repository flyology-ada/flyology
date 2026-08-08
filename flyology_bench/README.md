# flyology_bench

`flyology_bench` is an adaptive microbenchmarking library for Ada. It is kept
in the Flyology repository because Flyology needs repeatable measurements of
tasking, synchronization, and I/O primitives, but the crate does not depend on
the Flyology runtime and can benchmark ordinary Ada libraries.

The initial API provides:

- adaptive batch sizing for nanosecond-scale operations;
- a native monotonic clock (`mach_absolute_time` on Darwin and
  `CLOCK_MONOTONIC_RAW` on Linux), with nominal and observed resolution;
- a warmup phase and a configurable total measurement budget;
- ordinary and caller-controlled batched measurements;
- untimed setup/teardown hooks and result-producing batches whose opaque result
  barrier runs after the ending timestamp;
- paired, order-balanced comparisons with equal timed slices by default;
- multi-way comparisons with equal-time calibration, position-balanced or
  sequential schedules, and an optional shared-iteration policy;
- geometric and median speedups, circular-block bootstrap confidence intervals,
  practical-effect verdicts, order-effect and serial-correlation diagnostics,
  relative time change, and per-pair win/loss counts;
- raw per-operation samples;
- minimum, median, mean, p95, p99, maximum, standard deviation, median absolute
  deviation, and coefficient of variation;
- deterministic circular-block bootstrap 95% confidence intervals;
- Tukey mild and severe outlier diagnostics without silently dropping samples;
- optional measured timestamp-cost subtraction, disabled by default;
- persisted raw-sample baselines with compatibility fingerprints;
- host/toolchain metadata and optional strict Linux or advisory Darwin thread
  placement;
- ANSI console result cards, in-place terminal progress, CSV, and
  newline-delimited JSON reporters; and
- explicit optimization and memory barriers.

## Add the crate

Version `0.1.0-dev` is distributed through the Flyology organization index.
Keep the community index enabled for the compiler, add the development index
ahead of it, and add the crate normally:

```sh
alr index --reset-community
alr index --add=git+https://github.com/flyology-ada/alire-index.git \
  --name=flyology --before=community
alr with flyology_bench
```

The organization index is a development channel until the crate has a
community-index release.

## Example

```ada
with Flyology_Bench;
with Flyology_Bench.Reporters;

procedure Example is
   Value : Natural := 1;

   procedure Work is
   begin
      Value := (Value * 33 + 17) mod 1_000_003;
   end Work;

   procedure Run is new Flyology_Bench.Measure (Work);
   Result : Flyology_Bench.Measurement;
   Config : constant Flyology_Bench.Configuration :=
     Flyology_Bench.Reporters.Terminal_Mode;
begin
   Run (Config => Config, Result => Result);
   Flyology_Bench.Reporters.Put_Console ("integer_mix", Result);
end Example;
```

`Measure` is generic so the benchmark operation is statically bound. The
framework times many calls with two clock reads per sample and reports the
result per operation. `Measure_Batched` instead passes the calibrated iteration
count to the caller; use it when one measured batch coordinates tasks or owns
setup that must not be repeated by the harness.

## Comparisons

Comparisons are measured directly rather than assembled from two independent
runs:

```ada
Existing_Value  : Natural := 1;
Contender_Value : Natural := 1;

procedure Existing is
begin
   Existing_Value := (Existing_Value * 33 + 17) mod 1_000_003;
end Existing;

procedure Contender is
begin
   Contender_Value := (Contender_Value * 33 + 17) mod 1_000_003;
end Contender;

procedure Compare is new Flyology_Bench.Compare
  (Reference_Operation => Existing,
   Contender_Operation => Contender);

Result : Flyology_Bench.Comparison;

Compare (Result => Result);
Flyology_Bench.Reporters.Put_Comparison_Console
  ("existing", "contender", Result);
```

Each sample pair runs the reference and contender adjacently. By default, each
side calibrates its own iteration count toward the same timed slice, so faster
implementations perform more logical operations instead of receiving less
measurement time. The harness deterministically shuffles which side runs first
while keeping the two order counts equal, or within one sample when the
configured count is odd. This limits order bias and makes each ratio local in
time instead of comparing one long reference run with a later contender run.

`Geometric_Mean_Speedup` is the geometric mean of paired
`reference time / contender time` ratios. A value greater than one means the
contender was faster. `Relative_Time_Change_Percent` reports the inverse view:
a negative value means the contender used less time. Their confidence bounds
come from deterministic circular-block resampling of paired log-ratios,
preserving both pair membership and short-range sample order. The result also
reports lag-one correlation and the difference between reference-first and
contender-first ratio groups. These diagnostics flag drift; they do not prove a
particular physical cause.

`Practical_Threshold_Percent` defaults to one percent. A verdict is
`Contender_Faster` or `Reference_Faster` only when the entire confidence
interval clears that threshold. It is `Practically_Equivalent` only when the
entire interval fits inside the threshold, and `Inconclusive` otherwise.

Set `Comparison_Batching => Shared_Iterations` when both sides must receive the
same logical operation count. In that policy, elapsed measurement time varies
with implementation speed and calibration stops expanding when the slower side
reaches eight times the target. `Compare_Batched` provides the same policies
for tasking, I/O, or fixture-owned batches.

`Compare_Many` accepts an enumeration of two to sixteen implementations. Case
one is the reference. The default independently calibrates every case toward an
equal share of the total timed budget, then places every case once in each
position over shuffled cyclic rounds. Set
`Shootout_Scheduling => Sequential_Cases` to finish one implementation's sample
block before beginning the next. Sequential blocks make per-case telemetry
easier to inspect but are more exposed to thermal and time-order drift. The
console reporter prints the chosen schedule and a color-coded `vs` table. Set
`Show_Individual_Details => True` to append the complete latency, tails,
sampling, quality, and clock card for every case:

```ada
type Candidate is (Existing, Rewrite, SIMD, Tasked);

procedure Batch
  (Which : Candidate; Iterations : Flyology_Bench.Iteration_Count);

procedure Compare_All is new Flyology_Bench.Compare_Many
  (Case_Id => Candidate, Batch => Batch);
procedure Put_All is new
  Flyology_Bench.Reporters.Put_Multi_Comparison_Console (Candidate);

Result : Flyology_Bench.Multi_Comparison;

Compare_All (Result => Result);
Put_All (Result, Show_Individual_Details => True);
```

The overall shootout retains process-wide CPU and absolute RSS telemetry.
Detailed cards additionally report CPU time, timed elapsed duration, and RSS
change captured immediately around that implementation's own batches. This
avoids attributing the interleaved process's cumulative RSS to every case.

Inputs and observable outputs must be kept alive. `Do_Not_Optimize` is an
opaque compiler barrier suitable immediately before or after a measurement;
putting it inside a nanosecond operation would measure the out-of-line barrier
call as part of that operation. Volatile state is often clearer for a first
benchmark. `Clobber_Memory` prevents motion of memory operations across a
chosen boundary.

For very small result-producing operations, prefer `Measure_Result_Batched`.
It passes the batch result to the opaque barrier after the ending clock read, so
the optimizer must retain the computation without charging the barrier call to
the measured interval. `Measure_With_Hooks` likewise runs setup before the
starting timestamp and teardown after the ending timestamp.

## Measurement model

The harness characterizes its platform clock, warms the operation, and
calibrates an iteration count toward `Measurement_Time / Samples`. It then
collects equally weighted per-operation batch averages. It retains the nominal
resolution, smallest
observed positive step, adjacent-read costs, median batch duration, and the
clock-resolution floor divided by the iteration count. Timestamp-cost
subtraction is disabled by default; enabling it subtracts one minimum positive
adjacent-read interval from each batch. The harness does not subtract an
invented empty loop because that would not reproduce the generic call, data
dependencies, or optimizer decisions of the workload.

Fractional nanoseconds per operation are amortized throughput estimates: the
harness times a much longer batch and divides by its logical operation count.
They are not evidence that an individual fractional-nanosecond interval was
timestamped. `p95` and `p99` are percentiles of those batch averages, not
individual-operation tail latencies; reporters label them as sample means.

`Maximum_Sampling_Time` is a hard wall-time budget for the collection phase;
zero leaves it unlimited. The harness always completes at least ten samples and
checks the budget between complete samples, paired samples, balanced multi-way
rounds, or sequential case samples, so one in-flight batch can extend slightly
past the boundary. A sequential shootout divides the limit among cases and
retains the common sample count every case completed. Reported sample counts
are the number actually analyzed. For comparisons,
`Measurement_Time` is divided across all timed sides or cases rather than being
silently multiplied by their count.

Outliers remain in every statistic and in the raw samples. The outlier counts
are diagnostics for investigating host noise, input mixtures, or workload
phase changes; they are not permission to discard inconvenient runs.

Wall-clock timing is the default for Flyology waits and cross-task work.
`Flyology_Bench.Baselines` persists raw samples and refuses a regression
comparison when the clock backend or environment fingerprint differs. Its
default fingerprint contains OS, architecture, and GNAT version; callers should
add CPU policy, compiler switches, revision, and other locally relevant state.
Direct paired `Compare` is preferable whenever both implementations can run in
one process.

`Flyology_Bench.Host_Control.Pin_Current_Thread` applies strict Linux CPU
affinity or a Darwin advisory affinity tag. Placement cannot by itself control
frequency scaling, thermal state, interrupts, or competing system load, so
those conditions still belong in the recorded fingerprint and run policy.

Per-operation CPU time, allocation instrumentation, and hardware performance
counters require platform- or allocator-specific providers and are not inferred
from wall time. The crate does not label wall-time results as CPU time or
individual-operation latency.

Terminal mode keeps progress columns stable and reports process CPU as both a
percentage and equivalent occupied cores, current RSS and growth, and elapsed
wall time in `hh:mm:ss`. During a multi-way sampling round, every update names
the implementation in a fixed-width field between the shootout name and phase.
Final human-readable reports use labeled table rows and CPU/RSS sparklines.
Telemetry probes run outside timed regions. They describe the process while the
benchmark runs; they are observability signals, not per-operation measurements.

The maintained example deliberately includes CPU-heavy, memory-retaining,
wait-heavy, and occasionally hiccuping cases so terminal telemetry visibly
moves. Those cases are an observability demonstration, not interchangeable
implementations of one algorithm. Its shootout requests three seconds of data
but caps actual sample collection at two seconds to demonstrate the budget.

For script input, select clean stdout with no progress or ANSI sequences:

```sh
FLYOLOGY_BENCH_OUTPUT=csv examples/bin/basic
FLYOLOGY_BENCH_OUTPUT=json examples/bin/basic
```

CSV emits a header plus one row per contender. JSON emits one newline-delimited
object containing the reference, contenders, environment context, clock data,
and comparison statistics.

## Build and test

From this directory:

```sh
alr build
alr test
```

Or, from an Alire environment with GNAT and GPRbuild available:

```sh
./scripts/test.sh
```

Generated objects, libraries, and executables stay under this crate's `obj`,
`lib`, `tests`, and `examples` build directories and are not versioned.
