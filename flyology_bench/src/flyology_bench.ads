--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Finalization;
with Ada.Strings.Unbounded;
with Interfaces;

--  Measures adaptive batches and paired comparisons of Ada operations.
package Flyology_Bench is
   --  Configuration bounds are carried by the subtypes and record predicates
   --  below rather than by a validation pass. Predicates are assertions, and
   --  this crate builds without -gnata, so they are enabled explicitly.
   pragma Assertion_Policy (Dynamic_Predicate => Check);

   --  Number of logical benchmark operations. Zero is useful for caller-owned
   --  counters; a measured batch always contains at least one iteration.
   type Iteration_Count is range 0 .. Long_Long_Integer'Last;

   --  Batch size for one timed sample, which is never empty.
   subtype Positive_Iteration_Count is
     Iteration_Count range 1 .. Iteration_Count'Last;

   --  Wall-time budget that may legitimately be zero, either because a stage
   --  is skipped or because a limit is disabled.
   subtype Nonnegative_Duration is Duration range 0.0 .. Duration'Last;

   --  Wall-time interval that must actually elapse. Duration'Small is one
   --  nanosecond, so this covers all of Duration above zero.
   subtype Positive_Duration is Duration range Duration'Small .. Duration'Last;

   --  Share of an observed capacity, in percent.
   subtype Percentage is Long_Float range 0.0 .. 100.0;

   --  Percentage excluding the whole. 'Pred is a static attribute, so this
   --  stays an ordinary range constraint rather than a predicate.
   subtype Threshold_Percentage is
     Percentage range 0.0 .. Long_Float'Pred (100.0);

   --  Number of independently timed samples collected for one measurement.
   subtype Sample_Count is Positive range 10 .. 1_000;

   --  Central coverage of a two-sided bootstrap confidence interval, in
   --  percent. The bounds exclude intervals too narrow to be useful and the
   --  unattainable 100-percent interval.
   subtype Confidence_Percentage is Long_Float range 50.0 .. 99.9;

   --  Number of bootstrap distributions drawn for each reported interval.
   --  The upper bound keeps analysis time and temporary storage bounded.
   subtype Bootstrap_Resample_Count is Positive range 100 .. 10_000;

   --  Index into the raw samples retained by a measurement.
   subtype Sample_Index is Positive range 1 .. Sample_Count'Last;

   --  Maximum number of implementations in one multi-way comparison.
   Max_Comparison_Cases : constant := 16;
   --  Number of implementations participating in a multi-way comparison.
   subtype Comparison_Case_Count is Positive range 2 .. Max_Comparison_Cases;
   --  One-based implementation index in enumeration order.
   subtype Comparison_Case_Index is Positive range 1 .. Max_Comparison_Cases;

   --  Stage reported by an optional progress callback. Callbacks execute only
   --  outside timed regions.
   --  @enum Starting The run is initializing its clock and state.
   --  @enum Waiting_For_CPU_Quiescence The harness is waiting for sustained
   --  low host CPU utilization before warmup.
   --  @enum Warming The operation is executing outside timed sampling.
   --  @enum Calibrating The harness is selecting a batch size.
   --  @enum Sampling Timed samples are being collected.
   --  @enum Analyzing Statistics and confidence intervals are being computed.
   --  @enum Finished The result is complete.
   type Progress_Phase is
     (Starting, Waiting_For_CPU_Quiescence, Warming, Calibrating, Sampling,
      Analyzing, Finished);

   --  Receives coarse benchmark progress. Total is zero when a phase has no
   --  meaningful bounded work count.
   --  @param Name Human-readable benchmark or implementation identity.
   --  @param Phase Current benchmark stage.
   --  @param Completed Completed work units in the current stage.
   --  @param Total Total work units, or zero when the phase is unbounded.
   type Progress_Handler is access procedure
     (Name      : String;
      Phase     : Progress_Phase;
      Completed : Natural;
      Total     : Natural);

   --  Statistical and practical interpretation of a paired comparison.
   --  @enum Inconclusive The confidence interval supports no practical verdict.
   --  @enum Practically_Equivalent The full interval lies inside the configured
   --  practical threshold.
   --  @enum Contender_Faster The contender is faster beyond the threshold.
   --  @enum Reference_Faster The reference is faster beyond the threshold.
   type Comparison_Verdict is
     (Inconclusive, Practically_Equivalent, Contender_Faster,
      Reference_Faster);

   --  Controls how comparison batches divide their wall-time budget.
   --  Equal_Time independently calibrates each implementation toward the same
   --  per-sample duration. Shared_Iterations uses one logical operation count
   --  for every implementation, so elapsed time varies with their speed.
   --  @enum Equal_Time Independently calibrate equal timed slices.
   --  @enum Shared_Iterations Use one logical operation count for every case.
   type Comparison_Batch_Policy is (Equal_Time, Shared_Iterations);

   --  Controls how Compare_Many orders implementation batches.
   --  Balanced_Rounds interleaves cases and rotates their positions.
   --  Sequential_Cases completes one case's sample block before the next.
   --  @enum Balanced_Rounds Interleave and position-balance implementation
   --  batches.
   --  @enum Sequential_Cases Collect one implementation's block at a time.
   type Shootout_Schedule_Policy is (Balanced_Rounds, Sequential_Cases);

   --  One independently sampled measurement axis. Wall_Time remains the
   --  calibration and collection-budget clock even when it is not selected
   --  for reporting. Process counters include every thread in the benchmark
   --  process; thread CPU covers only the executing pthread. Linux PMU
   --  counters additionally inherit into child native tasks created after
   --  counter initialization. Flyology counters require Scheduler_Probe.
   --  @enum Wall_Time Monotonic elapsed nanoseconds per logical operation.
   --  @enum Process_CPU_Time User plus system CPU nanoseconds per operation
   --  across the process.
   --  @enum Thread_CPU_Time User plus system CPU nanoseconds per operation on
   --  the calling native pthread.
   --  @enum Process_RSS Resident bytes observed after the batch.
   --  @enum Process_RSS_Change Resident-byte change per logical operation.
   --  @enum Minor_Page_Faults Minor faults per logical operation.
   --  @enum Major_Page_Faults Major faults per logical operation.
   --  @enum Voluntary_Context_Switches Voluntary switches per operation.
   --  @enum Involuntary_Context_Switches Involuntary switches per operation.
   --  @enum Disk_Read_Bytes Storage bytes read per logical operation.
   --  @enum Disk_Written_Bytes Storage bytes written per logical operation.
   --  @enum Filesystem_Input_Operations Filesystem input operations per
   --  logical operation.
   --  @enum Filesystem_Output_Operations Filesystem output operations per
   --  logical operation.
   --  @enum CPU_Cycles Linux perf CPU cycles per logical operation.
   --  @enum Instructions Linux perf retired instructions per operation.
   --  @enum Instructions_Per_Cycle Linux perf instructions divided by cycles.
   --  @enum Cache_Misses Linux perf cache misses per logical operation.
   --  @enum Branches Linux perf branch instructions per logical operation.
   --  @enum Branch_Misses Linux perf branch misses per logical operation.
   --  @enum Flyology_Dispatches Scheduler dispatches per logical operation.
   --  @enum Flyology_Poll_Batches Poller batches per logical operation.
   --  @enum Flyology_Poll_Events Delivered poll events per logical operation.
   --  @enum Flyology_Wakeups Wake requests per logical operation.
   --  @enum Flyology_Migrations Inbound plus outbound migrations per logical
   --  operation.
   type Metric_Axis is
     (Wall_Time,
      Process_CPU_Time,
      Thread_CPU_Time,
      Process_RSS,
      Process_RSS_Change,
      Minor_Page_Faults,
      Major_Page_Faults,
      Voluntary_Context_Switches,
      Involuntary_Context_Switches,
      Disk_Read_Bytes,
      Disk_Written_Bytes,
      Filesystem_Input_Operations,
      Filesystem_Output_Operations,
      CPU_Cycles,
      Instructions,
      Instructions_Per_Cycle,
      Cache_Misses,
      Branches,
      Branch_Misses,
      Flyology_Dispatches,
      Flyology_Poll_Batches,
      Flyology_Poll_Events,
      Flyology_Wakeups,
      Flyology_Migrations);

   --  Set of axes requested for one run.
   type Metric_Set is array (Metric_Axis) of Boolean;

   --  Wall-time results only, without additional native probes.
   Time_Metrics : constant Metric_Set := [Wall_Time => True, others => False];
   --  Portable Darwin/Linux process, thread, memory, fault, switch, and I/O
   --  counters in addition to wall time.
   Process_Resource_Metrics : constant Metric_Set :=
     [Wall_Time .. Filesystem_Output_Operations => True, others => False];
   --  Linux perf counters covering the calling pthread and the native tasks
   --  it creates afterwards. Axes remain unavailable when the kernel, host
   --  PMU, or perf permissions reject an event; Metric_Status reports which.
   Linux_Hardware_Metrics : constant Metric_Set :=
     [CPU_Cycles .. Branch_Misses => True, others => False];
   --  Counters supplied through Scheduler_Probe.
   Flyology_Scheduler_Metrics : constant Metric_Set :=
     [Flyology_Dispatches .. Flyology_Migrations => True, others => False];
   --  Every built-in axis; Flyology scheduler counters remain opt-in because
   --  the standalone crate has no dependency on the Flyology runtime.
   All_Builtin_Metrics : constant Metric_Set :=
     Process_Resource_Metrics or Linux_Hardware_Metrics;

   --  Collection state retained for each requested metric.
   --  @enum Metric_Not_Requested The configuration did not select the axis.
   --  @enum Metric_Collected Every retained sample contains a value.
   --  @enum Unsupported_Platform The operating system has no backend.
   --  @enum Permission_Denied The operating system rejected probe access.
   --  @enum Unsupported_Event The host exposes no counter for the event,
   --  either because it has no performance monitoring unit or because that
   --  unit does not implement this event.
   --  @enum Counter_Resources_Unavailable The event could not be scheduled or
   --  allocated.
   --  @enum Probe_Failed A native snapshot, counter control, or read failed,
   --  or the kernel rejected the requested counter attributes.
   --  @enum Counter_Reset A custom cumulative ending value was below its
   --  beginning value.
   --  @enum Invalid_Value A custom value was NaN, infinite, or a negative
   --  completed elapsed value.
   --  @enum Conversion_Overflow Custom delta or unit conversion overflowed.
   --  @enum Metric_Partially_Collected At least one retained sample contains a
   --  value, but one or more retained samples do not.
   type Metric_Availability is
     (Metric_Not_Requested,
      Metric_Collected,
      Unsupported_Platform,
      Permission_Denied,
      Unsupported_Event,
      Counter_Resources_Unavailable,
      Probe_Failed,
      Metric_Partially_Collected,
      Counter_Reset,
      Invalid_Value,
      Conversion_Overflow);

   --  Attribution boundary of a metric.
   --  @enum Batch_Wall_Clock Monotonic elapsed time surrounding the batch.
   --  @enum Benchmark_Process All native threads in the process.
   --  @enum Current_Native_Thread Only the pthread executing the probe.
   --  @enum Native_Task_Tree The executing pthread and child native tasks or
   --  processes it creates after counter initialization.
   --  @enum Flyology_Runtime Counters supplied by Flyology observability.
   --  @enum Caller_Defined_Window Scope described by the provider contract.
   --  @enum Device_Or_Accelerator Synchronized external execution scope.
   --  @enum Simulated_Clock Deterministic or simulated clock scope.
   type Metric_Scope is
     (Batch_Wall_Clock, Benchmark_Process, Current_Native_Thread,
      Native_Task_Tree, Flyology_Runtime, Caller_Defined_Window,
      Device_Or_Accelerator, Simulated_Clock);

   --  Quality of the boundary used to attribute a collected metric. This is
   --  deliberately separate from Metric_Availability: a process-wide value
   --  can be successfully collected while also including concurrent work
   --  outside the operation being observed.
   --  @enum Exact_Window The value belongs to the measured wall-clock window.
   --  @enum Same_Native_Thread_Window The value covers one native thread and
   --  is valid only when both boundaries execute on that thread.
   --  @enum Native_Task_Tree_Window The value covers one native thread and
   --  native children inherited by its counter group.
   --  @enum Shared_Process_Window The value covers the complete process and
   --  can include unrelated or concurrent work.
   --  @enum Shared_Runtime_Window The value covers a Flyology runtime or
   --  execution-group boundary rather than one operation exclusively.
   --  @enum Unattributable No valid attribution survived the two boundaries.
   type Metric_Attribution is
     (Exact_Window,
      Same_Native_Thread_Window,
      Native_Task_Tree_Window,
      Shared_Process_Window,
      Shared_Runtime_Window,
      Unattributable);

   --  Whether a smaller or larger value is normally resource-favorable.
   --  Diagnostic metrics receive no better/worse verdict.
   --  @enum Lower_Is_Better Smaller resource consumption is favorable.
   --  @enum Higher_Is_Better Larger efficiency is favorable.
   --  @enum Diagnostic No general optimization direction is asserted.
   type Metric_Direction is
     (Lower_Is_Better, Higher_Is_Better, Diagnostic);

   --  Statistical form used to compare one metric.
   --  @enum Relative_Ratio Paired positive samples use ratios and percent.
   --  @enum Absolute_Difference Signed or zero-valued samples use differences.
   type Metric_Comparison_Method is
     (Relative_Ratio, Absolute_Difference);

   --  Bounded caller-defined measurement axes. Registration is complete
   --  before a run starts; collection performs no allocation.
   Max_Custom_Metrics : constant := 8;
   --  Maximum custom metric identity length.
   Max_Custom_Metric_Name_Length : constant := 48;
   --  Maximum custom metric unit length.
   Max_Custom_Metric_Unit_Length : constant := 24;
   --  Maximum alternate timing source identity length.
   Max_Timing_Source_Name_Length : constant := 48;
   --  Number of registered custom axes.
   subtype Custom_Metric_Count is Natural range 0 .. Max_Custom_Metrics;
   --  One-based custom axis index in registration order.
   subtype Custom_Metric_Index is Positive range 1 .. Max_Custom_Metrics;

   --  Meaning of the two snapshots surrounding one retained batch.
   --  Cumulative_Delta requires a nondecreasing signed counter and stores
   --  After - Before. Absolute_Sample stores the ending value. Completed_Elapsed
   --  also stores the ending value, but identifies it as a synchronized elapsed
   --  duration supplied by the measured batch.
   --  @enum Cumulative_Delta Store a checked ending-minus-beginning counter.
   --  @enum Absolute_Sample Store the explicit ending sample value.
   --  @enum Completed_Elapsed Store a synchronized finite nonnegative elapsed
   --  value returned by measured work.
   type Custom_Sample_Semantics is
     (Cumulative_Delta, Absolute_Sample, Completed_Elapsed);

   --  Whether a batch value is retained once or divided by its exact logical
   --  operation count. Units must describe the resulting value truthfully.
   --  @enum Per_Batch Retain one value for the complete batch.
   --  @enum Per_Operation Divide by the exact logical-operation count.
   type Custom_Normalization is (Per_Batch, Per_Operation);

   --  Comparison method declared by the provider. Relative_Positive rejects
   --  any pair containing zero or a negative value instead of silently
   --  changing statistical meaning. Absolute always compares signed
   --  contender-minus-reference differences.
   --  @enum Relative_Positive Compare paired positive values as ratios.
   --  @enum Absolute Compare paired signed differences.
   type Custom_Comparison_Semantics is
     (Relative_Positive, Absolute);

   --  One caller-provided snapshot slot.
   --  @field Status Collection outcome; values are ignored unless collected.
   --  @field Counter_Value Signed cumulative value for delta semantics.
   --  @field Sample_Value Floating sample for absolute or elapsed semantics.
   type Custom_Value is record
      Status        : Metric_Availability := Metric_Collected;
      Counter_Value : Long_Long_Integer := 0;
      Sample_Value  : Long_Float := 0.0;
   end record;
   --  Fixed provider snapshot covering every possible registered axis.
   type Custom_Snapshot is
     array (Custom_Metric_Index) of Custom_Value;

   --  A single bounded snapshot callback covers every registered custom axis.
   --  It runs once immediately before and once immediately after each retained
   --  batch. It must not allocate if allocation-free collection is required.
   --  @param Snapshot Failure-initialized slots populated by the provider.
   type Custom_Probe is access procedure (Snapshot : in out Custom_Snapshot);

   --  Bounded pre-run descriptors and their transient provider callback.
   type Custom_Metric_Registry is private;

   --  Register one axis in deterministic registration order. Names are
   --  lowercase ASCII identifiers beginning with a letter and containing only
   --  letters, digits, '.', '_', or '-'. Units and timing-source names are
   --  nonempty printable ASCII without commas, quotes, backslashes, or control
   --  characters. Duplicate identities and built-in-name collisions raise
   --  Constraint_Error. Registration beyond Max_Custom_Metrics raises
   --  Capacity_Error.
   --  @param Registry Registry to extend before collection.
   --  @param Name Stable lowercase identity.
   --  @param Unit Unit after optional iteration normalization.
   --  @param Scope Boundary covered by the value.
   --  @param Attribution Quality of the provider's attribution boundary.
   --  @param Direction Favorable comparison direction or diagnostic.
   --  @param Semantics Interpretation of begin and end snapshot fields.
   --  @param Normalization Per-batch or per-operation storage.
   --  @param Comparison Relative-positive or signed absolute comparison.
   --  @param Primary_Timing Whether this is the reported alternate timer.
   --  @param Timing_Source Stable alternate timing source identity.
   --  @param Resolution Positive resolution in Unit for a primary timer.
   procedure Register_Custom_Metric
     (Registry        : in out Custom_Metric_Registry;
      Name            : String;
      Unit            : String;
      Scope           : Metric_Scope;
      Attribution     : Metric_Attribution;
      Direction       : Metric_Direction;
      Semantics       : Custom_Sample_Semantics := Cumulative_Delta;
      Normalization   : Custom_Normalization := Per_Operation;
      Comparison      : Custom_Comparison_Semantics := Relative_Positive;
      Primary_Timing  : Boolean := False;
      Timing_Source   : String := "";
      Resolution      : Long_Float := 0.0);

   --  Install the one provider used by a registry. The provider address lives
   --  only for the synchronous call; completed results never retain it.
   --  @param Registry Registry used by a subsequent synchronous runner call.
   --  @param Probe Begin/end snapshot callback.
   procedure Set_Custom_Probe
     (Registry : in out Custom_Metric_Registry;
      Probe    : Custom_Probe);

   --  Return the number of registered axes.
   --  @param Registry Registry to inspect.
   --  @return Registered custom axis count.
   function Custom_Metrics (Registry : Custom_Metric_Registry)
     return Custom_Metric_Count;

   --  Raised when bounded custom metric registration is full.
   Capacity_Error : exception;

   --  Resource-oriented result of a metric comparison.
   --  @enum Metric_Inconclusive The interval establishes no direction.
   --  @enum Metric_Practically_Equivalent A relative interval lies inside the
   --  configured practical threshold.
   --  @enum Contender_Better The contender uses less resource or has greater
   --  efficiency, according to the metric direction.
   --  @enum Reference_Better The reference is favorable.
   --  @enum Metric_Diagnostic The axis has no general optimization direction.
   type Metric_Verdict is
     (Metric_Inconclusive,
      Metric_Practically_Equivalent,
      Contender_Better,
      Reference_Better,
      Metric_Diagnostic);

   --  Cumulative Flyology scheduler counters supplied outside timed regions.
   --  A caller can sum one or more Flyology.Observability.Group_Snapshot
   --  values. Counters must be process-lifetime monotonic values.
   --  @field Available Whether the snapshot contains usable counters.
   --  @field Dispatches Cumulative fiber dispatches.
   --  @field Poll_Batches Cumulative event-poller batches.
   --  @field Poll_Events Cumulative host events delivered.
   --  @field Wakeups Cumulative task wake requests.
   --  @field Migrations_In Cumulative migrations entering observed groups.
   --  @field Migrations_Out Cumulative migrations leaving observed groups.
   type Flyology_Scheduler_Snapshot is record
      Available      : Boolean := False;
      Dispatches     : Interfaces.Unsigned_64 := 0;
      Poll_Batches   : Interfaces.Unsigned_64 := 0;
      Poll_Events    : Interfaces.Unsigned_64 := 0;
      Wakeups        : Interfaces.Unsigned_64 := 0;
      Migrations_In  : Interfaces.Unsigned_64 := 0;
      Migrations_Out : Interfaces.Unsigned_64 := 0;
   end record;

   --  Capture cumulative Flyology scheduler counters outside a timed region.
   --  @param Snapshot Caller-populated cumulative counter snapshot.
   type Flyology_Scheduler_Probe is access procedure
     (Snapshot : out Flyology_Scheduler_Snapshot);

   --  Distribution summary for one requested measurement axis.
   --  @field Available Whether at least one retained sample has this axis.
   --  @field Samples Number of retained metric samples.
   --  @field Minimum Smallest sample in Metric_Unit units.
   --  @field Maximum Largest sample.
   --  @field Mean Arithmetic sample mean.
   --  @field Median Sample median.
   --  @field P95 Ninety-fifth percentile.
   --  @field P99 Ninety-ninth percentile.
   --  @field Confidence_Low Lower endpoint of the bootstrap mean interval.
   --  @field Confidence_High Upper endpoint of the bootstrap mean interval.
   type Metric_Summary is record
      Available       : Boolean := False;
      Samples         : Natural := 0;
      Minimum         : Long_Float := 0.0;
      Maximum         : Long_Float := 0.0;
      Mean            : Long_Float := 0.0;
      Median          : Long_Float := 0.0;
      P95             : Long_Float := 0.0;
      P99             : Long_Float := 0.0;
      Confidence_Low  : Long_Float := 0.0;
      Confidence_High : Long_Float := 0.0;
   end record;

   --  Paired comparison summary for one metric axis.
   --  Change is contender relative percent for Relative_Ratio and contender
   --  minus reference in Metric_Unit units for Absolute_Difference.
   --  @field Available Whether both sides retained complete axis samples.
   --  @field Method Relative ratio or signed absolute difference.
   --  @field Reference_Median Reference median in Metric_Unit units.
   --  @field Contender_Median Contender median in Metric_Unit units.
   --  @field Change Point estimate of contender change.
   --  @field Confidence_Low Lower endpoint in the same change units.
   --  @field Confidence_High Upper endpoint in the same change units.
   --  @field Verdict Directional, equivalent, inconclusive, or diagnostic.
   type Metric_Comparison_Result is record
      Available         : Boolean := False;
      Method            : Metric_Comparison_Method := Absolute_Difference;
      Reference_Median  : Long_Float := 0.0;
      Contender_Median  : Long_Float := 0.0;
      Change            : Long_Float := 0.0;
      Confidence_Low    : Long_Float := 0.0;
      Confidence_High   : Long_Float := 0.0;
      Verdict           : Metric_Verdict := Metric_Inconclusive;
   end record;

   --  Controls the optional host CPU preflight gate. When enabled, the harness
   --  samples utilization outside timed regions and proceeds only after both
   --  the host-wide average and busiest logical CPU remain at or below their
   --  limits for Stable_Time. This detects competing CPU work; it does not
   --  establish I/O, thermal, frequency, or interrupt quiescence.
   --  The gate's settings exist only while it is enabled, so a disabled
   --  policy carries no tuning to keep coherent.
   --  @field Enabled Whether to wait before clock characterization and warmup.
   --  @field Maximum_Average_CPU_Percent Largest accepted host-wide busy share.
   --  @field Maximum_Core_CPU_Percent Largest accepted busy share on any one
   --  logical CPU.
   --  @field Stable_Time Continuous accepted interval required before starting.
   --  @field Poll_Interval Delay between host CPU counter snapshots. A poll
   --  slower than the timeout would let the gate expire unsampled.
   --  @field Timeout Maximum wall time spent waiting before raising
   --  CPU_Quiescence_Timeout. A timeout shorter than Stable_Time could never
   --  be satisfied.
   type CPU_Quiescence_Policy (Enabled : Boolean := False) is record
      case Enabled is
         when True =>
            Maximum_Average_CPU_Percent : Percentage := 20.0;
            Maximum_Core_CPU_Percent    : Percentage := 50.0;
            Stable_Time                 : Positive_Duration := 1.0;
            Poll_Interval               : Positive_Duration := 0.100;
            Timeout                     : Positive_Duration := 15.0;
         when False =>
            null;
      end case;
   end record
     with Dynamic_Predicate =>
       (if CPU_Quiescence_Policy.Enabled
        then CPU_Quiescence_Policy.Timeout
               >= CPU_Quiescence_Policy.Stable_Time
             and then CPU_Quiescence_Policy.Poll_Interval
                        <= CPU_Quiescence_Policy.Timeout),
     Predicate_Failure =>
       raise Constraint_Error with
         "CPU quiescence timeout must cover the stable interval, and its "
         & "poll interval must not exceed the timeout";

   --  Raised when enabled CPU quiescence is not observed before its timeout.
   CPU_Quiescence_Timeout : exception;

   --  Response applied when foreign CPU work is observed during collection.
   --  The preflight gate only proves the host was quiet before warmup; this
   --  policy decides what happens when it stops being quiet afterwards.
   --  @enum Observe Retain every sample and report what was seen. Nothing is
   --  discarded, so the raw distribution stays exactly as collected.
   --  @enum Retake Discard the contaminated window and collect it again,
   --  bounded by Maximum_Retakes.
   --  @enum Pause Wait for foreign load to settle, re-warm the workload, and
   --  resume, bounded by Maximum_Pause_Time.
   type Interference_Response is (Observe, Retake, Pause);

   --  How foreign CPU load was attributed.
   --  @enum Host_Wide Foreign load is the host's busy time minus this
   --  process's own CPU time. Available on every supported platform.
   --  @enum Core_Scoped Foreign load is measured on the claimed logical CPUs
   --  and their SMT siblings. Requires strict placement, so Linux only, and
   --  holds only while this process runs one CPU-consuming thread; see
   --  Environment_Report.Attribution_Diluted.
   type Interference_Source is (Host_Wide, Core_Scoped);

   --  Controls the optional mid-run host interference watch. Foreign CPU load
   --  is estimated between timed samples, never inside them, over windows of
   --  at least Window wall time. Windows are whole numbers of samples, pairs,
   --  or balanced rounds, so a response never splits a comparison's pairing.
   --
   --  Host CPU counters are tick-based on both platforms, so a window shorter
   --  than one tick cannot produce a trustworthy estimate. A closed window
   --  that did not reach Window is recorded but never triggers a response.
   --
   --  This detects competing CPU work. It does not detect contention for
   --  shared cache or memory bandwidth, which perturb a measurement without
   --  moving any CPU busy counter.
   --  The watch's settings exist only while it is enabled, and the three
   --  pause settings exist only under Pause. Observe and Retake both share
   --  the retake budget, which bounds how many windows one run may redo.
   --  @field Enabled Whether to watch for foreign load during collection.
   --  @field Response What to do when a window exceeds the limit.
   --  @field Maximum_Foreign_CPU_Percent Largest accepted foreign share of
   --  the machine's total CPU capacity.
   --  @field Window Smallest wall interval an estimate is trusted over.
   --  @field Maximum_Retakes Total sample retakes allowed for one run.
   --  @field Settle_Time Continuous accepted interval required before a
   --  paused run resumes.
   --  @field Maximum_Pause_Time Total wall time one run may spend paused.
   --  Paused time is excluded from Maximum_Sampling_Time. A budget smaller
   --  than one settle interval could never resume a run.
   --  @field Rewarm_Time Untimed warmup executed after a pause, before timed
   --  collection resumes. A resumed run is otherwise cold and its first
   --  samples would be the outliers the pause was meant to avoid.
   type Interference_Policy
     (Enabled  : Boolean := False;
      Response : Interference_Response := Observe) is
   record
      case Enabled is
         when True =>
            Maximum_Foreign_CPU_Percent : Percentage := 10.0;
            Window                      : Positive_Duration := 0.050;
            Maximum_Retakes             : Natural := 25;
            case Response is
               when Observe | Retake =>
                  null;
               when Pause =>
                  Settle_Time        : Positive_Duration := 0.250;
                  Maximum_Pause_Time : Positive_Duration := 30.0;
                  Rewarm_Time        : Nonnegative_Duration := 0.050;
            end case;
         when False =>
            null;
      end case;
   end record
     with Dynamic_Predicate =>
       (if Interference_Policy.Enabled
          and then Interference_Policy.Response = Pause
        then Interference_Policy.Maximum_Pause_Time
               >= Interference_Policy.Settle_Time),
     Predicate_Failure =>
       raise Constraint_Error with
         "interference pause budget must cover one settle interval";

   --  Controls optional harness-applied placement of the benchmark thread.
   --  Placement is never neutral: it fixes frequency and thermal behavior and
   --  removes the load balancing a deployed workload would receive. It also
   --  binds only the calling thread, so a benchmark whose work runs on event
   --  loops or a native executor pool stays partly unplaced. Use it for
   --  single-threaded microbenchmarks, not for scheduler measurements.
   --  @field Enabled Whether the harness pins its own benchmark thread.
   --  @field CPU Zero-based logical CPU, or Darwin affinity tag index.
   --  @field Include_Siblings Whether SMT siblings of the placed CPU join the
   --  watched set. A sibling saturated by another process perturbs the
   --  measurement while leaving the placed CPU's own busy share clean, so
   --  disabling this makes core-scoped observation confidently wrong.
   --  @field Require_Strict Whether an advisory-only platform is an error
   --  rather than a documented degradation.
   type Placement_Policy (Enabled : Boolean := False) is record
      case Enabled is
         when True =>
            CPU              : Natural := 0;
            Include_Siblings : Boolean := True;
            Require_Strict   : Boolean := False;
         when False =>
            null;
      end case;
   end record;

   --  Raised when Require_Strict placement is not available.
   Placement_Unavailable : exception;

   --  Controls the optional host CPU claim held for the duration of a run.
   --  The claim coordinates with other tools that follow the same convention,
   --  including load generators and profilers, not with arbitrary CPU work.
   --  Two harnesses that both pause on interference would otherwise oscillate
   --  against each other indefinitely, each being the other's foreign load.
   --  @field Enabled Whether to claim host CPU capacity for the run.
   --  @field Path Claim path, or empty for the convention default.
   --  @field Timeout Longest wait for a conflicting holder to finish.
   --  @field Poll_Interval Delay between claim attempts while waiting.
   --  @field Require_Machine_Scope Whether an unusable path, an exhausted
   --  timeout, or a privately mounted path is an error rather than a recorded
   --  degradation. A silently unserialized run is worse than a failed one.
   type Host_Lock_Policy (Enabled : Boolean := False) is record
      case Enabled is
         when True =>
            Path                  : Ada.Strings.Unbounded.Unbounded_String :=
              Ada.Strings.Unbounded.Null_Unbounded_String;
            Timeout               : Nonnegative_Duration := 30.0;
            Poll_Interval         : Positive_Duration := 0.250;
            Require_Machine_Scope : Boolean := False;
         when False =>
            null;
      end case;
   end record;

   --  Raised when a required host CPU claim could not be established.
   Host_Lock_Unavailable : exception;

   --  Outcome of optional harness-applied placement.
   --  @enum Placement_Not_Requested The policy was disabled.
   --  @enum Placement_Strict The benchmark thread is bound to one logical CPU.
   --  @enum Placement_Advisory The platform accepted only a scheduler hint,
   --  so the executing CPU is unknown and observation stays host-wide.
   --  @enum Placement_Rejected The platform refused the request.
   type Placement_Outcome is
     (Placement_Not_Requested, Placement_Strict, Placement_Advisory,
      Placement_Rejected);

   --  Outcome of the optional host CPU claim.
   --  @enum Lock_Not_Requested The policy was disabled.
   --  @enum Lock_Held The claim was taken and covers the machine as far as
   --  can be determined from inside it.
   --  @enum Lock_Namespace_Scoped The claim was taken, but the path resolves
   --  inside a private mount namespace, so it excludes only processes sharing
   --  that namespace.
   --  @enum Lock_Busy A conflicting holder was still present at the timeout.
   --  @enum Lock_Path_Unusable The claim path could not be opened.
   type Host_Lock_Outcome is
     (Lock_Not_Requested, Lock_Held, Lock_Namespace_Scoped, Lock_Busy,
      Lock_Path_Unusable);

   --  What the harness observed about its host while collecting one
   --  measurement. Every field is a record of conditions, never a correction:
   --  no reported statistic is adjusted by any of it.
   --  @field Watched Whether the watch produced at least one usable window.
   --  @field Attribution How foreign load was attributed.
   --  @field Windows Number of closed observation windows.
   --  @field Observed_Samples Retained samples covered by a closed window.
   --  For a multi-way shootout this counts every case, so it exceeds any one
   --  case's sample count.
   --  @field Mean_Foreign_CPU_Percent Mean foreign share across those
   --  windows, including windows whose samples were discarded and collected
   --  again: it describes the host during the run, not only the data kept.
   --  @field Peak_Foreign_CPU_Percent Largest foreign share in any window.
   --  @field Contaminated_Samples Retained samples collected during a window
   --  that exceeded the configured limit, out of Observed_Samples.
   --  @field Retaken_Samples Samples discarded and collected again.
   --  @field Pauses Number of times collection was suspended.
   --  @field Paused_Nanoseconds Total wall time spent suspended.
   --  @field Budget_Exhausted Whether a retake or pause budget ran out, after
   --  which the run continued under Observe.
   --  @field Placement Placement outcome for the benchmark thread.
   --  @field Watched_CPUs Logical CPUs in the observed set, zero when the
   --  attribution is host-wide.
   --  @field Attribution_Diluted Whether core-scoped attribution was
   --  abandoned mid-run. Placement binds only the calling thread, so another
   --  thread of this process can run on a watched CPU, where its time is
   --  indistinguishable from foreign load. When those threads consume more of
   --  the watched capacity than the configured foreign limit, the core-scoped
   --  answer can no longer address the question the limit asks, and the run
   --  continues host-wide instead of reporting its own runtime as
   --  interference.
   --  @field Host_Lock Host CPU claim outcome.
   type Environment_Report is record
      Watched                  : Boolean := False;
      Attribution              : Interference_Source := Host_Wide;
      Windows                  : Natural := 0;
      Observed_Samples         : Natural := 0;
      Mean_Foreign_CPU_Percent : Long_Float := 0.0;
      Peak_Foreign_CPU_Percent : Long_Float := 0.0;
      Contaminated_Samples     : Natural := 0;
      Retaken_Samples          : Natural := 0;
      Pauses                   : Natural := 0;
      Paused_Nanoseconds       : Long_Float := 0.0;
      Budget_Exhausted         : Boolean := False;
      Placement                : Placement_Outcome := Placement_Not_Requested;
      Watched_CPUs             : Natural := 0;
      Attribution_Diluted      : Boolean := False;
      Host_Lock                : Host_Lock_Outcome := Lock_Not_Requested;
   end record;

   --  Controls warmup, calibration, and timed sampling.
   --  @field Warmup_Time Untimed wall time used to warm code and data.
   --  @field Measurement_Time Target wall time across all timed samples.
   --  @field Maximum_Sampling_Time Hard wall-time budget for sample collection;
   --  zero disables the limit. The harness completes at least ten samples and
   --  checks the budget only between complete samples or comparison rounds.
   --  @field Samples Number of independently timed samples.
   --  @field Minimum_Sample_Time Lower bound for a calibrated sample.
   --  @field Maximum_Iterations Safety bound for one sample's batch size.
   --  @field Comparison_Batching Whether comparisons default to equal timed
   --  slices or one shared logical iteration count.
   --  @field Shootout_Scheduling Whether Compare_Many interleaves balanced
   --  rounds or collects one complete implementation block at a time.
   --  @field Subtract_Timer_Cost Whether to subtract the observed timestamp
   --  cost once from every timed sample.
   --  @field Practical_Threshold_Percent Smallest relative time change treated
   --  as practically meaningful by paired-comparison verdicts.
   --  @field Confidence_Level_Percent Central coverage of every bootstrap
   --  confidence interval, in percent.
   --  @field Bootstrap_Resamples Number of bootstrap distributions drawn for
   --  every analyzed measurement or comparison axis.
   --  @field Random_Seed Seed used for order shuffling and bootstrap sampling.
   --  @field Metrics Axes retained and compared around each timed batch.
   --  @field Scheduler_Probe Optional source of cumulative Flyology scheduler
   --  counters. The callback runs only outside timed regions.
   --  @field Custom_Metrics Bounded custom axes and synchronous run provider.
   --  @field CPU_Quiescence Optional sustained low-host-CPU gate performed
   --  before clock characterization and workload warmup.
   --  @field Interference Optional watch for foreign CPU load arriving after
   --  the preflight gate has already passed.
   --  @field Placement Optional harness-applied placement of the benchmark
   --  thread, which also sharpens interference attribution.
   --  @field Host_Lock Optional host CPU claim coordinating this run with
   --  other tools that follow the same convention.
   --  @field Collect_Process_Telemetry Capture process CPU and RSS around each
   --  timed sample using untimed native probes. Terminal_Mode enables this.
   --  @field Progress Optional callback invoked outside timed regions.
   --  @field Progress_Name Human-readable identity passed to Progress. During
   --  Compare_Many sampling, the current case name follows this identity.
   type Configuration is record
      Warmup_Time          : Nonnegative_Duration := 0.100;
      Measurement_Time     : Positive_Duration := 0.500;
      Maximum_Sampling_Time : Nonnegative_Duration := 0.0;
      Samples              : Sample_Count := 50;
      Minimum_Sample_Time  : Positive_Duration := 0.000_100;
      Maximum_Iterations   : Positive_Iteration_Count :=
        Positive_Iteration_Count'Last;
      Comparison_Batching  : Comparison_Batch_Policy := Equal_Time;
      Shootout_Scheduling  : Shootout_Schedule_Policy := Balanced_Rounds;
      Subtract_Timer_Cost  : Boolean := False;
      Practical_Threshold_Percent : Threshold_Percentage := 1.0;
      Confidence_Level_Percent : Confidence_Percentage := 95.0;
      Bootstrap_Resamples  : Bootstrap_Resample_Count := 2_000;
      Random_Seed          : Long_Long_Integer := 1;
      Metrics              : Metric_Set := Time_Metrics;
      Scheduler_Probe      : Flyology_Scheduler_Probe := null;
      Custom_Metrics       : Custom_Metric_Registry;
      CPU_Quiescence       : CPU_Quiescence_Policy := (others => <>);
      Interference         : Interference_Policy := (others => <>);
      Placement            : Placement_Policy := (others => <>);
      Host_Lock            : Host_Lock_Policy := (others => <>);
      Collect_Process_Telemetry : Boolean := False;
      Progress             : Progress_Handler := null;
      Progress_Name        : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
   end record
     --  A policy assembled field by field is never checked as a whole, so
     --  the enclosing configuration re-asserts each policy's own rule. This
     --  is the check a benchmark call makes on the way in.
     with Dynamic_Predicate =>
       Configuration.CPU_Quiescence in CPU_Quiescence_Policy
       and then Configuration.Interference in Interference_Policy,
     Predicate_Failure =>
       raise Constraint_Error with "incoherent benchmark configuration";

   --  Default configuration for interactive microbenchmark runs.
   Default_Configuration : constant Configuration;

   --  Tukey-fence classifications computed without removing any samples.
   --  @field Low_Severe Samples below the lower outer fence.
   --  @field Low_Mild Samples between the lower outer and inner fences.
   --  @field High_Mild Samples between the upper inner and outer fences.
   --  @field High_Severe Samples above the upper outer fence.
   type Outlier_Counts is record
      Low_Severe  : Natural := 0;
      Low_Mild    : Natural := 0;
      High_Mild   : Natural := 0;
      High_Severe : Natural := 0;
   end record;

   --  Raw samples and summary statistics from one benchmark measurement.
   type Measurement is private;

   --  Paired measurements and relative statistics for two implementations.
   type Comparison is private;

   --  Measurements and paired results for several implementations measured in
   --  common, position-balanced rounds. Case one is the reference.
   type Multi_Comparison is private;

   generic
      --  One logical operation with observable inputs or output.
      with procedure Operation;
   --  Warm, calibrate, and measure one statically bound operation.
   --  @param Config Measurement policy.
   --  @param Result Collected raw samples and summary statistics.
   --  @exception Constraint_Error Config requests more than the bounded
   --  bootstrap analysis work.
   procedure Measure
     (Config : Configuration := Default_Configuration;
      Result : out Measurement);

   generic
      --  Executes the requested logical operation count.
      with procedure Batch (Iterations : Iteration_Count);
   --  Warm, calibrate, and measure a caller-controlled batch. The caller must
   --  perform exactly Iterations logical operations before returning.
   --  @param Config Measurement policy.
   --  @param Result Collected raw samples and summary statistics.
   --  @exception Constraint_Error Config requests more than the bounded
   --  bootstrap analysis work.
   procedure Measure_Batched
     (Config : Configuration := Default_Configuration;
      Result : out Measurement);

   generic
      --  Prepare one batch outside its timed region.
      with procedure Setup;
      --  One logical operation executed inside the timed region.
      with procedure Operation;
      --  Consume or release batch state outside its timed region.
      with procedure Teardown;
   --  Measure an operation with per-sample setup and teardown hooks. Teardown
   --  also runs when the measured operation raises, before the exception is
   --  propagated.
   --  @param Config Measurement policy.
   --  @param Result Collected raw samples and summary statistics.
   --  @exception Constraint_Error Config requests more than the bounded
   --  bootstrap analysis work.
   procedure Measure_With_Hooks
     (Config : Configuration := Default_Configuration;
      Result : out Measurement);

   generic
      --  Observable result produced by a batch.
      type Element is private;
      --  Execute a batch and return a value that keeps its work observable.
      with procedure Batch
        (Iterations : Iteration_Count;
         Value      : out Element);
   --  Measure a result-producing batch and pass its result to an opaque barrier
   --  after the ending timestamp. This avoids charging barrier cost to the
   --  measured operation.
   --  @param Config Measurement policy.
   --  @param Result Collected raw samples and summary statistics.
   --  @exception Constraint_Error Config requests more than the bounded
   --  bootstrap analysis work.
   procedure Measure_Result_Batched
     (Config : Configuration := Default_Configuration;
      Result : out Measurement);

   generic
      --  Existing or baseline operation.
      with procedure Reference_Operation;
      --  Operation compared with the reference.
      with procedure Contender_Operation;
   --  Measure two operations in adjacent, order-balanced sample pairs. Equal
   --  timed slices are the default; Shared_Iterations can require one count.
   --  @param Config Shared measurement policy.
   --  @param Result Paired measurements and relative statistics.
   --  @exception Constraint_Error Config requests more than the bounded
   --  bootstrap analysis work.
   procedure Compare
     (Config : Configuration := Default_Configuration;
      Result : out Comparison);

   generic
      --  Executes a reference batch.
      with procedure Reference_Batch (Iterations : Iteration_Count);
      --  Executes a contender batch.
      with procedure Contender_Batch (Iterations : Iteration_Count);
   --  Measure two caller-controlled batches in adjacent, order-balanced sample
   --  pairs. Each batch must perform exactly Iterations logical operations.
   --  @param Config Shared measurement policy.
   --  @param Result Paired measurements and relative statistics.
   --  @exception Constraint_Error Config requests more than the bounded
   --  bootstrap analysis work.
   procedure Compare_Batched
     (Config : Configuration := Default_Configuration;
      Result : out Comparison);

   generic
      --  Enumeration of implementations; the first value is the reference.
      type Case_Id is (<>);
      --  Execute Iterations operations for the selected implementation.
      with procedure Batch
        (Which      : Case_Id;
         Iterations : Iteration_Count);
   --  Compare two to sixteen implementations in shared rounds. Each case gets
   --  a comparable timed slice by default and occupies every execution
   --  position equally, or within one round when counts are indivisible.
   --  Sampling progress identifies each implementation separately.
   --  @param Config Shared measurement policy.
   --  @param Result Multi-way measurements and comparisons against case one.
   --  @exception Constraint_Error Config requests more than the bounded
   --  bootstrap analysis work.
   procedure Compare_Many
     (Config : Configuration := Default_Configuration;
      Result : out Multi_Comparison);

   --  Return the calibrated logical operation count in each timed sample.
   --  @param Result Completed measurement.
   --  @return Logical operations in each raw sample.
   function Iterations_Per_Sample
     (Result : Measurement) return Iteration_Count;

   --  Return the number of independently timed samples.
   --  @param Result Completed measurement.
   --  @return Number of collected raw samples.
   function Samples (Result : Measurement) return Sample_Count;

   --  Return the measured timestamp cost used for optional subtraction.
   --  @param Result Completed measurement.
   --  @return Minimum observed adjacent-clock cost in nanoseconds.
   function Timer_Cost_Nanoseconds (Result : Measurement) return Long_Float;

   --  Return the platform clock implementation used for the measurement.
   --  @param Result Completed measurement.
   --  @return Stable human-readable backend identifier.
   function Clock_Backend (Result : Measurement) return String;

   --  Return the platform-reported clock resolution.
   --  @param Result Completed measurement.
   --  @return Nominal clock resolution in nanoseconds.
   function Clock_Resolution_Nanoseconds
     (Result : Measurement) return Long_Float;

   --  Return the smallest positive clock step observed during characterization.
   --  @param Result Completed measurement.
   --  @return Observed clock step in nanoseconds, or zero if none was observed.
   function Observed_Clock_Resolution_Nanoseconds
     (Result : Measurement) return Long_Float;

   --  Return the median adjacent-clock interval observed at startup.
   --  @param Result Completed measurement.
   --  @return Median clock-read interval in nanoseconds.
   function Median_Timer_Cost_Nanoseconds
     (Result : Measurement) return Long_Float;

   --  Return the elapsed duration of one calibrated timed batch.
   --  @param Result Completed measurement.
   --  @return Median sample batch duration in nanoseconds.
   function Median_Batch_Nanoseconds
     (Result : Measurement) return Long_Float;

   --  Return the clock-quantization floor amortized over one sample batch.
   --  @param Result Completed measurement.
   --  @return Nominal resolution divided by calibrated iterations.
   function Quantization_Floor_Nanoseconds
     (Result : Measurement) return Long_Float;

   --  Return the fastest retained per-operation sample.
   --  @param Result Completed measurement.
   --  @return Fastest per-operation sample in nanoseconds.
   function Minimum_Nanoseconds (Result : Measurement) return Long_Float;

   --  Return the slowest retained per-operation sample.
   --  @param Result Completed measurement.
   --  @return Slowest per-operation sample in nanoseconds.
   function Maximum_Nanoseconds (Result : Measurement) return Long_Float;

   --  Return the arithmetic mean of the retained per-operation samples.
   --  @param Result Completed measurement.
   --  @return Arithmetic mean per operation in nanoseconds.
   function Mean_Nanoseconds (Result : Measurement) return Long_Float;

   --  Return the median of the retained per-operation samples.
   --  @param Result Completed measurement.
   --  @return Median per operation in nanoseconds.
   function Median_Nanoseconds (Result : Measurement) return Long_Float;

   --  Return the sample standard deviation of per-operation time.
   --  @param Result Completed measurement.
   --  @return Sample standard deviation in nanoseconds.
   function Standard_Deviation_Nanoseconds
     (Result : Measurement) return Long_Float;

   --  Return the median absolute deviation of per-operation time.
   --  @param Result Completed measurement.
   --  @return Median absolute deviation in nanoseconds.
   function Median_Absolute_Deviation_Nanoseconds
     (Result : Measurement) return Long_Float;

   --  Return the 95th percentile of per-operation batch averages. This is not
   --  an individual-operation tail-latency percentile.
   --  @param Result Completed measurement.
   --  @return Linearly interpolated 95th percentile in nanoseconds.
   function P95_Nanoseconds (Result : Measurement) return Long_Float;

   --  Return the 99th percentile of per-operation batch averages. This is not
   --  an individual-operation tail-latency percentile.
   --  @param Result Completed measurement.
   --  @return Linearly interpolated 99th percentile in nanoseconds.
   function P99_Nanoseconds (Result : Measurement) return Long_Float;

   --  Return the lower endpoint of the bootstrap mean interval.
   --  @param Result Completed measurement.
   --  @return Lower endpoint of the deterministic bootstrap mean interval.
   function Mean_Confidence_Low_Nanoseconds
     (Result : Measurement) return Long_Float;

   --  Return the upper endpoint of the bootstrap mean interval.
   --  @param Result Completed measurement.
   --  @return Upper endpoint of the deterministic bootstrap mean interval.
   function Mean_Confidence_High_Nanoseconds
     (Result : Measurement) return Long_Float;

   --  Return the confidence level used to analyze this measurement.
   --  @param Result Completed measurement.
   --  @return Central bootstrap interval coverage in percent.
   function Confidence_Level_Percent
     (Result : Measurement) return Confidence_Percentage;

   --  Return the bootstrap resample count used to analyze this measurement.
   --  @param Result Completed measurement.
   --  @return Number of bootstrap distributions drawn per interval.
   function Bootstrap_Resamples
     (Result : Measurement) return Bootstrap_Resample_Count;

   --  Return sample dispersion relative to the arithmetic mean.
   --  @param Result Completed measurement.
   --  @return Sample standard deviation as a percentage of the mean.
   function Coefficient_Of_Variation_Percent
     (Result : Measurement) return Long_Float;

   --  Return lag-one correlation of sequential sample means.
   --  @param Result Completed measurement.
   --  @return Lag-one sample correlation, or zero when undefined.
   function Sample_Lag_One_Correlation
     (Result : Measurement) return Long_Float;

   --  Return what the harness observed about its host during collection.
   --  Nothing in this report has been applied to any reported statistic: the
   --  harness records the conditions and leaves the samples alone.
   --  @param Result Completed measurement.
   --  @return Environment observations retained for the run.
   function Environment (Result : Measurement) return Environment_Report;

   --  Return the foreign CPU share observed over the window containing one
   --  sample. Samples collected before the first window closed, and every
   --  sample of an unwatched run, report zero.
   --  @param Result Completed measurement.
   --  @param Index One-based index into its collected raw samples.
   --  @return Foreign share of total CPU capacity, in percent.
   --  @exception Constraint_Error If Index exceeds the collected sample count.
   function Sample_Foreign_CPU_Percent
     (Result : Measurement;
      Index  : Sample_Index) return Long_Float;

   --  Return diagnostic Tukey-fence classifications without removing samples.
   --  @param Result Completed measurement.
   --  @return Diagnostic outlier classifications, with no samples removed.
   function Outliers (Result : Measurement) return Outlier_Counts;

   --  Return one retained per-operation sample.
   --  @param Result Completed measurement.
   --  @param Index One-based index into its collected raw samples.
   --  @return Per-operation duration in nanoseconds.
   --  @exception Constraint_Error If Index exceeds the collected sample count.
   function Sample_Nanoseconds
     (Result : Measurement;
      Index  : Sample_Index) return Long_Float;

   --  Return a stable human-readable metric name.
   --  @param Axis Selected measurement axis.
   --  @return Stable display name used by reporters.
   function Metric_Name (Axis : Metric_Axis) return String;

   --  Return the metric's human-readable unit.
   --  @param Axis Selected measurement axis.
   --  @return Unit string, including per-operation normalization.
   function Metric_Unit (Axis : Metric_Axis) return String;

   --  Return the attribution boundary of one metric.
   --  @param Axis Selected measurement axis.
   --  @return Wall, process, current-thread, native-task-tree, or Flyology
   --  runtime scope.
   function Scope (Axis : Metric_Axis) return Metric_Scope;

   --  Return the resource direction used by comparison verdicts.
   --  @param Axis Selected measurement axis.
   --  @return Lower, higher, or diagnostic direction.
   function Direction (Axis : Metric_Axis) return Metric_Direction;

   --  Test whether complete samples exist for one axis.
   --  @param Result Completed measurement.
   --  @param Axis Requested measurement axis.
   --  @return True when every retained sample has a value.
   function Metric_Available
     (Result : Measurement;
      Axis   : Metric_Axis) return Boolean;

   --  Return why an axis is available, absent, or unusable.
   --  @param Result Completed measurement.
   --  @param Axis Measurement axis.
   --  @return Retained collection state with a specific failure class.
   function Metric_Status
     (Result : Measurement;
      Axis   : Metric_Axis) return Metric_Availability;

   --  Test whether an axis was selected for one measurement.
   --  @param Result Completed measurement.
   --  @param Axis Measurement axis.
   --  @return True when the configuration requested the axis.
   function Metric_Requested
     (Result : Measurement;
      Axis   : Metric_Axis) return Boolean;

   --  Return one retained metric sample.
   --  @param Result Completed measurement.
   --  @param Axis Requested measurement axis.
   --  @param Index One-based retained sample index.
   --  @return Value in Metric_Unit units.
   --  @exception Constraint_Error If the axis is unavailable or Index exceeds
   --  the retained sample count.
   function Metric_Sample
     (Result : Measurement;
      Axis   : Metric_Axis;
      Index  : Sample_Index) return Long_Float;

   --  Return the distribution summary for one axis.
   --  @param Result Completed measurement.
   --  @param Axis Requested measurement axis.
   --  @return Available or unavailable summary.
   function Metric_Statistics
     (Result : Measurement;
      Axis   : Metric_Axis) return Metric_Summary;

   --  Number of registered custom axes retained by a measurement.
   --  @param Result Completed measurement.
   --  @return Registered custom axis count.
   function Custom_Metric_Total
     (Result : Measurement) return Custom_Metric_Count;
   --  Locate the declared primary alternate timer.
   --  @param Result Completed measurement.
   --  @return Its one-based custom axis, or zero when none was declared.
   function Primary_Timing_Axis
     (Result : Measurement) return Custom_Metric_Count;
   --  Return a custom axis's stable identity.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Stable custom metric name.
   function Custom_Metric_Name
     (Result : Measurement; Axis : Custom_Metric_Index) return String;
   --  Return the unit after normalization.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Custom metric unit.
   function Custom_Metric_Unit
     (Result : Measurement; Axis : Custom_Metric_Index) return String;
   --  Return the declared scope.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Caller-declared scope.
   function Custom_Metric_Scope
     (Result : Measurement; Axis : Custom_Metric_Index) return Metric_Scope;
   --  Return the declared attribution quality.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Caller-declared attribution.
   function Custom_Metric_Attribution
     (Result : Measurement;
      Axis   : Custom_Metric_Index) return Metric_Attribution;
   --  Return the declared optimization direction.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Lower, higher, or diagnostic direction.
   function Custom_Metric_Direction
     (Result : Measurement; Axis : Custom_Metric_Index) return Metric_Direction;
   --  Return begin/end sample semantics.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Cumulative, absolute, or completed-elapsed semantics.
   function Custom_Metric_Semantics
     (Result : Measurement;
      Axis   : Custom_Metric_Index) return Custom_Sample_Semantics;
   --  Return batch normalization semantics.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Per-batch or per-operation normalization.
   function Custom_Metric_Normalization
     (Result : Measurement;
      Axis   : Custom_Metric_Index) return Custom_Normalization;
   --  Return the declared comparison form.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Relative-positive or signed absolute comparison.
   function Custom_Metric_Comparison
     (Result : Measurement;
      Axis   : Custom_Metric_Index) return Custom_Comparison_Semantics;
   --  Test whether an axis is the alternate reported timer.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return True for the one primary alternate timing axis.
   function Custom_Metric_Is_Primary_Timing
     (Result : Measurement; Axis : Custom_Metric_Index) return Boolean;
   --  Return alternate timer identity, or empty for an ordinary metric.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Stable timing source identity.
   function Custom_Metric_Timing_Source
     (Result : Measurement; Axis : Custom_Metric_Index) return String;
   --  Return alternate source resolution in its output unit.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Positive primary-timer resolution, otherwise zero.
   function Custom_Metric_Resolution
     (Result : Measurement; Axis : Custom_Metric_Index) return Long_Float;
   --  Return aggregate custom-axis availability.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Complete, partial, or failure status.
   function Custom_Metric_Status
     (Result : Measurement;
      Axis   : Custom_Metric_Index) return Metric_Availability;
   --  Return one collected custom value.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @param Index Retained sample index.
   --  @return Value in Custom_Metric_Unit units.
   function Custom_Metric_Sample
     (Result : Measurement;
      Axis   : Custom_Metric_Index;
      Index  : Sample_Index) return Long_Float;
   --  Return one retained custom sample's status.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @param Index Retained sample index.
   --  @return Collected or specific unavailable status.
   function Custom_Metric_Sample_Status
     (Result : Measurement;
      Axis   : Custom_Metric_Index;
      Index  : Sample_Index) return Metric_Availability;
   --  Return the summary over collected custom values.
   --  @param Result Completed measurement.
   --  @param Axis Registered custom axis.
   --  @return Summary whose sample count excludes unavailable values.
   function Custom_Metric_Statistics
     (Result : Measurement;
      Axis   : Custom_Metric_Index) return Metric_Summary;

   --  Return the reference side of a paired comparison.
   --  @param Result Completed comparison.
   --  @return Reference-side measurement using the shared sample schedule.
   function Reference_Measurement (Result : Comparison) return Measurement;

   --  Return the contender side of a paired comparison.
   --  @param Result Completed comparison.
   --  @return Contender-side measurement using the shared sample schedule.
   function Contender_Measurement (Result : Comparison) return Measurement;

   --  Return the confidence level used to analyze this comparison.
   --  @param Result Completed comparison.
   --  @return Central bootstrap interval coverage in percent.
   function Confidence_Level_Percent
     (Result : Comparison) return Confidence_Percentage;

   --  Return the bootstrap resample count used to analyze this comparison.
   --  @param Result Completed comparison.
   --  @return Number of bootstrap distributions drawn per interval.
   function Bootstrap_Resamples
     (Result : Comparison) return Bootstrap_Resample_Count;

   --  Return the geometric mean paired speedup. A value greater than one means
   --  the contender is faster.
   --  @param Result Completed comparison.
   --  @return Geometric mean of paired reference-time/contender-time ratios.
   function Geometric_Mean_Speedup (Result : Comparison) return Long_Float;

   --  Return the median paired speedup. A value greater than one means the
   --  contender is faster.
   --  @param Result Completed comparison.
   --  @return Median paired reference-time/contender-time ratio.
   function Median_Speedup (Result : Comparison) return Long_Float;

   --  Return the lower endpoint of the paired bootstrap speedup interval.
   --  @param Result Completed comparison.
   --  @return Lower endpoint of the paired bootstrap speedup interval.
   function Speedup_Confidence_Low
     (Result : Comparison) return Long_Float;

   --  Return the upper endpoint of the paired bootstrap speedup interval.
   --  @param Result Completed comparison.
   --  @return Upper endpoint of the paired bootstrap speedup interval.
   function Speedup_Confidence_High
     (Result : Comparison) return Long_Float;

   --  Return the contender's relative time change. A negative value means the
   --  contender took less time.
   --  @param Result Completed comparison.
   --  @return Contender time change relative to the reference, in percent.
   function Relative_Time_Change_Percent
     (Result : Comparison) return Long_Float;

   --  Return the lower endpoint of the contender's relative time interval.
   --  @param Result Completed comparison.
   --  @return Lower endpoint of the relative-time-change interval.
   function Relative_Time_Change_Confidence_Low
     (Result : Comparison) return Long_Float;

   --  Return the upper endpoint of the contender's relative time interval.
   --  @param Result Completed comparison.
   --  @return Upper endpoint of the relative-time-change interval.
   function Relative_Time_Change_Confidence_High
     (Result : Comparison) return Long_Float;

   --  Return the practical/statistical verdict for the comparison.
   --  @param Result Completed comparison.
   --  @return Verdict derived from the interval and configured threshold.
   function Verdict (Result : Comparison) return Comparison_Verdict;

   --  Return the configured practical-effect threshold.
   --  @param Result Completed comparison.
   --  @return Symmetric relative-time threshold in percent.
   function Practical_Threshold_Percent
     (Result : Comparison) return Long_Float;

   --  Return the estimated first-versus-second execution order effect.
   --  @param Result Completed comparison.
   --  @return Difference between order-group geometric speedups, in percent.
   function Order_Effect_Percent (Result : Comparison) return Long_Float;

   --  Return lag-one correlation of paired log-speedup samples.
   --  @param Result Completed comparison.
   --  @return Lag-one sample correlation, or zero when undefined.
   function Lag_One_Correlation (Result : Comparison) return Long_Float;

   --  Return the mean paired time difference. A negative value means the
   --  contender took less time.
   --  @param Result Completed comparison.
   --  @return Arithmetic mean of contender-time minus reference-time pairs.
   function Mean_Time_Difference_Nanoseconds
     (Result : Comparison) return Long_Float;

   --  Return the number of sample pairs won by the contender.
   --  @param Result Completed comparison.
   --  @return Pairs in which the contender took less time.
   function Contender_Wins (Result : Comparison) return Natural;

   --  Return the number of sample pairs won by the reference.
   --  @param Result Completed comparison.
   --  @return Pairs in which the reference took less time.
   function Reference_Wins (Result : Comparison) return Natural;

   --  Return the number of equal-time sample pairs.
   --  @param Result Completed comparison.
   --  @return Pairs with equal reported per-operation time.
   function Ties (Result : Comparison) return Natural;

   --  Compare one retained axis using the same paired sample schedule as wall
   --  time. Positive-only axes use relative ratios; signed or zero-containing
   --  axes use paired absolute differences.
   --  @param Result Completed comparison.
   --  @param Axis Requested measurement axis.
   --  @return Available or unavailable paired metric comparison.
   function Compare_Metric
     (Result : Comparison;
      Axis   : Metric_Axis) return Metric_Comparison_Result;

   --  Return one paired custom metric comparison.
   --  @param Result Completed direct or multi-way paired comparison.
   --  @param Axis Registered custom axis.
   --  @return Paired comparison, unavailable unless both sides are complete.
   function Compare_Custom_Metric
     (Result : Comparison;
      Axis   : Custom_Metric_Index) return Metric_Comparison_Result;

   --  Return how many timed pairs ran the reference first.
   --  @param Result Completed comparison.
   --  @return Timed pairs that ran the reference side first.
   function Reference_First_Samples (Result : Comparison) return Natural;

   --  Return how many timed pairs ran the contender first.
   --  @param Result Completed comparison.
   --  @return Timed pairs that ran the contender side first.
   function Contender_First_Samples (Result : Comparison) return Natural;

   --  Return the speedup ratio retained for one adjacent sample pair.
   --  @param Result Completed comparison.
   --  @param Index One-based index into its paired raw samples.
   --  @return Reference-time/contender-time ratio for the pair.
   --  @exception Constraint_Error If Index exceeds the collected sample count.
   function Sample_Speedup
     (Result : Comparison;
      Index  : Sample_Index) return Long_Float;

   --  Return the number of implementations in a multi-way comparison.
   --  @param Result Completed multi-way comparison.
   --  @return Number of measured cases, including the reference.
   function Cases (Result : Multi_Comparison) return Comparison_Case_Count;

   --  Return the schedule used to collect a multi-way comparison.
   --  @param Result Completed multi-way comparison.
   --  @return Balanced or sequential shootout schedule.
   function Shootout_Schedule
     (Result : Multi_Comparison) return Shootout_Schedule_Policy;

   --  Return the batch calibration policy used by a multi-way comparison.
   --  @param Result Completed multi-way comparison.
   --  @return Equal-time or shared-iteration batch policy.
   function Shootout_Batching
     (Result : Multi_Comparison) return Comparison_Batch_Policy;

   --  Return one case's measurement. Index one is the reference.
   --  @param Result Completed multi-way comparison.
   --  @param Index Case index in enumeration order.
   --  @return Selected case measurement.
   --  @exception Constraint_Error If Index exceeds the measured case count.
   function Case_Measurement
     (Result : Multi_Comparison;
      Index  : Comparison_Case_Index) return Measurement;

   --  Return one case's paired comparison against case one.
   --  @param Result Completed multi-way comparison.
   --  @param Index Contender index in enumeration order.
   --  @return Selected paired comparison against the reference.
   --  @exception Constraint_Error If Index is one or exceeds the case count.
   function Versus_Reference
     (Result : Multi_Comparison;
      Index  : Comparison_Case_Index) return Comparison;

   generic
      --  Value type accepted by the barrier.
      type Element is private;
   --  Make a value visible to an opaque compiler barrier. Place this outside a
   --  timed nanosecond operation because the barrier is an out-of-line call.
   --  @param Value Input or output value that the optimizer must retain.
   procedure Do_Not_Optimize (Value : in out Element);

   --  Prevent memory operations from moving across this compiler barrier.
   procedure Clobber_Memory;

