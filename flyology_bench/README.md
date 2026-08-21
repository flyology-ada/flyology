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
- deterministic circular-block bootstrap confidence intervals with bounded,
  configurable coverage and resample count;
- Tukey mild and severe outlier diagnostics without silently dropping samples;
- optional measured timestamp-cost subtraction, disabled by default;
- atomically published raw-sample baselines with exact compatibility
  fingerprints and CI regression gates;
- host/toolchain metadata and optional strict Linux or advisory Darwin thread
  placement;
- selectable wall-time, CPU-time, RSS, fault, context-switch, storage-I/O,
  Linux hardware-counter, and Flyology scheduler axes sampled around the same
  retained batches;
- up to eight bounded caller-defined axes and a static adapter for synchronized
  caller-supplied elapsed values, while retaining harness wall time;
- an optional sustained low-host-CPU gate before warmup;
- an optional watch for foreign CPU load arriving after that gate, which can
  annotate, collect a contaminated window again, or pause and re-warm, and
  which never adjusts a reported statistic;
- an optional host CPU claim that coordinates with any other tool following
  the same convention;
- ANSI console result cards, in-place terminal progress, CSV, and
  newline-delimited JSON reporters; and
- explicit optimization and memory barriers.

## Add the crate

Version `0.1.1-dev` is distributed through the Flyology organization index.
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

`Confidence_Level_Percent` defaults to 95.0 and accepts 50.0 through 99.9.
`Bootstrap_Resamples` defaults to 2,000 and accepts 100 through 10,000. Both
are fields of the runner and recording configurations; recorded independent
comparisons and saved-baseline comparisons accept the same bounded settings as
parameters. A wider interval or more resamples increases analysis work but
does not collect additional workload samples. Results retain the settings, and
console, CSV, and JSON reporters identify them alongside each interval.

One public analysis call may draw at most 100,000,000 source samples across
all of its bootstrap intervals. Runner preflight counts every requested axis
because it may be available when collection completes; recorded snapshots and
independent comparisons count the axes and valid samples actually retained.
Saved-baseline comparisons count both distributions. A configuration above
the ceiling raises `Constraint_Error` instead of silently reducing its
resample count, so retained settings and reporter metadata always describe the
calculation that was performed. Runner preflight happens before warmup or timed
work begins. The work-product ceiling also prevents multiplication overflow
when several individually bounded settings are combined.

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

## Custom metrics and alternate timing

`Custom_Metric_Registry` adds at most eight axes without extending the
`Metric_Axis` enumeration or changing existing long-form schemas. Register
every axis and install one bounded snapshot callback before calling a runner:

```ada
Flyology_Bench.Register_Custom_Metric
  (Config.Custom_Metrics,
   Name        => "cache_lookups",
   Unit        => "lookups/op",
   Scope       => Flyology_Bench.Caller_Defined_Window,
   Attribution => Flyology_Bench.Shared_Process_Window,
   Direction   => Flyology_Bench.Lower_Is_Better);
Flyology_Bench.Set_Custom_Probe
  (Config.Custom_Metrics, Probe'Access);
```

Names are stable lowercase ASCII identifiers of at most 48 characters. They
begin with a letter and contain only letters, digits, `.`, `_`, or `-`.
Built-in identities use their lowercase underscore spelling, such as
`wall_time`, for collision checks. Units are at most 24 printable ASCII
characters and exclude comma, quote, and backslash. Registration order is
reporting order; duplicates and built-in collisions raise `Constraint_Error`,
and the ninth axis raises `Capacity_Error`.

The default `Cumulative_Delta` semantics reads a signed cumulative counter at
both boundaries, rejects a decrease as `Counter_Reset`, checks subtraction and
floating conversion, and optionally divides the delta by the exact batch
iteration count. `Absolute_Sample` explicitly retains the ending signed or
zero value. `Completed_Elapsed` requires a finite nonnegative ending value.
NaN, infinity, conversion overflow, a failed callback, and provider-reported
unavailability remain statuses; they never become numeric zero. A partial run
retains every per-sample status, summarizes only collected values, and is not
eligible for a paired comparison. `Relative_Positive` rejects a pair
containing zero or a negative value; choose `Absolute` explicitly for signed
contender-minus-reference comparisons.

