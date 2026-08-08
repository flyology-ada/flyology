--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Strings.Unbounded;

--  Measures adaptive batches and paired comparisons of Ada operations.
package Flyology_Bench is
   --  Number of logical benchmark operations. Zero is useful for caller-owned
   --  counters; a measured batch always contains at least one iteration.
   type Iteration_Count is range 0 .. Long_Long_Integer'Last;

   --  Number of independently timed samples collected for one measurement.
   subtype Sample_Count is Positive range 10 .. 1_000;

   --  Index into the raw samples retained by a measurement.
   subtype Sample_Index is Positive range 1 .. Sample_Count'Last;

   --  Maximum number of implementations in one multi-way comparison.
   Max_Comparison_Cases : constant := 16;
   subtype Comparison_Case_Count is Positive range 2 .. Max_Comparison_Cases;
   subtype Comparison_Case_Index is Positive range 1 .. Max_Comparison_Cases;

   --  Stage reported by an optional progress callback. Callbacks execute only
   --  outside timed regions.
   type Progress_Phase is
     (Starting, Warming, Calibrating, Sampling, Analyzing, Finished);

   --  Receives coarse benchmark progress. Total is zero when a phase has no
   --  meaningful bounded work count.
   type Progress_Handler is access procedure
     (Name      : String;
      Phase     : Progress_Phase;
      Completed : Natural;
      Total     : Natural);

   --  Statistical and practical interpretation of a paired comparison.
   type Comparison_Verdict is
     (Inconclusive, Practically_Equivalent, Contender_Faster,
      Reference_Faster);

   --  Controls how comparison batches divide their wall-time budget.
   --  Equal_Time independently calibrates each implementation toward the same
   --  per-sample duration. Shared_Iterations uses one logical operation count
   --  for every implementation, so elapsed time varies with their speed.
   type Comparison_Batch_Policy is (Equal_Time, Shared_Iterations);

   --  Controls how Compare_Many orders implementation batches.
   --  Balanced_Rounds interleaves cases and rotates their positions.
   --  Sequential_Cases completes one case's sample block before the next.
   type Shootout_Schedule_Policy is (Balanced_Rounds, Sequential_Cases);

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
   --  @field Random_Seed Seed used for order shuffling and bootstrap sampling.
   --  @field Collect_Process_Telemetry Capture process CPU and RSS around each
   --  timed sample using untimed native probes. Terminal_Mode enables this.
   --  @field Progress Optional callback invoked outside timed regions.
   --  @field Progress_Name Human-readable identity passed to Progress. During
   --  Compare_Many sampling, the current case name follows this identity.
   type Configuration is record
      Warmup_Time          : Duration := 0.100;
      Measurement_Time     : Duration := 0.500;
      Maximum_Sampling_Time : Duration := 0.0;
      Samples              : Sample_Count := 50;
      Minimum_Sample_Time  : Duration := 0.000_100;
      Maximum_Iterations   : Iteration_Count := Iteration_Count'Last;
      Comparison_Batching  : Comparison_Batch_Policy := Equal_Time;
      Shootout_Scheduling  : Shootout_Schedule_Policy := Balanced_Rounds;
      Subtract_Timer_Cost  : Boolean := False;
      Practical_Threshold_Percent : Long_Float := 1.0;
      Random_Seed          : Long_Long_Integer := 1;
      Collect_Process_Telemetry : Boolean := False;
      Progress             : Progress_Handler := null;
      Progress_Name        : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
   end record;

   --  Default configuration for interactive microbenchmark runs.
   Default_Configuration : constant Configuration := (others => <>);

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
      with procedure Operation;
      --  One logical operation with observable inputs or output.
   --  Warm, calibrate, and measure one statically bound operation.
   --  @param Config Measurement policy.
   --  @param Result Collected raw samples and summary statistics.
   procedure Measure
     (Config : Configuration := Default_Configuration;
      Result : out Measurement);

   generic
      with procedure Batch (Iterations : Iteration_Count);
      --  Executes the requested logical operation count.
   --  Warm, calibrate, and measure a caller-controlled batch. The caller must
   --  perform exactly Iterations logical operations before returning.
   --  @param Config Measurement policy.
   --  @param Result Collected raw samples and summary statistics.
   procedure Measure_Batched
     (Config : Configuration := Default_Configuration;
      Result : out Measurement);

   generic
      with procedure Setup;
      --  Prepare one batch outside its timed region.
      with procedure Operation;
      --  One logical operation executed inside the timed region.
      with procedure Teardown;
      --  Consume or release batch state outside its timed region.
   --  Measure an operation with per-sample setup and teardown hooks. Teardown
   --  also runs when the measured operation raises, before the exception is
   --  propagated.
   --  @param Config Measurement policy.
   --  @param Result Collected raw samples and summary statistics.
   procedure Measure_With_Hooks
     (Config : Configuration := Default_Configuration;
      Result : out Measurement);

   generic
      type Element is private;
      --  Observable result produced by a batch.
      with procedure Batch
        (Iterations : Iteration_Count;
         Value      : out Element);
      --  Execute a batch and return a value that keeps its work observable.
   --  Measure a result-producing batch and pass its result to an opaque barrier
   --  after the ending timestamp. This avoids charging barrier cost to the
   --  measured operation.
   --  @param Config Measurement policy.
   --  @param Result Collected raw samples and summary statistics.
   procedure Measure_Result_Batched
     (Config : Configuration := Default_Configuration;
      Result : out Measurement);

   generic
      with procedure Reference_Operation;
      --  Existing or baseline operation.
      with procedure Contender_Operation;
      --  Operation compared with the reference.
   --  Measure two operations in adjacent, order-balanced sample pairs. Equal
   --  timed slices are the default; Shared_Iterations can require one count.
   --  @param Config Shared measurement policy.
   --  @param Result Paired measurements and relative statistics.
   procedure Compare
     (Config : Configuration := Default_Configuration;
      Result : out Comparison);

   generic
      with procedure Reference_Batch (Iterations : Iteration_Count);
      --  Executes a reference batch.
      with procedure Contender_Batch (Iterations : Iteration_Count);
      --  Executes a contender batch.
   --  Measure two caller-controlled batches in adjacent, order-balanced sample
   --  pairs. Each batch must perform exactly Iterations logical operations.
   --  @param Config Shared measurement policy.
   --  @param Result Paired measurements and relative statistics.
   procedure Compare_Batched
     (Config : Configuration := Default_Configuration;
      Result : out Comparison);

   generic
      type Case_Id is (<>);
      --  Enumeration of implementations; the first value is the reference.
      with procedure Batch
        (Which      : Case_Id;
         Iterations : Iteration_Count);
      --  Execute Iterations operations for the selected implementation.
   --  Compare two to sixteen implementations in shared rounds. Each case gets
   --  a comparable timed slice by default and occupies every execution
   --  position equally, or within one round when counts are indivisible.
   --  Sampling progress identifies each implementation separately.
   --  @param Config Shared measurement policy.
   --  @param Result Multi-way measurements and comparisons against case one.
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

   --  Return the reference side of a paired comparison.
   --  @param Result Completed comparison.
   --  @return Reference-side measurement using the shared sample schedule.
   function Reference_Measurement (Result : Comparison) return Measurement;

   --  Return the contender side of a paired comparison.
   --  @param Result Completed comparison.
   --  @return Contender-side measurement using the shared sample schedule.
   function Contender_Measurement (Result : Comparison) return Measurement;

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
      type Element is private;
      --  Value type accepted by the barrier.
   --  Make a value visible to an opaque compiler barrier. Place this outside a
   --  timed nanosecond operation because the barrier is an out-of-line call.
   --  @param Value Input or output value that the optimizer must retain.
   procedure Do_Not_Optimize (Value : in out Element);

   --  Prevent memory operations from moving across this compiler barrier.
   procedure Clobber_Memory;

