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
- selectable wall-time, CPU-time, RSS, fault, context-switch, storage-I/O,
  Linux hardware-counter, and Flyology scheduler axes sampled around the same
  retained batches;
- an optional sustained low-host-CPU gate before warmup;
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

## Record externally driven work

`Flyology_Bench.Recording` inverts control when the application, rather than
the benchmark runner, decides when work happens. Register stable identities
before starting, then mark boundaries inside a request handler, consumer, or
long-lived worker:

```ada
with Flyology_Bench.Recording;

package Recording renames Flyology_Bench.Recording;

Recorder : Recording.Recorder
  (Maximum_Benchmarks => 8,
   Retained_Samples   => 10_000);
Request : Recording.Benchmark;

Recording.Register (Recorder, "request", Request);
Recording.Start (Recorder);

declare
   Sample : Recording.Span;
begin
   Recording.Begin_Sample (Recorder, Request, Sample);
   begin
      Handle_Request;
   exception
      when others =>
         Recording.Finish (Sample, Recording.Failure);
         raise;
   end;
   Recording.Finish (Sample, Recording.Success);
end;
```

Registration and bounded-store allocation happen before `Start`. The boundary
path performs no Ada heap allocation. `Finish` reads the ending timestamp
before entering the protected sample store, so retention and analysis are not
part of the recorded wall-time value. The recorder counts success, failure,
timeout, cancellation, unfinished spans, observations, retained samples, and
samples omitted by its bounded retention policy. `Reservoir` is the default
for a long run; `First_N` and `Latest_N` are also available.

Each retained row keeps its original observation number and outcome together
with the status and optional value of every requested axis. Raw CSV and the
JSON `samples` array therefore preserve the relationship between latency, CPU,
memory, and outcome even when a migration or failed probe makes one axis
unavailable. Summary statistics cover every retained outcome. Filter the
aligned raw rows when success-only or outcome-specific statistics are needed.
An axis with both valid and invalid rows reports `partially_collected`, its
valid and unavailable counts separately, and is not used for an independent
comparison until both sides are complete.

The live terminal is a continuously refreshed display rather than a log:

```ada
Recording.Start_Live_Terminal
  (Recorder, Refresh_Interval => 0.100);

--  Externally controlled work runs here.

Recording.Stop (Recorder);
Recording.Stop_Live_Terminal (Recorder);
```

Its fixed rows report session elapsed time, current process CPU as percentage
and occupied cores, RSS, completed and active spans, errors, and rolling median
and p95 latency for every registered identity. The maintained
`recording_service` example uses several client tasks to drive a long-lived Ada
rendezvous service. Instrumentation lives inside four service workers and
therefore demonstrates overlapping CPU-heavy, memory-burst, wait-bound, fast,
occasionally slow, and occasionally failed spans without an HTTP dependency:

```sh
alr exec -- gprbuild -p -P examples/flyology_bench_examples.gpr
examples/bin/recording_service

FLYOLOGY_BENCH_RECORDING_OUTPUT=csv examples/bin/recording_service
FLYOLOGY_BENCH_RECORDING_OUTPUT=json examples/bin/recording_service
```

Recorded percentiles describe individual spans, unlike the runner's
per-operation batch means. `Compare_Independent` compares separately observed
recorded distributions with independent resampling; it does not reuse the
runner's paired bootstrap. CSV and JSON mark these contracts as
`sample_semantics=individual_span` and `comparison_design=independent`.
Comparison output retains requested-but-unavailable axes and both input
statuses. If wall time was not requested or was incomplete, JSON emits `null`
for wall-derived speedup and relative change and the console reports that the
wall comparison is unavailable.

Metric availability and attribution are separate. Wall time has an exact span
boundary. Thread CPU is accepted only when both boundaries execute on the same
native thread. Process CPU, RSS, faults, switches, and I/O include concurrent
process activity. Flyology scheduler counters cover their supplied runtime
scope. On Linux, each recorder session owns PMU groups that remain enabled per
native worker, and each span scales the difference between its two cumulative
value/enabled/running snapshots; they include inherited native children and
remain task-tree scoped. Concurrent recorders use separate sessions. Worker
exit closes that worker's groups, so later pthread reuse cannot inherit stale
descriptors. A migrated span excludes thread and PMU values rather than
silently attaching them to the destination thread.