Probe order is fixed. Built-in begin snapshots run first, followed by the
custom begin snapshot and harness wall start. After the batch, the harness wall
timestamp runs first, then the custom end snapshot, Linux counter stop/read,
scheduler end snapshot, and process-resource end snapshot. This keeps custom
callback cost outside wall time. It does not make probe families independent:
one family can perturb the machine state observed by a later family, and the
reporter does not “correct” that interaction. Providers must declare scope and
attribution; a returned number does not imply `Exact_Window`. A current-thread
provider must either establish that both callbacks ran on the same native
thread or report the sample unavailable. Registration and result-store
allocation precede collection; the retained-batch path performs no allocation.

`Flyology_Bench.Manual_Timing` is a generic/static adapter for a simulated,
device, accelerator, or other caller-owned source. Its batch returns a
completed elapsed value and status. The caller must synchronize measured work
before returning; queue submission latency must not be described as device
execution. `Scale_To_Unit` performs a checked conversion and the retained
resolution uses the same output unit. The adapter keeps `wall time` as a
separate built-in axis for warmup, equal-wall calibration, sampling budgets,
interference windows, and progress. It never applies wall timestamp-cost
subtraction to the alternate value. `Manual_Timing_Comparison` applies the
same contract to adjacent paired batches. Both use equal harness-wall slices;
there is currently no equal-alternate-time calibration mode. Compact console
output places the declared primary timer first with its source and resolution,
then labels harness wall time as calibration; paired output identifies which
axes-table verdict belongs to the primary timer. Each adapter invocation owns
its mutable bridge state and may run concurrently through the same generic
instance. A configured custom provider remains active and the timer consumes
one free registry slot. Reported resolution is divided by the exact retained
iteration denominator; paired schemas retain separate reference and contender
resolutions when equal-wall calibration selects different counts.

Use the versioned `Put_Extended_Metrics_CSV` and
`Put_Extended_Comparison_Metrics_CSV` schemas, or the corresponding NDJSON
procedures, for built-in and custom axes together. They retain kind, name,
unit, scope, attribution, direction, sample semantics, normalization, timing
role/source/resolution, calibration clock, availability, status, summaries,
comparison method, interval, and verdict. The older CSV procedures remain
unchanged. `examples/custom_metrics.adb` demonstrates a domain counter and a
deterministic simulated timer; it makes no claim about untested GPU support.

Custom providers are not currently integrated with `Recording`. A recording
span can overlap other spans and migrate independently, so reusing one
runner-style begin/end snapshot would not provide coherent per-span ownership,
bounded concurrency, or attribution. The registry and retained per-sample
status model are the integration seam for a future recording-specific design;
until then, record domain observations separately rather than labeling them as
Flyology_Bench recording axes.

## Parameter sweeps, work, and empirical scaling

`Flyology_Bench.Sweeps` runs an explicit ordered set of exact positive
`size:` or `count:` points. A point may also carry a stable display label. The
canonical identity is the parameter kind and full unsigned decimal value; a
duplicate numeric identity is rejected even when its label differs. Labels use
the bounded portable grammar `[A-Za-z0-9][A-Za-z0-9_.-]*`.

The sweep executor is generic over three statically bound operations:
`Select_Point`, `Work_For`, and an already-instantiated `Measure`, `Compare`, or
`Compare_Batched` procedure. Selection and the one call through the sweep layer
occur outside timed batches. The logical operation inside the measurement
generic remains statically bound; there is no access-to-subprogram dispatch per
operation.

Every point states exact integral work per logical operation as items, bytes,
or a bounded caller-named unit. Decimal and binary display scaling affect only
human rendering: raw machine output always retains the exact value, unit, and
scaling choice. Throughput is derived from the same wall-time per-operation
batch means already retained by `Measurement`:

```text
operations/s = 1_000_000_000 / nanoseconds-per-operation
work/s       = operations/s * work-per-operation
```

There is no second timing interval. Median rates invert median wall time. Rate
confidence endpoints invert and reverse the existing mean-time confidence
interval. Zero, negative, fractional, non-finite, unrepresentable, or
incoherently named work amounts are rejected; unavailable wall data and rate
overflow remain explicit unavailable states.

