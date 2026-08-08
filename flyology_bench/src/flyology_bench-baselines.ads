--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Persists raw benchmark samples and compares compatible later runs.
package Flyology_Bench.Baselines is
   --  Samples and compatibility metadata loaded from a baseline file.
   type Baseline is private;

   --  Independent-run regression result. Direct Compare remains preferable
   --  when both implementations can run in the same process.
   type Regression is private;

   --  Save a measurement and all retained samples. Fingerprint should identify
   --  the host, CPU policy, toolchain, switches, and revision relevant to the
   --  caller's regression policy. Empty selects Metadata.Fingerprint. Newlines
   --  are rejected.
   --  @param Path Destination baseline path, replaced when it already exists.
   --  @param Name Stable benchmark name.
   --  @param Result Completed measurement.
   --  @param Fingerprint Caller-defined environment identity.
   procedure Save
     (Path        : String;
      Name        : String;
      Result      : Measurement;
      Fingerprint : String := "");

   --  Load a baseline written by Save.
   --  @param Path Existing baseline path.
   --  @return Parsed baseline and raw samples.
   function Load (Path : String) return Baseline;

   --  Compare a current run with an independently collected baseline using an
   --  independent percentile bootstrap of arithmetic-mean ratios.
   --  @param Saved Previously loaded baseline.
   --  @param Current Current compatible measurement.
   --  @param Fingerprint Current environment identity; empty selects the
   --  default metadata fingerprint.
   --  @param Practical_Threshold_Percent Smallest meaningful time change.
   --  @param Random_Seed Deterministic bootstrap seed.
   --  @return Compatibility, interval, change, and verdict.
   function Compare
     (Saved      : Baseline;
      Current    : Measurement;
      Fingerprint : String := "";
      Practical_Threshold_Percent : Long_Float := 1.0;
      Random_Seed : Long_Long_Integer := 1) return Regression;

   --  Return the name stored in a baseline.
   --  @param Saved Loaded baseline.
   --  @return Stored benchmark name.
   function Name (Saved : Baseline) return String;

   --  Return the caller-defined environment fingerprint.
   --  @param Saved Loaded baseline.
   --  @return Stored fingerprint, possibly empty.
   function Fingerprint (Saved : Baseline) return String;

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
   --  @return Lower 95% speedup bound.
   function Speedup_Confidence_Low (Result : Regression) return Long_Float;

   --  Return the upper endpoint of the independent bootstrap interval.
   --  @param Result Compatible regression result.
   --  @return Upper 95% speedup bound.
   function Speedup_Confidence_High (Result : Regression) return Long_Float;

   --  Return current time change relative to baseline. Negative is faster.
   --  @param Result Compatible regression result.
   --  @return Relative arithmetic-mean time change in percent.
   function Time_Change_Percent (Result : Regression) return Long_Float;

   --  Return the practical/statistical regression verdict.
   --  @param Result Regression result.
   --  @return Verdict, or Inconclusive when incompatible.
   function Verdict (Result : Regression) return Comparison_Verdict;

private
   type Stored_Sample_Array is array (Sample_Index'Range) of Long_Float;

   type Baseline is record
      Name_Length        : Natural := 0;
      Name_Data          : String (1 .. 256) := (others => ' ');
      Fingerprint_Length : Natural := 0;
      Fingerprint_Data   : String (1 .. 1_024) := (others => ' ');
      Backend_Id_Length  : Natural := 0;
      Backend_Id         : String (1 .. 64) := (others => ' ');
      Sample_Total       : Sample_Count := Sample_Count'First;
      Values             : Stored_Sample_Array := (others => 0.0);
   end record;

   type Regression is record
      Is_Compatible : Boolean := False;
      Speedup_Value : Long_Float := 1.0;
      CI_Low        : Long_Float := 1.0;
      CI_High       : Long_Float := 1.0;
      Verdict_Value : Comparison_Verdict := Inconclusive;
   end record;
end Flyology_Bench.Baselines;