Use `Flyology_Bench.Recording.Reporters` for the terminal summary, long-form
summary CSV, raw retained-sample CSV, newline-delimited JSON, and independent
comparison formats.

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

## Resource and runtime axes

Wall time remains the calibration and collection-budget clock. `Metrics`
selects which additional values are retained around those same timed batches:

```ada
use type Flyology_Bench.Metric_Set;

Config.Metrics :=
  Flyology_Bench.Process_Resource_Metrics
  or Flyology_Bench.Linux_Hardware_Metrics;
```

`Terminal_Mode` adds `Process_Resource_Metrics` to the caller's selection. It
includes process and current-thread CPU time, current process RSS and its
across-batch change, minor and major faults, voluntary and involuntary context
switches, actual storage bytes, and filesystem block-I/O operations. The
process values include all native threads in the benchmark process. There is no
OS-level per-thread RSS value, so RSS is process-scoped and its absolute value
is diagnostic rather than a directional comparison.

On Linux, `Linux_Hardware_Metrics` requests user-space CPU cycles, retired
instructions, instructions per cycle, cache misses, branches, and branch
misses through `perf_event_open`. Cycles and instructions form one event group,
so IPC uses counters enabled, scheduled, and disabled over the same window.
Events inherit into native tasks or processes created by the executing pthread
after counter initialization. This covers the maintained example's per-batch
parallel workers; it does not attach to threads that already existed when the
run began. Kernel and hypervisor execution are excluded.

Each sample is the difference between a counter read taken while the group is
disabled and one taken after it is disabled again. The group enable between
those reads gives cycles and instructions one common start, and the
multiplexing correction uses enabled and running time deltas from the same
pair of reads.
`PERF_EVENT_IOC_RESET` is deliberately not used: it clears an event's own
count but not the inherited count accumulated from exited child tasks, so a
reset-and-read-absolute scheme would report totals that grow from sample to
sample once workers contribute.

An unavailable axis retains a `Metric_Status`: unsupported platform,
permission denial, unsupported event, unavailable counter resources, or probe
failure. `perf_event_open` reports `EINVAL` both for a generic event the host
cannot map and for an attribute combination the kernel rejects, so that case
is re-probed with only the permission-relevant attributes before being
classified. Console, long-form CSV, and JSON reporters preserve the same
reason; the harness never substitutes zero. A lightweight task gets meaningful
attribution only while it remains on the same event-loop pthread and does not
suspend so unrelated fibers execute inside the sample. Use a thread pin or
dedicated execution group when that boundary is part of the benchmark design.

The standalone crate does not depend on Flyology. Scheduler axes therefore use
an optional callback that returns cumulative counters. The callback runs before
and after each sample, outside its timestamps:

```ada
with Flyology.Observability;

procedure Probe
  (Result : out Flyology_Bench.Flyology_Scheduler_Snapshot)
is
   Group : Flyology.Observability.Group_Snapshot;
begin
   if Flyology.Observability.Snapshot (0, Group) then
      Result :=
        (Available      => True,
         Dispatches     => Group.Dispatches,
         Poll_Batches   => Group.Poll_Batches,
         Poll_Events    => Group.Poll_Events,
         Wakeups        => Group.Wakeups,
         Migrations_In  => Group.Migrations_In,
         Migrations_Out => Group.Migrations_Out);
   else
      Result := (others => <>);
   end if;
end Probe;

Config.Metrics := Config.Metrics or Flyology_Bench.Flyology_Scheduler_Metrics;
Config.Scheduler_Probe := Probe'Access;
```

Define `Probe` at library level to satisfy the callback type's lifetime. A
caller may sum several group snapshots; in that case inbound plus outbound
migration values count group-boundary crossings, so one migration between two
included groups contributes twice.

Every delta is divided by the logical operation count, except absolute RSS and
the dimensionless IPC value. A paired comparison uses relative ratios only
when every value on both sides is positive. Zero-containing and signed axes use
paired absolute differences. Diagnostic axes retain confidence intervals but
do not claim that either implementation is generally better.

Counter control and snapshot calls are outside the wall-clock timestamps, and
setup/teardown hooks are outside every selected axis. Enabling several probe
families can still perturb another family at the boundary: for example,
stopping Linux perf events takes system calls before the ending process-CPU
snapshot. Adaptive batches amortize that fixed cost, but they do not make it
zero. When a small resource difference matters, repeat the comparison with
only that metric family selected and check that the conclusion remains.

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

