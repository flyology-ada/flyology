--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Strings.Unbounded;

--  Persists raw benchmark samples and gates compatible later runs.

package Flyology_Bench.Baselines is
   --  A baseline artifact is structurally invalid or uses an unsupported
   --  schema version.
   Baseline_Format_Error : exception;

   --  A baseline artifact could not be written, published, or read.
   Baseline_IO_Error : exception;

   --  Saved or current sample data cannot be compared within the numeric
   --  domain representable by the harness's clock and iteration counters.
   Baseline_Comparison_Error : exception;

   --  Require raises this exception when a gate result is rejected.
   Regression_Gate_Failure : exception;

   --  Samples and compatibility metadata loaded from a baseline file.
   type Baseline is private;

   --  Independent-run regression result. Direct Compare remains preferable
   --  when both implementations can run in the same process.
   type Regression is private;

   --  Save a measurement and all retained samples. Fingerprint should identify
   --  the host, CPU policy, toolchain, switches, and revision relevant to the
   --  caller's regression policy. Empty selects Metadata.Fingerprint. The
   --  implementation writes a checksummed versioned temporary artifact in the
   --  destination directory, flushes it, and atomically replaces Path.
   --  @param Path Destination baseline path, atomically replaced on success.
   --  @param Name Stable, nonempty benchmark name.
   --  @param Result Completed measurement.
   --  @param Fingerprint Caller-defined environment identity.
   --  @exception Constraint_Error A text field is empty, too long, or contains
   --  a newline or NUL byte.
   --  @exception Baseline_IO_Error The temporary file or atomic publication
   --  failed. An existing artifact remains unchanged before publication.
   procedure Save (Path : String; Name : String; Result : Measurement; Fingerprint : String := "");

   --  Load and validate a baseline written by Save. Version 2 validation
   --  includes required and duplicate fields, ranges, completeness, footer,
   --  and checksum. The earlier version 1 format remains readable so existing
   --  durable references can be checked, but new records always use version 2.
   --  @param Path Existing baseline path.
   --  @return Parsed baseline and raw samples.
   --  @exception Baseline_Format_Error The artifact is malformed, partial,
   --  corrupt, duplicated, out of range, or uses an unsupported version.
   function Load (Path : String) return Baseline;

   --  Compare a current run with an independently collected baseline using an
   --  independent circular-block bootstrap of arithmetic-mean ratios.
   --  @param Saved Previously loaded baseline.
   --  @param Current Current compatible measurement.
   --  @param Fingerprint Current environment identity; empty selects the
   --  default metadata fingerprint.
   --  @param Practical_Threshold_Percent Smallest meaningful time change.
   --  @param Random_Seed Deterministic bootstrap seed.
   --  @param Confidence_Level_Percent Central interval coverage in percent.
   --  @param Bootstrap_Resamples Number of bootstrap distributions to draw.
   --  @return Compatibility, interval, change, and verdict.
   --  @exception Constraint_Error Compatible samples request more than the
   --  bounded bootstrap analysis work.
   --  @exception Baseline_Comparison_Error Sample data cannot be compared
   --  within the supported numeric domain.
   function Compare
     (Saved                       : Baseline;
      Current                     : Measurement;
      Fingerprint                 : String := "";
      Practical_Threshold_Percent : Long_Float := 1.0;
      Random_Seed                 : Long_Long_Integer := 1;
      Confidence_Level_Percent    : Confidence_Percentage := 95.0;
      Bootstrap_Resamples         : Bootstrap_Resample_Count := 2_000) return Regression;

   --  Return the name stored in a baseline.
   --  @param Saved Loaded baseline.
   --  @return Stored benchmark name.
   function Name (Saved : Baseline) return String;

   --  Return the caller-defined environment fingerprint.
   --  @param Saved Loaded baseline.
   --  @return Stored fingerprint.
   function Fingerprint (Saved : Baseline) return String;

   --  Return the stored clock backend identity.
   --  @param Saved Loaded baseline.
   --  @return Exact clock backend identifier.
   function Clock_Backend (Saved : Baseline) return String;

   --  Return whether clock backend and environment fingerprint match.
   --  @param Result Regression result.
   --  @return True when comparing the runs is permitted.
   function Compatible (Result : Regression) return Boolean;

   --  Return baseline-time/current-time ratio. Greater than one is faster.
   --  @param Result Compatible regression result.
   --  @return Arithmetic-mean speedup.
   function Speedup (Result : Regression) return Long_Float;

   --  Return the lower endpoint of the independent bootstrap interval.
   --  @param Result Compatible regression result.
   --  @return Lower configured-confidence speedup bound.
   function Speedup_Confidence_Low (Result : Regression) return Long_Float;

   --  Return the upper endpoint of the independent bootstrap interval.
   --  @param Result Compatible regression result.
   --  @return Upper configured-confidence speedup bound.
   function Speedup_Confidence_High (Result : Regression) return Long_Float;

   --  Return current time change relative to baseline. Negative is faster.
   --  @param Result Compatible regression result.
   --  @return Relative arithmetic-mean time change in percent.
   function Time_Change_Percent (Result : Regression) return Long_Float;

   --  Return the lower endpoint of the current-time change interval.
   --  @param Result Compatible regression result.
   --  @return Lower time-change bound in percent; negative is faster.
   function Time_Change_Confidence_Low (Result : Regression) return Long_Float;

   --  Return the upper endpoint of the current-time change interval.
   --  @param Result Compatible regression result.
   --  @return Upper time-change bound in percent; negative is faster.
   function Time_Change_Confidence_High (Result : Regression) return Long_Float;

   --  Return the practical/statistical regression verdict. A regression is
   --  established only when the complete change interval is above the
   --  practical threshold.
   --  @param Result Regression result.
   --  @return Practical/statistical verdict.
   function Verdict (Result : Regression) return Comparison_Verdict;

   --  Whether a non-result condition is reported or rejects the gate.
   --  @enum Report_Only Preserve the status without rejecting the run.
   --  @enum Reject Reject the run.
   type Gate_Action is (Report_Only, Reject);

   --  Policy for a saved-baseline gate. An established Regression always
   --  rejects. Improvement and practical equivalence always pass.
   --  @field Practical_Threshold_Percent Smallest meaningful time change.
   --  @field On_Missing Action when Path does not exist.
   --  @field On_Invalid Action for malformed, corrupt, or unreadable artifacts
   --  and invalid current measurement data.
   --  @field On_Incompatible Action for exact identity, fingerprint, or clock
   --  incompatibility.
   --  @field On_Inconclusive Action when the confidence interval establishes
   --  neither a practical result nor a regression.
   type Gate_Policy is record
      Practical_Threshold_Percent : Threshold_Percentage := 1.0;
      On_Missing                  : Gate_Action := Report_Only;
      On_Invalid                  : Gate_Action := Report_Only;
      On_Incompatible             : Gate_Action := Report_Only;
      On_Inconclusive             : Gate_Action := Report_Only;
   end record;

   --  Interactive policy that reports exceptional states without rejection.
   Permissive_Gate_Policy : constant Gate_Policy := (others => <>);

   --  CI policy that rejects every exceptional state and inconclusive result.
   Fail_Closed_Gate_Policy : constant Gate_Policy :=
     (Practical_Threshold_Percent => 1.0,
      On_Missing                  => Reject,
      On_Invalid                  => Reject,
      On_Incompatible             => Reject,
      On_Inconclusive             => Reject);

   --  Complete status of one baseline gate evaluation.
   --  @enum Improvement Confidence interval establishes an improvement.
   --  @enum Practical_Equivalence Complete interval lies within the threshold.
   --  @enum Inconclusive Confidence interval establishes neither result.
   --  @enum Regressed Complete interval establishes a regression.
   --  @enum Missing_Baseline Path does not exist.
   --  @enum Incompatible_Baseline Exact identity, fingerprint, or clock differs.
   --  @enum Invalid_Baseline Artifact validation failed.
   --  @enum Baseline_Error Artifact I/O or current-measurement validation
   --  prevented comparison.
   type Gate_Status is
     (Improvement,
      Practical_Equivalence,
      Inconclusive,
      Regressed,
      Missing_Baseline,
      Incompatible_Baseline,
      Invalid_Baseline,
      Baseline_Error);

   --  Exact reason that a loaded baseline is incompatible.
   --  @enum No_Compatibility_Issue The result is not incompatible.
   --  @enum Benchmark_Identity_Mismatch Benchmark names differ.
   --  @enum Environment_Fingerprint_Mismatch Environment identities differ.
   --  @enum Clock_Backend_Mismatch Clock backend identities differ.
   type Compatibility_Issue is
     (No_Compatibility_Issue,
      Benchmark_Identity_Mismatch,
      Environment_Fingerprint_Mismatch,
      Clock_Backend_Mismatch);

   --  Policy decision and optional independent-run statistics for one gate.
   type Gate_Result is private;

   --  Load Path, require exact benchmark/environment identity, run the existing
   --  independent comparison, and apply Policy. This function never records or
   --  updates a baseline.
   --  @param Path Named baseline artifact.
   --  @param Current_Name Exact stable identity for Current.
   --  @param Current Current measurement.
   --  @param Fingerprint Exact current environment identity; empty selects the
   --  default metadata fingerprint.
   --  @param Policy Gate threshold and exceptional-state actions.
   --  @param Random_Seed Deterministic bootstrap seed.
   --  @param Confidence_Level_Percent Central interval coverage in percent.
   --  @param Bootstrap_Resamples Number of bootstrap distributions to draw.
   --  @return Status, decision, diagnostics, and optional statistics.
   --  @exception Constraint_Error Compatible samples request more than the
   --  bounded bootstrap analysis work.
   function Evaluate_Gate
     (Path                     : String;
      Current_Name             : String;
      Current                  : Measurement;
      Fingerprint              : String := "";
      Policy                   : Gate_Policy := Permissive_Gate_Policy;
      Random_Seed              : Long_Long_Integer := 1;
      Confidence_Level_Percent : Confidence_Percentage := 95.0;
      Bootstrap_Resamples      : Bootstrap_Resample_Count := 2_000) return Gate_Result;

   --  Raise Regression_Gate_Failure when Result is rejected.
   --  @param Result Completed gate evaluation.
   --  @exception Regression_Gate_Failure Result is rejected.
   procedure Require (Result : Gate_Result);

   --  Return the complete evaluation status.
   --  @param Result Completed gate evaluation.
   --  @return Distinct statistical or artifact status.
   function Status (Result : Gate_Result) return Gate_Status;

   --  Return a stable lowercase machine name for Status.
   --  @param Result Completed gate evaluation.
   --  @return Status name with underscores between words.
   function Status_Name (Result : Gate_Result) return String;

   --  Return whether policy rejects the result.
   --  @param Result Completed gate evaluation.
   --  @return True when CI should fail.
   function Rejected (Result : Gate_Result) return Boolean;

   --  Return whether an exact compatible comparison ran.
   --  @param Result Completed gate evaluation.
   --  @return True when benchmark identity, fingerprint, and clock match.
   function Compatible (Result : Gate_Result) return Boolean;

   --  Return the exact incompatibility reason.
   --  @param Result Completed gate evaluation.
   --  @return Compatibility issue, or No_Compatibility_Issue.
   function Compatibility (Result : Gate_Result) return Compatibility_Issue;

   --  Return whether speedup and confidence queries are available.
   --  @param Result Completed gate evaluation.
   --  @return True after a compatible independent comparison.
   function Has_Statistics (Result : Gate_Result) return Boolean;

   --  Return the loaded baseline identity, or empty when unavailable.
   --  @param Result Completed gate evaluation.
   --  @return Exact saved benchmark name.
   function Baseline_Name (Result : Gate_Result) return String;

   --  Return the exact current benchmark identity.
   --  @param Result Completed gate evaluation.
   --  @return Current benchmark name supplied to Evaluate_Gate.
   function Current_Name (Result : Gate_Result) return String;

   --  Return the evaluated artifact path.
   --  @param Result Completed gate evaluation.
   --  @return Path supplied to Evaluate_Gate.
   function Baseline_Path (Result : Gate_Result) return String;

   --  Return a human-readable decision diagnostic.
   --  @param Result Completed gate evaluation.
   --  @return Specific status reason.
   function Reason (Result : Gate_Result) return String;

   --  Return the configured practical threshold.
   --  @param Result Completed gate evaluation.
   --  @return Threshold in percent.
   function Practical_Threshold_Percent (Result : Gate_Result) return Long_Float;

   --  Return the stable name of the independent bootstrap method.
   --  @param Result Completed gate evaluation.
   --  @return Method name recorded for reproduction and machine output.
   function Bootstrap_Method (Result : Gate_Result) return String;

   --  Return the confidence level used by the independent bootstrap.
   --  @param Result Completed gate evaluation.
   --  @return Confidence level in percent.
   function Confidence_Level_Percent (Result : Gate_Result) return Long_Float;

   --  Return the number of bootstrap resamples used by the gate.
   --  @param Result Completed gate evaluation.
   --  @return Positive resample count.
   function Bootstrap_Resamples (Result : Gate_Result) return Positive;

   --  Return the deterministic bootstrap seed supplied to Evaluate_Gate.
   --  @param Result Completed gate evaluation.
   --  @return Exact signed seed.
   function Random_Seed (Result : Gate_Result) return Long_Long_Integer;

   --  Return baseline-time/current-time ratio.
   --  @param Result Gate result with statistics.
   --  @return Arithmetic-mean speedup.
   --  @exception Program_Error Has_Statistics is False.
   function Speedup (Result : Gate_Result) return Long_Float;

   --  Return the lower configured-confidence bootstrap speedup bound.
   --  @param Result Gate result with statistics.
   --  @return Lower speedup bound.
   --  @exception Program_Error Has_Statistics is False.
   function Speedup_Confidence_Low (Result : Gate_Result) return Long_Float;

   --  Return the upper configured-confidence bootstrap speedup bound.
   --  @param Result Gate result with statistics.
   --  @return Upper speedup bound.
   --  @exception Program_Error Has_Statistics is False.
   function Speedup_Confidence_High (Result : Gate_Result) return Long_Float;

   --  Return current time change relative to baseline.
   --  @param Result Gate result with statistics.
   --  @return Percent change; negative is faster.
   --  @exception Program_Error Has_Statistics is False.
   function Time_Change_Percent (Result : Gate_Result) return Long_Float;

   --  Return the lower endpoint of the current-time change interval.
   --  @param Result Gate result with statistics.
   --  @return Lower time-change bound in percent; negative is faster.
   --  @exception Program_Error Has_Statistics is False.
   function Time_Change_Confidence_Low (Result : Gate_Result) return Long_Float;

   --  Return the upper endpoint of the current-time change interval.
   --  @param Result Gate result with statistics.
   --  @return Upper time-change bound in percent; negative is faster.
   --  @exception Program_Error Has_Statistics is False.
   function Time_Change_Confidence_High (Result : Gate_Result) return Long_Float;