`Measure_Sweep` and `Compare_Sweep` return bounded inspectable results for
every attempted point. The paired executor invokes one existing adjacent,
order-balanced comparison at each point; it never assembles a verdict from
separately collected blocks. Point setup, measurement, wall availability,
throughput overflow, dry-run, and whole-budget exhaustion are distinct
statuses. Stop-on-failure and continue-after-failure are explicit policies.

With `Per_Point_Budget`, `Configuration.Maximum_Sampling_Time` applies
independently to each point under the normal runner rules. With
`Whole_Sweep_Budget`, the same value is an outer elapsed-time limit including
selection, warmup, calibration, and collection. Each point receives the
remaining value as its collection limit; a point already in flight completes,
and later points are marked budget-exhausted. Zero remains unlimited.

Collection and empirical scaling analysis are separate.
`Flyology_Bench.Scaling` accepts stored or deterministic synthetic observations
and fits constant, logarithmic, linear, n log n, quadratic, and cubic models in
log space. It reports every model's coefficient, nominal exponent, R-squared,
RMS and maximum log residual, selection state, and observed input range. At
least four distinct positive points spanning a factor of two are required.
Invalid observations, numeric overflow, poor fit, and poor identifiability
produce explicit unavailable states. A selected model describes only the
observed range; it is empirical scaling, not proof of big-O.

`Flyology_Bench.Sweeps.Reporters` defines new console, CSV, and newline-delimited
JSON schemas rather than changing the existing measurement formats. Rows carry
the suite-compatible full `benchmark` name supplied as `Case_Name`, a separate
canonical `point`, raw parameter and label, work identity/value/scaling, the
`per_operation_batch_mean` sample semantics, availability/status, time,
throughput, direction, and paired verdict. Suite registration and filtering
remain case-level; a sweep is one registered case unless callers explicitly
register its points as separate cases.

The maintained example compares insertion sort and Shell sort over five sizes,
prints elapsed and work-normalized throughput at every adjacent paired point,
and then analyzes each stored result independently:

```sh
alr exec -- gprbuild -p -P examples/flyology_bench_examples.gpr
examples/bin/sweep_comparison
```

Its output is a factual report of that invocation and publishes no host
performance claim.

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

## Configuration rules

`Configuration` carries its own rules rather than checking them on entry to a
run. Fields whose meaning excludes a value use a subtype that excludes it:
`Nonnegative_Duration`, `Positive_Duration`, `Percentage`,
`Threshold_Percentage`, which excludes 100 percent,
`Confidence_Percentage`, and `Bootstrap_Resample_Count`. A literal outside a
bound is a compile-time diagnostic; a computed one raises `Constraint_Error`
at the assignment or aggregate that produced it, naming the offending line.
The bootstrap work-product ceiling is a separate call-level rule because it
combines sample count, resample count, analysis shape, and available or
requested axes.

Each optional policy takes its `Enabled` flag, and `Interference` also its
`Response`, as a discriminant, so a policy's settings exist only while they
apply. Naming `Settle_Time` under `Observe`, or `CPU` on a disabled
`Placement`, does not compile. Setting a policy from a run-time flag therefore
selects between two aggregates:

```ada
Gate : constant Flyology_Bench.CPU_Quiescence_Policy :=
  (if Wait_For_Quiet_CPU
   then (Enabled => True, Stable_Time => 0.500, others => <>)
   else (Enabled => False));
```

The three rules that relate two fields — a quiescence timeout that covers its
stable interval, a poll interval within that timeout, and a pause budget that
covers one settle interval — are record predicates, checked when a policy
value is built or assigned. A policy modified one field at a time is not
checked at that moment, so `Configuration` re-asserts each policy's rule and a
benchmark call rejects an incoherent one on the way in.

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

## Interference during collection

The preflight gate proves the host was quiet before warmup. It says nothing
about what happens next, and a machine that goes busy halfway through a run
produces a result that looks clean. `Interference` watches for that:

```ada
Config.Interference :=
  (Enabled                     => True,
   Response                    => Flyology_Bench.Retake,
   Maximum_Foreign_CPU_Percent => 10.0,
   Window                      => 0.050,
   Maximum_Retakes             => 25);
```

