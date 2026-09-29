# flyology_debug

`flyology_debug` is an independent Ada library for bounded in-memory tracing.
It does not depend on the Flyology runtime and performs no rendering, file
access, terminal output, or other I/O.

`Flyology_Debug.Tracers` provides:

- application-defined, definite message types;
- monotonic producer timestamps represented in integer nanoseconds;
- an injectable timestamp function with the native clock as its default;
- protected-store admission sequence numbers independent of timestamp order;
- fixed-capacity retention-ordered trace history;
- optional producer shards with injected automatic selection and explicit
  override;
- zero-copy `Take` and `Take_Merged`, borrowed `Visit` and `Visit_Merged`,
  explicit `Release`, and `Clear`;
- configurable `Overwrite_Oldest`, `Drop_Newest`, and `Block_Producer`
  full-history policies;
- reversible `Enable` and `Disable` producer control;
- terminal `Close`, which wakes blocked producers;
- `Try_Trace` for callers that cannot wait in blocking mode; and
- saturating overwrite and drop counts returned with each detached batch.

`Flyology_Debug.Gauges` separately provides persistent latest-value storage for
an application-defined enumeration of gauge keys. Each key has independent
synchronization, and `Read` samples without clearing values.

The ring index, admission, append, clear, sequence, and saturating-counter
transitions are isolated in a SPARK policy kernel used by the tracer
implementation and checked by the repository's `./scripts/prove.sh` campaign.
Arbitrary payload copying, protected-object exclusion, finalization, borrowed
visitation, and clock behavior remain outside that pure kernel and are covered
by compiler checks and behavioral tests.

Timestamps use the same platform clocks as `flyology_bench`:
`mach_absolute_time` on Darwin and `clock_gettime(CLOCK_MONOTONIC_RAW)` on
Linux. Values are converted to unsigned nanoseconds from a monotonic origin.
They provide nanosecond units and ordering; actual clock resolution remains a
property of the host platform. Both tracing and gauge generics accept an
application-defined `Now` function when another monotonic, simulated, or
deterministic clock is required. A custom function must be task safe because
producers call it outside the protected store and may call it concurrently.
Its exceptions propagate without admitting the associated message or gauge.

The crate itself never interprets a message or gauge. A timer task can take a
trace batch, sample gauges, and pass both to application-specific formatting,
persistence, telemetry, or test assertions.

## Add the crate

Version `0.1.1-dev` is distributed through the Flyology organization index.
Keep the community index enabled for the compiler, add the development index
ahead of it, and add the crate normally:

```sh
alr index --reset-community
alr index --add=git+https://github.com/flyology-ada/alire-index.git \
  --name=flyology --before=community
alr with flyology_debug
```

## Example

```ada
with Flyology_Debug.Gauges;
with Flyology_Debug.Tracers;

procedure Example is
   type Event is (Request_Accepted, Request_Completed);
   type Message is record
      Kind       : Event;
      Request_Id : Positive;
   end record;
   type Gauge is (Active_Requests, Queue_Depth);

   package Debug is new Flyology_Debug.Tracers
     (Message_Type   => Message,
      Capacity       => 4_096,
      Producer_Count => 2);

   package Metrics is new Flyology_Debug.Gauges
     (Gauge_Kind => Gauge, Gauge_Value_Type => Natural);

   Trace_Result : Debug.Merged_Batch;
   Gauge_Result : Metrics.Snapshot;

   procedure Observe
     (Producer    : Debug.Producer_Id;
      Sequence    : Debug.Sequence_Number;
      Captured_At : Flyology_Debug.Timestamp;
      Payload     : not null access constant Message)
   is
      pragma Unreferenced (Producer, Sequence, Captured_At, Payload);
   begin
      null;
   end Observe;
begin
   Debug.Trace ((Request_Accepted, 42), Producer => 1);
   Debug.Trace ((Request_Completed, 42), Producer => 2);
   Metrics.Set (Active_Requests, 1);
   Debug.Take_Merged (Trace_Result);
   Metrics.Read (Gauge_Result);
   Debug.Visit_Merged (Trace_Result, Observe'Access);
   Debug.Release (Trace_Result);
end Example;
```

`Trace` captures the timestamp before it enters the selected producer's
protected history. Message copy cost is therefore still producer cost, but the
call performs no allocation or I/O in this crate. `Take` swaps that producer's
two preallocated buffers in constant protected time and gives the calling
consumer a limited handle to the detached buffer. There is no capacity-wide
collection copy and no third trace array per producer. That producer immediately
uses its other buffer. Concurrent `Take` calls for the same producer serialize
until the prior consumer calls `Release` or its batch is finalized; different
producers can be taken independently. A consumer must release its current batch
before requesting another from the same tracer instance. The crate creates no
internal task.
`Visit` passes borrowed access to messages in that detached buffer, avoiding the
per-record copies made by the convenience `Trace_At` and `Message_Of` functions.
A callback must not retain the message access or release the batch.