private
   type Sample_Array is array (Sample_Index range <>) of Long_Float;
   type Boolean_Sample_Array is array (Sample_Index range <>) of Boolean;

   type Measurement is record
      Sample_Total       : Sample_Count := Sample_Count'First;
      Iterations         : Iteration_Count := 1;
      Timer_Cost         : Long_Float := 0.0;
      Median_Timer_Cost  : Long_Float := 0.0;
      Clock_Resolution   : Long_Float := 0.0;
      Observed_Resolution : Long_Float := 0.0;
      Clock_Backend_Id   : Natural := 0;
      Median_Batch       : Long_Float := 0.0;
      Values             : Sample_Array (Sample_Index'Range) := (others => 0.0);
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
      Random_Seed_Value  : Long_Long_Integer := 1;
      Telemetry_Available : Boolean := False;
      Telemetry_CPU       : Sample_Array (Sample_Index'Range) :=
        (others => 0.0);
      Telemetry_RSS       : Sample_Array (Sample_Index'Range) :=
        (others => 0.0);
      Telemetry_RSS_Delta : Sample_Array (Sample_Index'Range) :=
        (others => 0.0);
      Telemetry_CPU_Total : Long_Float := 0.0;
      Telemetry_Wall_Total : Long_Float := 0.0;
      Telemetry_RSS_Start : Long_Float := 0.0;
      Telemetry_RSS_Final : Long_Float := 0.0;
      Telemetry_RSS_Peak  : Long_Float := 0.0;
      Telemetry_RSS_Change_Total : Long_Float := 0.0;
      Telemetry_RSS_Change_Peak : Long_Float := 0.0;
   end record;

   type Comparison is record
      Reference_Data       : Measurement;
      Contender_Data       : Measurement;
      Speedup_Values       : Sample_Array (Sample_Index'Range) :=
        (others => 0.0);
      Reference_First_Order : Boolean_Sample_Array (Sample_Index'Range) :=
        (others => False);
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
end Flyology_Bench;