`Response` is a discriminant, so the settings that only a paused run uses
exist only under `Pause` and naming them under any other response is a
compile error:

```ada
Config.Interference :=
  (Enabled                     => True,
   Response                    => Flyology_Bench.Pause,
   Maximum_Foreign_CPU_Percent => 10.0,
   Window                      => 0.050,
   Maximum_Retakes             => 25,
   Settle_Time                 => 0.250,
   Maximum_Pause_Time          => 30.0,
   Rewarm_Time                 => 0.050);
```

Foreign load is host busy time minus this process's own CPU time. That
subtraction matters: the preflight gate can compare raw host utilization
against a limit because the harness is idle at that point, but during
collection the benchmark thread saturates a core, so an unsubtracted limit
would trip on every sample. Load generated inside the benchmark process is
this process's own CPU time and is correctly not foreign.

Three responses form a ladder. `Observe` records what it saw and keeps every
sample. `Retake` discards the contaminated window and collects it again.
`Pause` waits for the host to settle, re-warms, and then collects it again.
The re-warm is not optional politeness: a resumed run has cold caches,
predictors, and frequency state, so without it the first sample after a pause
is the outlier the pause was meant to avoid.

Nothing here adjusts a reported statistic. A skew factor derived from observed
load would be invented data — the cost of interference depends on whether the
contention is an SMT sibling, a shared cache, memory bandwidth, or another
socket entirely, and the same foreign share can mean no slowdown or a large
one. Runs are annotated or repaired, never corrected. For a measurement that
is inherently less sensitive to being descheduled, request `Thread_CPU_Time`
and `Involuntary_Context_Switches` rather than reinterpreting wall time.

Observation happens between timed samples, never inside them, over windows of
whole collection units. A unit is one sample, one comparison pair, or one
balanced multi-way round, so a response never splits the two halves of a pair
or lands mid-round where it would spread interference unevenly across the
cases a round exists to compare fairly. Host CPU counters are tick-based on
both platforms, so a window that does not reach `Window` is recorded but never
acted on: below roughly one tick the estimate is mostly quantization, and
discarding samples over it would be noise dressed as hygiene.

Budgets degrade rather than abort. When retakes or the pause budget run out,
collection continues under `Observe` and the report sets `Budget_Exhausted`.
Paused time is excluded from `Maximum_Sampling_Time`, because waiting for the
host is not collection.

`Environment (Result)` returns everything observed, and the console, CSV, and
JSON reporters all carry it. That visibility is the point: a run that had to
repair itself must say so, or a heavily repaired result reads as a quieter
machine than the one it actually ran on.

## Placement

`Placement` lets the harness pin its own benchmark thread, which also sharpens
interference attribution. With a strict binding the harness knows which
logical CPUs are its own, so every other CPU's busy time is foreign outright,
and the placed CPU's own foreign share is its busy time minus the placed
thread's CPU time. Attribution then reports `Core_Scoped`.

```ada
Config.Placement :=
  (Enabled => True, CPU => 3, Include_Siblings => True, Require_Strict => True);
```

`Include_Siblings` is on by default and should stay on. A process saturating
the SMT sibling of the placed CPU slows the measurement badly while leaving
the placed CPU's own busy share clean, so core-scoped observation that ignores
siblings is worse than host-wide observation: it is confidently wrong. Shared
cache and memory bandwidth remain invisible to any per-core busy metric.

Placement is Linux-only in practice. Linux applies strict affinity through
`pthread_setaffinity_np`. Darwin's affinity API is an advisory tag that groups
threads by cache affinity rather than naming a CPU, and Apple Silicon
implements no thread affinity at all and rejects every request. Anything short
of a strict binding leaves attribution host-wide; `Require_Strict` turns that
degradation into `Placement_Unavailable` instead.

Placement is never neutral. It fixes frequency and thermal behavior and
removes load balancing a deployed workload would get, and it binds only the
calling thread, so a benchmark whose work runs on event loops or a native
executor pool stays partly unplaced. Use it for single-threaded
microbenchmarks, not for scheduler measurements. Because a pinned run and an
unpinned run are not the same environment, placement belongs in the recorded
baseline fingerprint.