## CPU quiescence preflight

An opt-in preflight can wait for sustained low host CPU utilization before
clock characterization and workload warmup:

```ada
Config.CPU_Quiescence :=
  (Enabled                     => True,
   Maximum_Average_CPU_Percent => 20.0,
   Maximum_Core_CPU_Percent    => 50.0,
   Stable_Time                 => 1.0,
   Poll_Interval               => 0.100,
   Timeout                     => 15.0);
```

Both limits must hold continuously for `Stable_Time`. The average limit catches
broad machine load; the per-core limit prevents one saturated logical CPU from
being hidden by many idle CPUs. Linux reads cumulative counters from
`/proc/stat`; Darwin uses `host_processor_info`. The gate runs once per
top-level measurement or comparison and reports
`Waiting_For_CPU_Quiescence` through the normal progress callback. If the
stable interval is not observed before `Timeout`, the run raises
`CPU_Quiescence_Timeout` instead of silently collecting under known CPU load.

This is a CPU preflight, not a general proof of host quiescence. It does not
detect storage traffic, thermal state, frequency changes, or later competing
work. Process telemetry during collection remains relevant. The maintained
example enables this gate only when `FLYOLOGY_BENCH_QUIESCENCE=1`, so ordinary
example and CI runs do not acquire a new wait or failure condition.

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

Allocation counts still require allocator instrumentation and are not inferred
from RSS. CPU time, Linux hardware counters, and the resource axes above are
separate samples with explicit scopes; the crate does not relabel wall time as
one of them or as individual-operation latency.

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
Pass `--metrics=perf` to keep only wall time and Linux hardware counters. Add
`--require-perf` in validation runs to fail after the first measurement unless
every selected hardware axis produced samples; the failure names every missing
axis with its status. `--require-perf=core` is the documented narrower policy
for a host whose PMU implements cycles and instructions but rejects a generic
cache or branch event; it still requires cycles, instructions, and IPC:

```sh
./examples/bin/basic --metrics=perf
./examples/bin/basic --metrics=perf --require-perf
./examples/bin/basic --metrics=perf --require-perf=core
```

For script input, select clean stdout with no progress or ANSI sequences:

```sh
FLYOLOGY_BENCH_OUTPUT=csv examples/bin/basic
FLYOLOGY_BENCH_OUTPUT=json examples/bin/basic
```

The original CSV reporters retain their stable latency schemas. The long-form
`Put_Metrics_CSV` and `Put_Comparison_Metrics_CSV` reporters emit one row per
axis, including availability status and failure reasons. The multi-way
long-form reporter emits
those rows for every contender. JSON measurement, comparison, and multi-way
objects include metric arrays alongside environment, clock, and latency data.

## Build and test

From this directory:

```sh
alr build
alr test
```

`alr test` also checks the published machine-readable schemas: every CSV row
carries exactly the columns its header declares, the long-form metric rows
agree between `available` and `status`, and each JSON object parses. The
parse uses `jq` when it is installed and falls back to structural checks
otherwise, reporting which path ran.

From the repository root, an opt-in Linux container run grants the narrow
Docker performance-monitoring capability and requires actual PMU samples:

```sh
FLYOLOGY_LINUX_PERF=1 ./scripts/test-linux-docker.sh
```

That mode also sets `FLYOLOGY_BENCH_REQUIRE_PERF=1`, which makes the smoke
test require the hardware axes and compare a serial batch against one that
starts four worker tasks. Because each worker repeats the serial batch's work,
an inherited counter reports several times as many cycles per logical
operation; counting only the calling pthread leaves the two comparable and
fails the check.

The capability cannot compensate for a Linux virtual machine that does not
expose a hardware PMU. A guest kernel without one lists no CPU entry under
`/sys/bus/event_source/devices`, every `PERF_TYPE_HARDWARE` open fails, and
the required run exits with the specific unavailable status rather than
reporting a pass.

Or, from an Alire environment with GNAT and GPRbuild available:

```sh
./scripts/test.sh
```

Generated objects, libraries, and executables stay under this crate's `obj`,
`lib`, `tests`, and `examples` build directories and are not versioned.
