--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Finalization;
with Interfaces;

--  Records benchmark boundaries supplied by an application instead of
--  invoking the measured operation itself. Recording is intended for servers,
--  load tests, and other externally controlled workloads.
package Flyology_Bench.Recording is
   --  Maximum supported registered identities in one recording session.
   subtype Benchmark_Capacity is Positive range 1 .. 256;
   --  Maximum retained observations for each registered identity.
   subtype Retained_Capacity is Positive range 10 .. 100_000;

   --  Result attached to one completed span.
   --  @enum Success The operation completed normally.
   --  @enum Failure The operation raised or returned an error.
   --  @enum Timeout The operation exceeded an application deadline.
   --  @enum Cancelled The caller cancelled the operation.
   type Sample_Outcome is (Success, Failure, Timeout, Cancelled);

   --  Policy used after a benchmark has observed more samples than it can
   --  retain. Aggregate counters always cover every finished span.
   --  @enum Reservoir Keep a bounded pseudorandom sample of the complete run.
   --  @enum First_N Keep the first Retained_Samples observations.
   --  @enum Latest_N Keep the most recent Retained_Samples observations.
   type Retention_Policy is (Reservoir, First_N, Latest_N);

   --  Recording-session policy. Registration and allocation happen before
   --  Start; Begin_Sample and Finish perform no Ada heap allocation.
   --  @field Metrics Axes captured around each application-supplied span.
   --  @field Scheduler_Probe Optional cumulative Flyology scheduler source.
   --  @field Retention Bounded sample retention policy.
   --  @field Random_Seed Seed used by reservoir selection and bootstrapping.
   --  @field Practical_Threshold_Percent Smallest relative change used for an
   --  independent-comparison verdict.
   type Configuration is record
      Metrics              : Metric_Set := Process_Resource_Metrics;
      Scheduler_Probe      : Flyology_Scheduler_Probe := null;
      Retention            : Retention_Policy := Reservoir;
      Random_Seed          : Long_Long_Integer := 1;
      Practical_Threshold_Percent : Long_Float := 1.0;
   end record;

   --  Default policy for externally recorded spans.
   Default_Configuration : constant Configuration := (others => <>);

   --  Owns registrations, bounded stores, and session-wide telemetry. The
   --  recorder must outlive every Benchmark and Span obtained from it.
   --  @field Maximum_Benchmarks Maximum number of identities registered
   --  before Start.
   --  @field Retained_Samples Bounded raw sample capacity for each identity.
   type Recorder
     (Maximum_Benchmarks : Benchmark_Capacity;
      Retained_Samples   : Retained_Capacity) is limited private;

   --  Stable, opaque identity registered before a session starts. It avoids
   --  string lookup and allocation in request paths.
   type Benchmark is private;

   --  One active measurement boundary. A span can be finished exactly once.
   --  Finalizing an unfinished span increments the abandoned count and never
   --  records a successful sample.
   type Span is limited private;

   --  Deep snapshot of retained individual-span data.
   type Recorded_Measurement is private;

   --  Independent-sample comparison of two recorded measurements.
   type Recorded_Comparison is private;

   --  Raised when a one-shot session or its dashboard is started twice.
   Recording_Already_Started : exception;
   --  Raised when Begin_Sample is called outside a running session.
   Recording_Not_Started     : exception;
   --  Raised when registration is attempted after Start.
   Registration_Closed       : exception;
   --  Raised when registration exceeds Maximum_Benchmarks.
   Too_Many_Benchmarks       : exception;
   --  Raised when a handle does not belong to the supplied recorder.
   Invalid_Benchmark         : exception;
   --  Raised when Begin_Sample receives an already active span.
   Span_Already_Active       : exception;
   --  Raised when Finish receives a span that is not active.
   Span_Already_Finished     : exception;

   --  Register a bounded-cardinality benchmark name. Registration may
   --  allocate and is prohibited while the session is running.
   --  @param Object Recorder that owns the identity.
   --  @param Name Stable human-readable identity, truncated to 96 characters.
   --  @param Item Returned hot-path handle.
   --  @exception Registration_Closed Registration is already frozen.
   --  @exception Too_Many_Benchmarks Capacity has been reached.
   procedure Register
     (Object : in out Recorder;
      Name   : String;
      Item   : out Benchmark);

   --  Freeze registration and begin accepting spans.
   --  @param Object Recorder to start.
   --  @param Config Frozen recording and metric policy.
   --  @exception Recording_Already_Started The one-shot session already ran.
   --  @exception Invalid_Benchmark No benchmark identity was registered.
   procedure Start
     (Object : in out Recorder;
      Config : Configuration := Default_Configuration);

   --  Stop accepting new spans. Already active spans may still finish; their
   --  count remains visible until they do.
   --  @param Object Recorder to stop.
   procedure Stop (Object : in out Recorder);

   --  Start a span. The benchmark must belong to a running recorder.
   --  @param Object Running recorder.
   --  @param Item Registered identity owned by Object.
   --  @param Value Reusable inactive span receiving starting snapshots.
   --  @exception Invalid_Benchmark Item does not belong to Object.
   --  @exception Recording_Not_Started Object is not running.
   --  @exception Span_Already_Active Value already marks an active span.
   procedure Begin_Sample
     (Object : in out Recorder;
      Item   : Benchmark;
      Value  : in out Span);

   --  Finish a span and retain or aggregate its measurements. End probes run
   --  before bounded-store synchronization, keeping recorder storage work out
   --  of the observed wall-time interval.
   --  @param Value Active span to finish.
   --  @param Outcome Application result counted for this span.
   --  @exception Span_Already_Finished Value is not active.
   procedure Finish
     (Value   : in out Span;
      Outcome : Sample_Outcome := Success);

   --  Return a stable name for a registered benchmark.
   --  @param Item Registered identity.
   --  @return Human-readable registered name.
   function Name (Item : Benchmark) return String;

   --  Copy the currently retained data for one benchmark. Snapshot can be
   --  called while recording; its values form one coherent store snapshot.
   --  @param Object Recorder that owns Item.
   --  @param Item Registered identity to copy.
   --  @param Result Deep result snapshot.
   --  @exception Invalid_Benchmark Item does not belong to Object.
   procedure Snapshot
     (Object : Recorder;
      Item   : Benchmark;
      Result : out Recorded_Measurement);

   --  Start an ANSI dashboard on standard output. The display refreshes in
   --  place until Stop_Live_Terminal is called; it is not an event log.
   --  @param Object Recorder to observe.
   --  @param Refresh_Interval Delay between complete redraws.
   --  @param ANSI Whether to emit color and cursor-control sequences.
   --  @exception Recording_Already_Started A dashboard is already active.
   procedure Start_Live_Terminal
     (Object           : in out Recorder;
      Refresh_Interval : Duration := 0.250;
      ANSI             : Boolean := True);

   --  Stop the dashboard, wait for its task, and leave the cursor below the
   --  final display.
   --  @param Object Recorder whose dashboard should stop.
   procedure Stop_Live_Terminal (Object : in out Recorder);

   --  Number of registered benchmarks.
   --  @param Object Recorder to inspect.
   --  @return Registered identity count.
   function Benchmarks (Object : Recorder) return Natural;
   --  Total completed spans observed for one benchmark, including samples not
   --  retained by the selected bounded policy.
   --  @param Result Recorded snapshot.
   --  @return Completed observation count.
   function Observed (Result : Recorded_Measurement) return Natural;
   --  Number of retained individual spans.
   --  @param Result Recorded snapshot.
   --  @return Retained raw observation count.
   function Retained (Result : Recorded_Measurement) return Natural;
   --  Number of observations omitted from retained raw storage.
   --  @param Result Recorded snapshot.
   --  @return Observed minus retained count.
   function Dropped (Result : Recorded_Measurement) return Natural;
   --  Number of spans still active when the snapshot was captured.
   --  @param Result Recorded snapshot.
   --  @return Active span count.
   function In_Flight (Result : Recorded_Measurement) return Natural;
   --  Number of spans finalized without Finish.
   --  @param Result Recorded snapshot.
   --  @return Abandoned span count.
   function Abandoned (Result : Recorded_Measurement) return Natural;
   --  Number of finished spans for one outcome.
   --  @param Result Recorded snapshot.
   --  @param Outcome Outcome to count.
   --  @return Completed spans with Outcome.
   function Outcomes
     (Result  : Recorded_Measurement;
      Outcome : Sample_Outcome) return Natural;
   --  Elapsed wall time covered by the recording session snapshot.
   --  @param Result Recorded snapshot.
   --  @return Session wall time through Stop or Snapshot.
   function Session_Elapsed (Result : Recorded_Measurement) return Duration;
   --  Return the recorded identity.
   --  @param Result Recorded snapshot.
   --  @return Human-readable registered name.
   function Name (Result : Recorded_Measurement) return String;

   --  Return one axis summary over its valid individual-span samples.
   --  @param Result Recorded snapshot.
   --  @param Axis Requested metric axis.
   --  @return Summary over valid retained samples.
   function Metric_Statistics
     (Result : Recorded_Measurement;
      Axis   : Metric_Axis) return Metric_Summary;
   --  Return collection status for an axis. Metric_Collected means every
   --  retained span has a value; Metric_Partially_Collected means only a
   --  subset does.
   --  @param Result Recorded snapshot.
   --  @param Axis Metric axis.
   --  @return Collected, unavailable, or not-requested status.
   function Metric_Status
     (Result : Recorded_Measurement;
      Axis   : Metric_Axis) return Metric_Availability;
   --  Return attribution quality for an axis.
   --  @param Result Recorded snapshot.
   --  @param Axis Metric axis.
   --  @return Boundary and ownership quality for Axis.
   function Attribution
     (Result : Recorded_Measurement;
      Axis   : Metric_Axis) return Metric_Attribution;
   --  Return valid retained value count for an axis.
   --  @param Result Recorded snapshot.
   --  @param Axis Metric axis.
   --  @return Valid retained values for Axis.
   function Metric_Samples
     (Result : Recorded_Measurement;
      Axis   : Metric_Axis) return Natural;
   --  Return samples excluded because their native execution scope changed.
   --  @param Result Recorded snapshot.
   --  @param Axis Thread-scoped metric axis.
   --  @return Excluded scope-changing sample count.
   function Scope_Changed_Samples
     (Result : Recorded_Measurement;
      Axis   : Metric_Axis) return Natural;
   --  Return retained samples without a valid value for an axis, including
   --  scope changes and probe failures.
   --  @param Result Recorded snapshot.
   --  @param Axis Metric axis.
   --  @return Retained samples lacking Axis.
   function Unavailable_Metric_Samples
     (Result : Recorded_Measurement;
      Axis   : Metric_Axis) return Natural;
   --  Return one retained metric value in Metric_Unit units.
   --  @param Result Recorded snapshot.
   --  @param Axis Requested metric axis.
   --  @param Index One-based valid sample index for Axis.
   --  @return Retained sample value.
   --  @exception Constraint_Error Axis is unavailable or Index is out of range.
   function Metric_Sample
     (Result : Recorded_Measurement;
      Axis   : Metric_Axis;
      Index  : Positive) return Long_Float;

   --  Return the monotonic observation number of one retained span. Reservoir
   --  storage does not imply observation order; use this value as its identity.
   --  @param Result Recorded snapshot.
   --  @param Index One-based retained row index.
   --  @return Observation number assigned when the span finished.
   --  @exception Constraint_Error Index is out of range.
   function Observation_Id
     (Result : Recorded_Measurement;
      Index  : Positive) return Natural;
   --  Return the application outcome attached to one retained span.
   --  @param Result Recorded snapshot.
   --  @param Index One-based retained row index.
   --  @return Recorded outcome.
   --  @exception Constraint_Error Index is out of range.
   function Outcome_At
     (Result : Recorded_Measurement;
      Index  : Positive) return Sample_Outcome;
   --  Return collection status for one axis of one retained span.
   --  @param Result Recorded snapshot.
   --  @param Index One-based retained row index.
   --  @param Axis Metric axis.
   --  @return Per-span collection status.
   --  @exception Constraint_Error Index is out of range.
   function Sample_Metric_Status
     (Result : Recorded_Measurement;
      Index  : Positive;
      Axis   : Metric_Axis) return Metric_Availability;
   --  Return one axis value from one retained span without losing cross-axis
   --  alignment.
   --  @param Result Recorded snapshot.
   --  @param Index One-based retained row index.
   --  @param Axis Metric axis.
   --  @return Per-span value in Metric_Unit units.
   --  @exception Constraint_Error Index is out of range or Axis has no value.
   function Sample_Metric_Value
     (Result : Recorded_Measurement;
      Index  : Positive;
      Axis   : Metric_Axis) return Long_Float;

   --  Compare independently collected distributions. Unlike Compare, this
   --  does not assume adjacent or correlated sample pairs.
   --  @param Reference Independently collected baseline distribution.
   --  @param Contender Independently collected candidate distribution.
   --  @param Result Independent bootstrap comparison.
   --  @param Practical_Threshold_Percent Relative practical-effect threshold.
   --  @param Random_Seed Deterministic bootstrap seed.
   --  @exception Constraint_Error Practical_Threshold_Percent is negative.
   procedure Compare_Independent
     (Reference : Recorded_Measurement;
      Contender : Recorded_Measurement;
      Result    : out Recorded_Comparison;
      Practical_Threshold_Percent : Long_Float := 1.0;
      Random_Seed : Long_Long_Integer := 1);

   --  Return the reference identity.
   --  @param Result Independent comparison.
   --  @return Reference name.
   function Reference_Name (Result : Recorded_Comparison) return String;
   --  Return the contender identity.
   --  @param Result Independent comparison.
   --  @return Contender name.
   function Contender_Name (Result : Recorded_Comparison) return String;
   --  Return reference median divided by contender median.
   --  @param Result Independent comparison.
   --  @return Speedup, greater than one when the contender is faster.
   --  @exception Constraint_Error Wall comparison is unavailable.
   function Speedup (Result : Recorded_Comparison) return Long_Float;
   --  Return the lower bootstrap speedup endpoint.
   --  @param Result Independent comparison.
   --  @return Lower 95-percent confidence endpoint.
   --  @exception Constraint_Error Wall comparison is unavailable.
   function Speedup_Confidence_Low
     (Result : Recorded_Comparison) return Long_Float;
   --  Return the upper bootstrap speedup endpoint.
   --  @param Result Independent comparison.
   --  @return Upper 95-percent confidence endpoint.
   --  @exception Constraint_Error Wall comparison is unavailable.
   function Speedup_Confidence_High
     (Result : Recorded_Comparison) return Long_Float;
   --  Return contender median change relative to reference.
   --  @param Result Independent comparison.
   --  @return Percent change, negative when contender wall time is lower.
   --  @exception Constraint_Error Wall comparison is unavailable.
   function Relative_Change_Percent
     (Result : Recorded_Comparison) return Long_Float;
   --  Return the lower relative-change endpoint.
   --  @param Result Independent comparison.
   --  @return Lower 95-percent confidence endpoint in percent.
   --  @exception Constraint_Error Wall comparison is unavailable.
   function Relative_Change_Confidence_Low
     (Result : Recorded_Comparison) return Long_Float;
   --  Return the upper relative-change endpoint.
   --  @param Result Independent comparison.
   --  @return Upper 95-percent confidence endpoint in percent.
   --  @exception Constraint_Error Wall comparison is unavailable.
   function Relative_Change_Confidence_High
     (Result : Recorded_Comparison) return Long_Float;
   --  Return the practical independent-comparison verdict.
   --  @param Result Independent comparison.
   --  @return Faster, equivalent, or inconclusive verdict.
   function Verdict
     (Result : Recorded_Comparison) return Comparison_Verdict;
   --  Report whether wall-derived speedup and relative-change values exist.
   --  @param Result Independent comparison.
   --  @return True when both sides supplied positive, complete wall samples.
   function Wall_Comparison_Available
     (Result : Recorded_Comparison) return Boolean;
   --  Return the reference collection status retained by the comparison.
   --  @param Result Independent comparison.
   --  @param Axis Metric axis.
   --  @return Reference status.
   function Reference_Metric_Status
     (Result : Recorded_Comparison;
      Axis   : Metric_Axis) return Metric_Availability;
   --  Return the contender collection status retained by the comparison.
   --  @param Result Independent comparison.
   --  @param Axis Metric axis.
   --  @return Contender status.
   function Contender_Metric_Status
     (Result : Recorded_Comparison;
      Axis   : Metric_Axis) return Metric_Availability;
   --  Return one independently resampled metric comparison.
   --  @param Result Independent comparison.
   --  @param Axis Metric axis.
   --  @return Available or unavailable metric comparison.
   function Compare_Metric
     (Result : Recorded_Comparison;
      Axis   : Metric_Axis) return Metric_Comparison_Result;