That last point is enforced rather than left to the reader. Because only the
calling thread is bound, another thread of the same process is free to occupy
a watched CPU, where its time is indistinguishable from foreign load. Each
window therefore reads process CPU as well as thread CPU; their difference
bounds how much of the watched capacity this process's other threads could
account for. Once that bound exceeds `Maximum_Foreign_CPU_Percent`, the
core-scoped answer can no longer address the question the limit asks, so the
run drops to host-wide observation for the rest of its samples and reports
`Attribution_Diluted`. Without it, a scheduler benchmark with placement
enabled would spend its retake budget discarding samples over load it created
itself.

The fallback direction is deliberate. Core-scoped attribution subtracts only
the placed thread, which over-reports interference when other threads share
the watched CPUs; subtracting the whole process instead would deduct time our
threads spent on CPUs outside the watched set, under-report foreign load, and
let contaminated data pass as clean. Over-reporting is visible in the retake
and contamination counts; under-reporting is not.

## Host CPU claim

`Host_Lock` claims host CPU capacity for the duration of a run, coordinating
with any other tool that follows the same convention:

```ada
Config.Host_Lock :=
  (Enabled               => True,
   Path                  => Ada.Strings.Unbounded.Null_Unbounded_String,
   Timeout               => 30.0,
   Poll_Interval         => 0.250,
   Require_Machine_Scope => False);
```

The claim is taken before the preflight gate, because waiting for a quiet host
first and then blocking on the claim would leave the quiet verdict stale by
the time collection began. A waiting run is idle, so it does not become the
load it is waiting out.

This matters most for `Pause`. Two harnesses that both pause on interference
are symmetric controllers observing each other: each pauses because the other
is loading the machine, both then observe quiet, both resume together, and
both immediately pause again. Serializing them removes the oscillation.

`Flyology_Bench.Host_Lock` also exposes the claim directly, including
disjoint per-CPU claims that let core-scoped runs on non-overlapping CPUs
proceed concurrently while a machine-wide claim excludes them all. The file
naming, protocol, and content grammar are specified in
[`docs/host-cpu-lock.md`](../docs/host-cpu-lock.md) so that other tools can
interoperate; it is a proposal rather than an established standard.

A successful claim is not proof of exclusivity. It coordinates only with
processes that reach the same file, and a privately mounted claim path — which
`systemd PrivateTmp=` produces routinely — silently reduces the claim to one
mount namespace. That case is detected on Linux and reported as
`Lock_Namespace_Scoped`; separate containers are not detectable from inside
and need an explicit shared path. `Require_Machine_Scope` refuses to run
rather than proceeding unserialized, because in CI a silently unserialized run
is worse than a failed one.

The maintained example enables the interference watch only when
`FLYOLOGY_BENCH_INTERFERENCE=1`, mirroring how it gates the preflight.

## Saved baseline gates

`Flyology_Bench.Baselines.Save` records an explicitly named baseline artifact.
The version 2 artifact keeps the exact benchmark identity, environment
fingerprint, clock backend, independent-comparison contract, and every retained
time sample. It has a checksum and commit footer. `Load` rejects missing
fields, duplicate fields and samples, unsupported versions, malformed or
out-of-range values, incomplete samples, trailing data, and checksum failures
with a specific `Baseline_Format_Error` message.

Raw time samples are limited to values the harness can produce: no smaller
than one nanosecond divided by the maximum iteration count and no larger than
one complete unsigned 64-bit clock delta. This bound keeps every independent
mean ratio, confidence endpoint, and time-change conversion finite. A current
measurement outside that domain raises `Baseline_Comparison_Error`; the gate
reports it as `Baseline_Error`, without publishing partial statistics, and
applies the configured fail-open or fail-closed artifact action.

`Load` also retains read compatibility with the earlier version 1 format that
the public `Save` procedure emitted. Its fixed field order, sample count, sample
ranges, and trailing data are validated, but that legacy format has no checksum
or commit footer. Recording is the explicit way to publish a version 2
replacement; checking a version 1 artifact never upgrades it in place.

`Save` writes a unique temporary artifact in the destination directory. It
flushes the complete file before an atomic POSIX `rename` publishes it. A
process failure before publication cannot truncate the earlier baseline. A
filesystem's power-loss guarantee for the containing directory remains a host
property. Record mode is a separate call: `Evaluate_Gate` only reads the
artifact and never updates it, including after a rejected run.