private
   package Strings renames Ada.Strings.Unbounded;

   type Stored_Sample_Array is array (Sample_Index'Range) of Long_Float;

   type Baseline is record
      Name_Length        : Natural := 0;
      Name_Data          : String (1 .. 256) := [others => ' '];
      Fingerprint_Length : Natural := 0;
      Fingerprint_Data   : String (1 .. 1_024) := [others => ' '];
      Backend_Id_Length  : Natural := 0;
      Backend_Id         : String (1 .. 64) := [others => ' '];
      Sample_Total       : Sample_Count := Sample_Count'First;
      Values             : Stored_Sample_Array := [others => 0.0];
   end record;

   type Regression is record
      Is_Compatible : Boolean := False;
      Speedup_Value : Long_Float := 1.0;
      CI_Low        : Long_Float := 1.0;
      CI_High       : Long_Float := 1.0;
      Verdict_Value : Comparison_Verdict := Inconclusive;
   end record;

   type Bootstrap_Method_Id is (Circular_Block_Mean_Ratio);

   type Gate_Result is record
      Status_Value             : Gate_Status := Baseline_Error;
      Rejected_Value           : Boolean := False;
      Compatible_Value         : Boolean := False;
      Issue_Value              : Compatibility_Issue := No_Compatibility_Issue;
      Statistics_Ready         : Boolean := False;
      Baseline_Name_Data       : Strings.Unbounded_String;
      Current_Name_Data        : Strings.Unbounded_String;
      Path_Data                : Strings.Unbounded_String;
      Reason_Data              : Strings.Unbounded_String;
      Threshold_Value          : Long_Float := 1.0;
      Bootstrap_Method_Value   : Bootstrap_Method_Id := Circular_Block_Mean_Ratio;
      Confidence_Level_Value   : Confidence_Percentage := 95.0;
      Bootstrap_Resample_Total : Bootstrap_Resample_Count := 2_000;
      Random_Seed_Value        : Long_Long_Integer := 1;
      Regression_Data          : Regression;
   end record;
end Flyology_Bench.Baselines;