private
   Maximum_Name_Length : constant := 96;
   type Name_Buffer is array (Positive range 1 .. Maximum_Name_Length)
     of Character;
   type Fixed_Name is record
      Length : Natural range 0 .. Maximum_Name_Length := 0;
      Data   : Name_Buffer := [others => ' '];
   end record;

   type Recorder_Backend is limited interface;
   type Recorder_Backend_Access is access all Recorder_Backend'Class;
   type Dashboard_Backend is limited interface;
   type Dashboard_Backend_Access is access all Dashboard_Backend'Class;

   type Benchmark is record
      Owner      : Recorder_Backend_Access := null;
      Identifier : Natural := 0;
      Label      : Fixed_Name;
   end record;

   type Span is new Ada.Finalization.Limited_Controlled with record
      Owner                : Recorder_Backend_Access := null;
      Identifier           : Natural := 0;
      Active               : Boolean := False;
      Started_At           : Interfaces.Unsigned_64 := 0;
      Native_Thread        : Interfaces.Unsigned_64 := 0;
      Resource_Before      : Resource_Values := [others => 0];
      Resource_Before_Mask : Interfaces.Unsigned_64 := 0;
      Scheduler_Before     : Flyology_Scheduler_Snapshot;
      Perf_Before          : Perf_Values := [others => 0];
      Perf_Enabled_Before  : Perf_Values := [others => 0];
      Perf_Running_Before  : Perf_Values := [others => 0];
      Perf_Before_Mask     : Interfaces.Unsigned_64 := 0;
      Overlapped           : Boolean := False;
   end record;
   --  @exclude Internal abandoned-span guard.
   --  @param Object Internal span.
   overriding procedure Finalize (Object : in out Span);

   type Metric_Value_Array is array (Positive range <>) of Long_Float;
   type Metric_Value_Array_Access is access Metric_Value_Array;
   type Metric_Value_Store is array (Metric_Axis) of Metric_Value_Array_Access;
   type Natural_Axis_Array is array (Metric_Axis) of Natural;
   type Attribution_Array is array (Metric_Axis) of Metric_Attribution;
   type Availability_Array is array (Metric_Axis) of Metric_Availability;
   type Summary_Array is array (Metric_Axis) of Metric_Summary;
   type Outcome_Array is array (Sample_Outcome) of Natural;
   type Sample_Value_Vector is array (Metric_Axis) of Long_Float;
   type Sample_Validity_Vector is array (Metric_Axis) of Boolean;
   type Sample_Status_Vector is array (Metric_Axis) of Metric_Availability;
   type Sample_Scope_Changed_Vector is array (Metric_Axis) of Boolean;
   type Recorded_Sample is record
      Observation   : Natural := 0;
      Outcome       : Sample_Outcome := Success;
      Values        : Sample_Value_Vector := [others => 0.0];
      Valid         : Sample_Validity_Vector := [others => False];
      Status        : Sample_Status_Vector :=
        [others => Metric_Not_Requested];
      Scope_Changed : Sample_Scope_Changed_Vector := [others => False];
      Overlapped    : Boolean := False;
   end record;
   type Recorded_Sample_Array is array (Positive range <>) of Recorded_Sample;
   type Recorded_Sample_Array_Access is access Recorded_Sample_Array;

   type Recorded_Measurement is new Ada.Finalization.Controlled with record
      Label          : Fixed_Name;
      Observed_Total : Natural := 0;
      Retained_Total : Natural := 0;
      Dropped_Total  : Natural := 0;
      In_Flight_Total : Natural := 0;
      Abandoned_Total : Natural := 0;
      Outcome_Totals : Outcome_Array := [others => 0];
      Elapsed_NS     : Interfaces.Unsigned_64 := 0;
      Requested      : Metric_Set := [others => False];
      Statuses       : Availability_Array := [others => Metric_Not_Requested];
      Attributions   : Attribution_Array := [others => Unattributable];
      Valid_Counts   : Natural_Axis_Array := [others => 0];
      Invalid_Counts : Natural_Axis_Array := [others => 0];
      Scope_Changed  : Natural_Axis_Array := [others => 0];
      Values         : Metric_Value_Store := [others => null];
      Samples        : Recorded_Sample_Array_Access := null;
      Summaries      : Summary_Array := [others => (others => <>)];
   end record;
   --  @exclude Internal deep-copy hook.
   --  @param Object Internal result.
   overriding procedure Adjust (Object : in out Recorded_Measurement);
   --  @exclude Internal deep-result cleanup hook.
   --  @param Object Internal result.
   overriding procedure Finalize (Object : in out Recorded_Measurement);

   type Metric_Comparison_Array is
     array (Metric_Axis) of Metric_Comparison_Result;
   type Recorded_Comparison is record
      Reference_Label : Fixed_Name;
      Contender_Label : Fixed_Name;
      Speedup_Value   : Long_Float := 1.0;
      Speedup_Low     : Long_Float := 1.0;
      Speedup_High    : Long_Float := 1.0;
      Change_Value    : Long_Float := 0.0;
      Change_Low      : Long_Float := 0.0;
      Change_High     : Long_Float := 0.0;
      Verdict_Value   : Comparison_Verdict := Inconclusive;
      Wall_Available  : Boolean := False;
      Reference_Statuses : Availability_Array :=
        [others => Metric_Not_Requested];
      Contender_Statuses : Availability_Array :=
        [others => Metric_Not_Requested];
      Metrics         : Metric_Comparison_Array := [others => (others => <>)];
   end record;

   type Recorder_Guard
     (Maximum_Benchmarks : Benchmark_Capacity;
      Retained_Samples   : Retained_Capacity)
   is new Ada.Finalization.Limited_Controlled with record
      Backend   : Recorder_Backend_Access := null;
      Dashboard : Dashboard_Backend_Access := null;
   end record;
   --  @exclude Internal recorder allocation hook.
   --  @param Object Internal recorder guard.
   overriding procedure Initialize (Object : in out Recorder_Guard);
   --  @exclude Internal recorder cleanup hook.
   --  @param Object Internal recorder guard.
   overriding procedure Finalize (Object : in out Recorder_Guard);

   type Recorder
     (Maximum_Benchmarks : Benchmark_Capacity;
      Retained_Samples   : Retained_Capacity) is limited record
      Guard : Recorder_Guard (Maximum_Benchmarks, Retained_Samples);
   end record;
end Flyology_Bench.Recording;