```ada
Flyology_Bench.Baselines.Save
  ("build/integer_mix.baseline",
   "integer_mix",
   Result,
   Fingerprint => Full_Environment_Identity);

Gate := Flyology_Bench.Baselines.Evaluate_Gate
  ("build/integer_mix.baseline",
   "integer_mix",
   Current,
   Fingerprint => Full_Environment_Identity,
   Policy => Flyology_Bench.Baselines.Fail_Closed_Gate_Policy);

Flyology_Bench.Reporters.Put_Gate_JSON (Gate);
if Flyology_Bench.Baselines.Rejected (Gate) then
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end if;
```

The gate uses the existing independent circular-block bootstrap of
arithmetic-mean ratios. A regression rejects only when the complete 95%
confidence interval establishes a slowdown beyond
`Practical_Threshold_Percent`. Improvement, practical equivalence, and
inconclusive results remain distinct. `Permissive_Gate_Policy` reports missing,
invalid, incompatible, and inconclusive results without rejecting.
`Fail_Closed_Gate_Policy` rejects all four conditions. A caller can derive a
policy that fails closed for the artifact and environment but reports an
inconclusive statistical result.

The bounded sum, mean, ratio, percentile interpolation, time-change, and
verdict primitives live in a private SPARK unit. `./scripts/prove.sh` proves
their bounded floating-point run-time checks and the ratio/time-change result
contracts at level 1. File parsing, bootstrap sampling and sorting, and gate
orchestration remain outside SPARK and are covered by the focused behavioral
tests.

Benchmark name, environment fingerprint, and clock backend comparisons are
exact. The gate does not compare samples after any mismatch. The default
fingerprint contains OS, architecture, and GNAT version. Add CPU policy,
compiler switches, revision, and all other locally relevant state. Direct
paired `Compare` remains preferable whenever both implementations can run in
one process because it preserves the collection schedule's pairing.

The maintained example separates recording from checking and maps rejection to
`Ada.Command_Line.Failure`:

```sh
identity='cpu=ci-runner-1;policy=cpu-2;switches=-O3;benchmark=v1'
./examples/bin/baseline_gate record build/integer_mix.baseline "$identity"
./examples/bin/baseline_gate check  build/integer_mix.baseline "$identity"
FLYOLOGY_BENCH_OUTPUT=csv  ./examples/bin/baseline_gate check build/integer_mix.baseline "$identity"
FLYOLOGY_BENCH_OUTPUT=json ./examples/bin/baseline_gate check build/integer_mix.baseline "$identity"
```

The example combines that required caller identity with the default OS,
architecture, and GNAT fingerprint. Use a stable description of the actual CPU
or runner class, placement policy, compiler switches, and benchmark contract;
do not use a changing build number or the contender revision being measured.

The console, CSV, and newline-delimited JSON gate reporters retain the status,
policy decision, compatibility issue, speedup and time-change intervals,
threshold, bootstrap method, confidence level, resample count, seed, and
reason. The machine schema uses confidence-neutral interval field names plus an
explicit confidence level so later statistical-policy configuration does not
mislabel an interval. Aggregation across a suite can use `Rejected` for the
final process status while counting each `Gate_Status` separately. A baseline
gate compares one named reference with one current run. Longer histories,
dashboards, commit-range runners, and change-point detection are separate
facilities.

`Flyology_Bench.Host_Control.Pin_Current_Thread` is the low-level primitive
under `Config.Placement`. Placement cannot by itself control frequency
scaling, thermal state, interrupts, or competing system load, so those
conditions still belong in the recorded fingerprint and run policy.

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

CSV summary and long-form schemas include `confidence_level_percent` and
`bootstrap_resamples`; interval columns use generic `ci_low`/`ci_high` names
because coverage is configurable. `Put_Metrics_CSV` and
`Put_Comparison_Metrics_CSV` emit one row per axis, including availability
status and failure reasons. The multi-way long-form reporter emits those rows
for every contender. JSON measurement, comparison, multi-way, and recording
objects include a `statistics` object alongside their metric, environment,
clock, and latency data.

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