private
   type Custom_Name_Buffer is
     array (Positive range 1 .. Max_Custom_Metric_Name_Length) of Character;
   type Custom_Unit_Buffer is
     array (Positive range 1 .. Max_Custom_Metric_Unit_Length) of Character;
   type Timing_Source_Buffer is
     array (Positive range 1 .. Max_Timing_Source_Name_Length) of Character;

   type Custom_Metric_Descriptor is record
      Name_Length          : Natural range 0 .. Max_Custom_Metric_Name_Length := 0;
      Name_Data            : Custom_Name_Buffer := [others => ' '];
      Unit_Length          : Natural range 0 .. Max_Custom_Metric_Unit_Length := 0;
      Unit_Data            : Custom_Unit_Buffer := [others => ' '];
      Scope_Value          : Metric_Scope := Batch_Wall_Clock;
      Attribution_Value    : Metric_Attribution := Unattributable;
      Direction_Value      : Metric_Direction := Diagnostic;
      Semantics_Value      : Custom_Sample_Semantics := Cumulative_Delta;
      Normalization_Value  : Custom_Normalization := Per_Operation;
      Comparison_Value     : Custom_Comparison_Semantics := Relative_Positive;
      Primary_Timing_Value : Boolean := False;
      Timing_Length        : Natural range 0 .. Max_Timing_Source_Name_Length := 0;
      Timing_Data          : Timing_Source_Buffer := [others => ' '];
      Resolution_Value     : Long_Float := 0.0;
   end record;
   type Custom_Descriptor_Array is
     array (Custom_Metric_Index) of Custom_Metric_Descriptor;

   type Custom_Metric_Registry is record
      Count       : Custom_Metric_Count := 0;
      Descriptors : Custom_Descriptor_Array := [others => (others => <>)];
      Provider    : Custom_Probe := null;
   end record;

   Default_Configuration : constant Configuration := (others => <>);

   --  Shapes of one native probe reading. The runner, the recorder, and the
   --  probe layer all store readings in these, so a measurement boundary
   --  never converts between two spellings of the same snapshot.
   Resource_Value_Count : constant := 11;
   type Resource_Values is
     array (Natural range 0 .. Resource_Value_Count - 1)
       of Interfaces.Unsigned_64;

   Perf_Value_Count : constant := 5;
   type Perf_Values is
     array (Natural range 0 .. Perf_Value_Count - 1)
       of Interfaces.Unsigned_64;
   type Perf_Status_Values is
     array (Natural range 0 .. Perf_Value_Count - 1) of Metric_Availability;

   type Sample_Array is array (Sample_Index range <>) of Long_Float;
   type Boolean_Sample_Array is array (Sample_Index range <>) of Boolean;
   type Metric_Sample_Matrix is
     array (Metric_Axis, Sample_Index) of Long_Float;
   type Metric_Summary_Array is array (Metric_Axis) of Metric_Summary;
   type Metric_Comparison_Array is
     array (Metric_Axis) of Metric_Comparison_Result;
   type Metric_Availability_Array is
     array (Metric_Axis) of Metric_Availability;

   type Metric_Store is record
      References : Positive := 1;
      Requested  : Metric_Set := Time_Metrics;
      Available  : Metric_Set := [others => False];
      Status     : Metric_Availability_Array :=
        [others => Metric_Not_Requested];
      Values     : Metric_Sample_Matrix := [others => [others => 0.0]];
      Summaries  : Metric_Summary_Array := [others => (others => <>)];
   end record;
   type Metric_Store_Access is access Metric_Store;
   type Metric_Store_Handle is new Ada.Finalization.Controlled with record
      Data : Metric_Store_Access := null;
   end record;
   --  @exclude
   --  @param Object Internal shared store handle.
   overriding procedure Adjust (Object : in out Metric_Store_Handle);
   --  @exclude
   --  @param Object Internal shared store handle.
   overriding procedure Finalize (Object : in out Metric_Store_Handle);

   type Custom_Sample_Matrix is
     array (Custom_Metric_Index, Sample_Index) of Long_Float;
   type Custom_Status_Matrix is
     array (Custom_Metric_Index, Sample_Index) of Metric_Availability;
   type Custom_Summary_Array is
     array (Custom_Metric_Index) of Metric_Summary;
   type Custom_Comparison_Array is
     array (Custom_Metric_Index) of Metric_Comparison_Result;
   type Custom_Store is record
      References  : Positive := 1;
      Count       : Custom_Metric_Count := 0;
      Descriptors : Custom_Descriptor_Array := [others => (others => <>)];
      Status      : Custom_Status_Matrix :=
        [others => [others => Metric_Not_Requested]];
      Values      : Custom_Sample_Matrix := [others => [others => 0.0]];
      Summaries   : Custom_Summary_Array := [others => (others => <>)];
   end record;
   type Custom_Store_Access is access Custom_Store;
   type Custom_Store_Handle is new Ada.Finalization.Controlled with record
      Data : Custom_Store_Access := null;
   end record;
   --  @exclude
   --  @param Object Internal shared custom store handle.
   overriding procedure Adjust (Object : in out Custom_Store_Handle);
   --  @exclude
   --  @param Object Internal shared custom store handle.
   overriding procedure Finalize (Object : in out Custom_Store_Handle);

   type Measurement is record
      Sample_Total       : Sample_Count := Sample_Count'First;
      Iterations         : Iteration_Count := 1;
      Timer_Cost         : Long_Float := 0.0;
      Median_Timer_Cost  : Long_Float := 0.0;
      Clock_Resolution   : Long_Float := 0.0;
      Observed_Resolution : Long_Float := 0.0;
      Clock_Backend_Id   : Natural := 0;
      Median_Batch       : Long_Float := 0.0;
      Values             : Sample_Array (Sample_Index'Range) := [others => 0.0];
      Minimum            : Long_Float := 0.0;
      Maximum            : Long_Float := 0.0;
      Mean               : Long_Float := 0.0;
      Median             : Long_Float := 0.0;
      Standard_Deviation : Long_Float := 0.0;
      MAD                : Long_Float := 0.0;
      P95                : Long_Float := 0.0;
      P99                : Long_Float := 0.0;
      Confidence_Low     : Long_Float := 0.0;
      Confidence_High    : Long_Float := 0.0;
      CV_Percent         : Long_Float := 0.0;
      Outlier_Total      : Outlier_Counts;
      Lag_One            : Long_Float := 0.0;
      Confidence_Level_Value : Confidence_Percentage := 95.0;
      Bootstrap_Resample_Total : Bootstrap_Resample_Count := 2_000;
      Random_Seed_Value  : Long_Long_Integer := 1;
      Telemetry_Available : Boolean := False;
      Telemetry_CPU       : Sample_Array (Sample_Index'Range) :=
        [others => 0.0];
      Telemetry_RSS       : Sample_Array (Sample_Index'Range) :=
        [others => 0.0];
      Telemetry_RSS_Delta : Sample_Array (Sample_Index'Range) :=
        [others => 0.0];
      Telemetry_CPU_Total : Long_Float := 0.0;
      Telemetry_Wall_Total : Long_Float := 0.0;
      Telemetry_RSS_Start : Long_Float := 0.0;
      Telemetry_RSS_Final : Long_Float := 0.0;
      Telemetry_RSS_Peak  : Long_Float := 0.0;
      Telemetry_RSS_Change_Total : Long_Float := 0.0;
      Telemetry_RSS_Change_Peak : Long_Float := 0.0;
      Environment_Data    : Environment_Report;
      Foreign_CPU         : Sample_Array (Sample_Index'Range) :=
        (others => 0.0);
      Metric_Data         : Metric_Store_Handle;
      Custom_Data         : Custom_Store_Handle;
   end record;

   type Comparison is record
      Reference_Data       : Measurement;
      Contender_Data       : Measurement;
      Speedup_Values       : Sample_Array (Sample_Index'Range) :=
        [others => 0.0];
      Reference_First_Order : Boolean_Sample_Array (Sample_Index'Range) :=
        [others => False];
      Geometric_Speedup    : Long_Float := 1.0;
      Median_Speedup_Value : Long_Float := 1.0;
      Speedup_CI_Low       : Long_Float := 1.0;
      Speedup_CI_High      : Long_Float := 1.0;
      Mean_Time_Difference : Long_Float := 0.0;
      Contender_Win_Total  : Natural := 0;
      Reference_Win_Total  : Natural := 0;
      Tie_Total            : Natural := 0;
      Reference_First      : Natural := 0;
      Contender_First      : Natural := 0;
      Order_Effect         : Long_Float := 0.0;
      Lag_One              : Long_Float := 0.0;
      Practical_Threshold  : Long_Float := 1.0;
      Random_Seed_Value    : Long_Long_Integer := 1;
      Verdict_Value        : Comparison_Verdict := Inconclusive;
      Metric_Comparisons   : Metric_Comparison_Array :=
        [others => (others => <>)];
      Custom_Comparisons   : Custom_Comparison_Array :=
        [others => (others => <>)];
   end record;

   type Measurement_Case_Array is
     array (Comparison_Case_Index'Range) of Measurement;
   type Comparison_Case_Array is
     array (Comparison_Case_Index'Range) of Comparison;

   type Multi_Comparison is record
      Case_Total : Comparison_Case_Count := Comparison_Case_Count'First;
      Schedule_Policy : Shootout_Schedule_Policy := Balanced_Rounds;
      Batch_Policy : Comparison_Batch_Policy := Equal_Time;
      Data       : Measurement_Case_Array;
      Against_Reference : Comparison_Case_Array;
   end record;

   --  @exclude
   --  @param Value Internal measurement reconstructed from a worker envelope.
   --  @return True when raw samples reproduce every derived statistic.
   function Measurement_Statistics_Consistent
     (Value : Measurement) return Boolean;

   --  @exclude
   --  @param Value Internal comparison reconstructed from a worker envelope.
   --  @return True when paired samples reproduce every derived statistic.
   function Comparison_Statistics_Consistent
     (Value : Comparison) return Boolean;
end Flyology_Bench;