`Producer_Count` defaults to one. Increasing it creates that many independent
producer shards inside the package instance. `Capacity` applies separately to
each producer, so total trace-array storage is `2 * Producer_Count * Capacity`
records. `Select_Producer` chooses a shard for `Trace` and `Try_Trace` calls
that omit one; its default selects producer one. An injected selector must be
task safe, nonblocking, and return `1 .. Producer_Count`. Explicit producer
arguments bypass it. Producers using different ids do not acquire the same
protected object. Sharing an id remains task safe and retains serialization.

The consumer may drain one producer with `Take`, or call `Take_Merged` to own
one detached buffer from every producer. `Take_Merged` first reserves every
producer in one protected operation, waiting without retaining a partial set,
and then swaps producers one at a time. It is therefore not a simultaneous
cross-producer snapshot. Each individual swap is constant-time and the producer
immediately continues in its spare buffer. A consumer must not call `Take` or
`Take_Merged` while retaining another batch from the same tracer instance.
`Visit_Merged` performs an allocation-free k-way heap merge without
copying messages. It preserves each producer's admission order, choosing the
earliest timestamp among current producer heads and breaking equal timestamps
by producer id. This intentionally does not reorder records within a shard when
concurrent timestamp capture and protected admission occurred in a different
order.

When both crates are present, a Flyology application can use its task-aware
selector without adding a dependency from `flyology_debug` back to Flyology:

```ada
with Flyology.Debug_Producer_Selection;

package Debug is new Flyology_Debug.Tracers
  (Message_Type    => Message,
   Capacity        => 4_096,
   Producer_Count  => 4,
   Select_Producer => Flyology.Debug_Producer_Selection.Choose);
```

Lightweight tasks map by current execution group, which represents actual
parallelism better than lightweight task identity. If a task migrates, later
traces may use the new group's shard. Native tasks map by a stable hash of
their pthread identity. A selector call with one configured producer returns
immediately without querying either identity.

Concurrent tasks sharing one producer id may enter protected history in a
different order from their captured timestamps. Each accepted record therefore
also receives a producer-local sequence number inside that protected store.
Sequence numbers establish admission order within one producer; timestamps
permit a consumer to merge records from several producers when a global view is
needed.

`Disable` reversibly ignores producer operations and wakes blocked producers.
`Is_Enabled` is an atomic query that callers can check before constructing an
expensive message. `Enable` resumes admission unless the tracer has been
terminally closed. `Trace` itself reads the same atomic enabled, disabled, or
closed state, so its disabled path does not enter the protected store.

Overwrite and drop producers use their selected producer's protected procedure.
Only `Block_Producer` uses a protected entry and its waiting semantics.
Blocking `Try_Trace` also checks a per-producer atomic capacity hint before
reading the clock; a race with another task sharing that producer can still
cause a clock read followed by a decline, but an already-full history does not.

## Full-history policies

`Overwrite_Oldest` is the default. Once `Capacity` messages are retained for
one producer, each new message for that producer replaces its oldest one.
`Overwrites` makes this loss visible in a batch and resets when that buffer is
detached or cleared. This mode gives tracing a fixed memory bound without making
producers wait for a consumer.

`Drop_Newest` preserves the records already retained when history is full and
declines each new message until capacity is released. `Trace` silently counts
the loss; `Try_Trace` also reports `Accepted => False`. The detached batch
reports dropped and overwritten messages separately.

`Block_Producer` preserves accepted messages. A full history blocks `Trace`
until `Take` or `Clear` releases capacity. `Disable` wakes the producer and
ignores its pending message; `Close` wakes it and raises `Closed_Error`.
`Try_Trace` reports `Accepted => False` instead of waiting when a blocking
tracer is full, disabled, or closed.

Call `Close` before waiting for producers to finish. Closure is terminal and
idempotent: it wakes every blocked `Trace`, which raises `Closed_Error`, and
rejects later `Trace` calls the same way. Retained state remains available to
`Take` or `Clear`; `Try_Trace` simply declines after closure. This gives
blocking mode an explicit shutdown path without making the consumer responsible
for draining quickly enough during shutdown.

## Gauges

Gauges are persistent current state rather than an ordered event stream. Each
`Gauge_Kind` value owns one fixed slot whose timestamp and value are replaced by
the latest `Set`. `Read` does not clear those slots; only an explicit `Clear`
does.

Each gauge key has its own protected slot. `Set` therefore contends only with a
`Read` or `Clear` copying the same key, rather than with the complete gauge set
or trace history. A snapshot is coherent for every individual key, but a
concurrent update may appear independently for each key, so it is not one
atomic instant across the entire enumeration.

## Test

```sh
alr test
```

The smoke test checks typed message retention, injected timestamps, admission
sequences, persistent gauge replacement, wrap/drop statistics, borrowed batch
visitation, enable/disable behavior, batch ownership, explicit release/clear
semantics, abort-safe finalization, nonblocking decline, concurrent consumers,
producer release in blocking mode, atomic merged reservations, interrupted
merged-waiter cleanup, and closure of queued producers.

## Producer-cost benchmark

The optional benchmark reports aggregate nanoseconds per `Trace` for disabled,
injected-clock, injected constant-selector, native-clock, four producers
sharing one shard, and four producers using independent shards:

```sh
./scripts/benchmark.sh
```

Results are host- and toolchain-specific and are not a correctness gate. Compare
the shared and sharded concurrent results to decide whether the additional
fixed storage is justified for an application.
