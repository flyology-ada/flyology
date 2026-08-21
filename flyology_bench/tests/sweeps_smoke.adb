--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Ada.Numerics.Long_Elementary_Functions;
with Ada.Strings.Unbounded;
with Flyology_Bench.Scaling;
with Flyology_Bench.Sweeps;
with Flyology_Bench.Sweeps.Reporters;

procedure Sweeps_Smoke is
   use type Flyology_Bench.Scaling.Scaling_Model;
   use type Flyology_Bench.Scaling.Scaling_Status;
   use type Flyology_Bench.Sweeps.Exact_Value;
   use type Flyology_Bench.Sweeps.Parameter_Kind;
   use type Flyology_Bench.Sweeps.Point_Status;
   use type Flyology_Bench.Sweeps.Throughput_Availability;
   use type Flyology_Bench.Sweeps.Work_Unit_Kind;

   package Sweeps renames Flyology_Bench.Sweeps;
   package Scaling renames Flyology_Bench.Scaling;
   package Reporters renames Flyology_Bench.Sweeps.Reporters;

   Current_Size : Natural := 1;
   State_A      : Long_Long_Integer := 1;
   State_B      : Long_Long_Integer := 1;
   Last_Progress_Name : Ada.Strings.Unbounded.Unbounded_String;

   procedure Observe_Progress
     (Name      : String;
      Phase     : Flyology_Bench.Progress_Phase;
      Completed : Natural;
      Total     : Natural)
   is
      pragma Unreferenced (Phase, Completed, Total);
   begin
      Last_Progress_Name := Ada.Strings.Unbounded.To_Unbounded_String (Name);
   end Observe_Progress;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   function Close
     (Left, Right : Long_Float;
      Relative    : Long_Float := 1.0E-12) return Boolean is
     (abs (Left - Right)
      <= Relative * Long_Float'Max (1.0, abs Right));

   procedure Choose_Point (Item : Sweeps.Parameter_Point) is
   begin
      Current_Size := Natural (Sweeps.Value (Item));
   end Choose_Point;

   procedure Operation_A is
   begin
      for Index in 1 .. Current_Size loop
         State_A := (State_A * 33 + Long_Long_Integer (Index)) mod 1_000_003;
      end loop;
   end Operation_A;

   procedure Operation_B is
   begin
      for Index in 1 .. Current_Size loop
         State_B := (State_B * 17 + Long_Long_Integer (Index) + 3) mod 1_000_033;
      end loop;
   end Operation_B;

   function Point_Work (Item : Sweeps.Parameter_Point) return Sweeps.Work_Amount is
     (Sweeps.Work
        (Sweeps.Value (Item), Sweeps.Items, Scaling => Sweeps.Decimal_Scaling));

   function Work_Maybe_Fail
     (Item : Sweeps.Parameter_Point) return Sweeps.Work_Amount is
   begin
      if Sweeps.Value (Item) = 2 then
         raise Program_Error with "work unavailable";
      end if;
      return Point_Work (Item);
   end Work_Maybe_Fail;

   procedure Measure_A is new Flyology_Bench.Measure (Operation_A);
   procedure Compare_AB is new Flyology_Bench.Compare
     (Reference_Operation => Operation_A,
      Contender_Operation => Operation_B);

   procedure Run_Ordinary is new Sweeps.Measure_Sweep
     (Select_Point => Choose_Point,
      Work_For     => Point_Work,
      Run_Point    => Measure_A);

   procedure Run_Paired is new Sweeps.Compare_Sweep
     (Select_Point => Choose_Point,
      Work_For     => Point_Work,
      Run_Point    => Compare_AB);

   procedure Select_Maybe_Fail (Item : Sweeps.Parameter_Point) is
   begin
      if Sweeps.Value (Item) = 2 then
         raise Program_Error with "bad, ""point""";
      end if;
      Choose_Point (Item);
   end Select_Maybe_Fail;

   procedure Run_Failing is new Sweeps.Measure_Sweep
     (Select_Point => Select_Maybe_Fail,
      Work_For     => Point_Work,
      Run_Point    => Measure_A);

   procedure Run_Work_Failing is new Sweeps.Measure_Sweep
     (Select_Point => Choose_Point,
      Work_For     => Work_Maybe_Fail,
      Run_Point    => Measure_A);

   procedure Select_Slow_First (Item : Sweeps.Parameter_Point) is
   begin
      if Sweeps.Value (Item) = 1 then
         delay 0.005;
      end if;
      Choose_Point (Item);
   end Select_Slow_First;

   procedure Run_Budgeted is new Sweeps.Measure_Sweep
     (Select_Point => Select_Slow_First,
      Work_For     => Point_Work,
      Run_Point    => Measure_A);

   Points : Sweeps.Point_Set (Maximum_Points => 3);
   Config : constant Flyology_Bench.Configuration :=
     (Warmup_Time             => 0.0,
      Measurement_Time        => 0.002,
      Maximum_Sampling_Time   => 0.050,
      Samples                 => 10,
      Minimum_Sample_Time     => 0.000_010,
      Maximum_Iterations      => 1_000_000,
      Progress                => Observe_Progress'Unrestricted_Access,
      others                  => <>);

   Ordinary : Sweeps.Ordinary_Sweep_Result (Maximum_Points => 3);
   Paired   : Sweeps.Paired_Sweep_Result (Maximum_Points => 3);
   Failure_Result : Sweeps.Ordinary_Sweep_Result (Maximum_Points => 3);
   Work_Failure_Result : Sweeps.Ordinary_Sweep_Result (Maximum_Points => 3);
   Dry_Result     : Sweeps.Ordinary_Sweep_Result (Maximum_Points => 3);

   procedure Expect_Constraint_Error
     (Action : not null access procedure;
      Name   : String)
   is
      Raised : Boolean := False;
   begin
      begin
         Action.all;
      exception
         when Constraint_Error =>
            Raised := True;
      end;
      Check (Raised, Name & " was accepted");
   end Expect_Constraint_Error;

begin
   Points.Append (Sweeps.Point (Sweeps.Count_Parameter, 1, "tiny"));
   Points.Append (Sweeps.Point (Sweeps.Count_Parameter, 2));
   Points.Append (Sweeps.Point (Sweeps.Count_Parameter, 4, "large"));
   Check (Points.Length = 3, "point length");
   Check (Sweeps.Identity (Points.Element (1)) = "count:1", "point identity");
   Check (Sweeps.Label (Points.Element (3)) = "large", "point label");
   Check
     (Sweeps.Value (Points.Element (2)) = 2,
      "explicit point ordering changed");

   declare
      procedure Duplicate is
      begin
         Points.Append (Sweeps.Point (Sweeps.Count_Parameter, 2, "duplicate"));
      end Duplicate;
      procedure Invalid_Label is
         Ignored : constant Sweeps.Parameter_Point :=
           Sweeps.Point (Sweeps.Size_Parameter, 8, "bad label");
         pragma Unreferenced (Ignored);
      begin
         null;
      end Invalid_Label;
   begin
      Expect_Constraint_Error (Duplicate'Access, "duplicate point");
      Expect_Constraint_Error (Invalid_Label'Access, "invalid point label");
   end;

   declare
      Items_Amount : constant Sweeps.Work_Amount :=
        Sweeps.Work (1_000.0, Sweeps.Items);
      Byte_Amount : constant Sweeps.Work_Amount :=
        Sweeps.Work
          (1_024.0, Sweeps.Bytes, Scaling => Sweeps.Binary_Scaling);
      Custom_Amount : constant Sweeps.Work_Amount :=
        Sweeps.Work (1_000_000.0, Sweeps.Caller_Named, "records");
      Rate : constant Sweeps.Throughput_Summary :=
        Sweeps.Derive_Throughput
          (Sweeps.Work (4.0, Sweeps.Items),
           Median_Nanoseconds      => 2.0,
           Mean_Confidence_Low_NS  => 1.0,
           Mean_Confidence_High_NS => 4.0);
   begin
      Check (Sweeps.Unit_Kind (Items_Amount) = Sweeps.Items, "items unit");
      Check (Sweeps.Display_Value (Items_Amount) = 1.0, "decimal display");
      Check (Sweeps.Display_Unit (Items_Amount) = "kitems", "decimal suffix");
      Check (Sweeps.Display_Value (Byte_Amount) = 1.0, "binary display");
      Check (Sweeps.Display_Unit (Byte_Amount) = "KiB", "binary suffix");
      Check (Sweeps.Display_Unit (Custom_Amount) = "Mrecords", "custom suffix");
      Check
        (Sweeps.Availability (Rate) = Sweeps.Throughput_Available,
         "synthetic throughput unavailable");
      Check
        (Close (Sweeps.Operations_Per_Second (Rate), 500_000_000.0),
         "operations/s derivation");
      Check
        (Close (Sweeps.Operations_Confidence_Low (Rate), 250_000_000.0),
         "inverted low rate bound");
      Check
        (Close (Sweeps.Operations_Confidence_High (Rate), 1_000_000_000.0),
         "inverted high rate bound");
      Check
        (Close (Sweeps.Work_Units_Per_Second (Rate), 2_000_000_000.0),
         "work/s derivation");
   end;

   declare
      procedure Zero_Work is
         Ignored : constant Sweeps.Work_Amount :=
           Sweeps.Work (0.0, Sweeps.Items);
         pragma Unreferenced (Ignored);
      begin
         null;
      end Zero_Work;
      procedure Negative_Work is
         Ignored : constant Sweeps.Work_Amount :=
           Sweeps.Work (-1.0, Sweeps.Items);
         pragma Unreferenced (Ignored);
      begin
         null;
      end Negative_Work;
      procedure Fractional_Work is
         Ignored : constant Sweeps.Work_Amount :=
           Sweeps.Work (1.5, Sweeps.Items);
         pragma Unreferenced (Ignored);
      begin
         null;
      end Fractional_Work;
      procedure Incoherent_Work is
         Ignored : constant Sweeps.Work_Amount :=
           Sweeps.Work (1.0, Sweeps.Bytes, "named");
         pragma Unreferenced (Ignored);
      begin
         null;
      end Incoherent_Work;
      procedure Invalid_Unit is
         Ignored : constant Sweeps.Work_Amount :=
           Sweeps.Work (1.0, Sweeps.Caller_Named, "bad unit");
         pragma Unreferenced (Ignored);
      begin
         null;
      end Invalid_Unit;
      procedure Overflowed_Work is
         Ignored : constant Sweeps.Work_Amount :=
           Sweeps.Work (Long_Float'Last, Sweeps.Items);
         pragma Unreferenced (Ignored);
      begin
         null;
      end Overflowed_Work;
      procedure Nonfinite_Work is
         Ignored : constant Sweeps.Work_Amount :=
           Sweeps.Work (Long_Float'Value ("NaN"), Sweeps.Items);
         pragma Unreferenced (Ignored);
      begin
         null;
      end Nonfinite_Work;
   begin
      Expect_Constraint_Error (Zero_Work'Access, "zero work");
      Expect_Constraint_Error (Negative_Work'Access, "negative work");
      Expect_Constraint_Error (Fractional_Work'Access, "fractional work");
      Expect_Constraint_Error (Incoherent_Work'Access, "incoherent work");
      Expect_Constraint_Error (Invalid_Unit'Access, "invalid custom unit");
      Expect_Constraint_Error (Overflowed_Work'Access, "overflowed work");
      Expect_Constraint_Error (Nonfinite_Work'Access, "non-finite work");
   end;

   declare
      Empty : Flyology_Bench.Measurement;
      Missing : constant Sweeps.Throughput_Summary :=
        Sweeps.Derive_Throughput
          (Sweeps.Work (1.0, Sweeps.Items), Empty);
      Overflow : constant Sweeps.Throughput_Summary :=
        Sweeps.Derive_Throughput
          (Sweeps.Work (Sweeps.Exact_Value'Last, Sweeps.Bytes),
           Long_Float'Model_Small,
           Long_Float'Model_Small,
           Long_Float'Model_Small);
   begin
      Check (not Sweeps.Available (Missing), "empty measurement became rate");
      Check
        (Sweeps.Availability (Overflow) = Sweeps.Throughput_Overflow,
         "rate overflow became available");
      Check
        (not Sweeps.Wall_Time_Available (Missing),
         "missing wall time became available");
      Check
        (Sweeps.Wall_Time_Available (Overflow),
         "valid wall summary was lost when work-rate arithmetic overflowed");
   end;

   Run_Ordinary
     (Case_Name => "algorithms/mix",
      Points    => Points,
      Config    => Config,
      Result    => Ordinary);
   Check (Sweeps.Length (Ordinary) = 3, "ordinary sweep length");
   Check
     (Ada.Strings.Unbounded.To_String (Last_Progress_Name)
      = "algorithms/mix/count:4",
      "progress lost exact case/point identity");
   for Index in 1 .. Sweeps.Length (Ordinary) loop
      declare
         Item : constant Sweeps.Ordinary_Point_Result :=
           Sweeps.Element (Ordinary, Index);
      begin
         Check (Sweeps.Status (Item) = Sweeps.Point_Measured, "ordinary point");
         Check (Sweeps.Work_Available (Item), "ordinary work unavailable");
         Check (Sweeps.Collection_Available (Item), "ordinary collection unavailable");
         Check (Sweeps.Available (Sweeps.Throughput (Item)), "ordinary rate");
         Check
           (Sweeps.Identity (Sweeps.Parameter (Item))
            = Sweeps.Identity (Points.Element (Index)),
            "ordinary point identity");
      end;
   end loop;

   Run_Paired
     (Case_Name => "algorithms/mix",
      Points    => Points,
      Config    => Config,
      Result    => Paired);
   Check (Sweeps.Length (Paired) = 3, "paired sweep length");
   for Index in 1 .. Sweeps.Length (Paired) loop
      declare
         Item : constant Sweeps.Paired_Point_Result :=
           Sweeps.Element (Paired, Index);
         Pair : constant Flyology_Bench.Comparison := Sweeps.Data (Item);
         Pair_Count : constant Natural :=
           Flyology_Bench.Reference_First_Samples (Pair)
           + Flyology_Bench.Contender_First_Samples (Pair);
      begin
         Check (Sweeps.Status (Item) = Sweeps.Point_Measured, "paired point");
         Check (Sweeps.Work_Available (Item), "paired work unavailable");
         Check (Sweeps.Collection_Available (Item), "paired collection unavailable");
         Check
           (Pair_Count
            = Natural
              (Flyology_Bench.Samples
                 (Flyology_Bench.Reference_Measurement (Pair))),
            "pairing missing at sweep point");
         Check
           (abs
              (Integer (Flyology_Bench.Reference_First_Samples (Pair))
               - Integer (Flyology_Bench.Contender_First_Samples (Pair))) <= 1,
            "point order was not balanced");
      end;
   end loop;

   declare
      Stop_Result : Sweeps.Ordinary_Sweep_Result (3);
   begin
      Run_Failing
        ("algorithms/failure",
         Points,
         Config,
         (Failure => Sweeps.Continue_After_Point_Failure, others => <>),
         Failure_Result);
      Check (Sweeps.Length (Failure_Result) = 3, "continue result length");
      Check
        (Sweeps.Status (Sweeps.Element (Failure_Result, 2))
         = Sweeps.Point_Setup_Failed,
         "setup failure status");
      Check
        (Sweeps.Work_Available (Sweeps.Element (Failure_Result, 2)),
         "selector failure lost established work");
      Check
        (not Sweeps.Collection_Available (Sweeps.Element (Failure_Result, 2)),
         "selector failure became collected");
      Check
        (Sweeps.Status (Sweeps.Element (Failure_Result, 3))
         = Sweeps.Point_Measured,
         "continue policy stopped");

      Run_Failing
        ("algorithms/failure",
         Points,
         Config,
         (Failure => Sweeps.Stop_On_Point_Failure, others => <>),
         Stop_Result);
      Check (Sweeps.Length (Stop_Result) = 2, "stop result length");
      Check (Sweeps.Stopped_Early (Stop_Result), "stop policy flag");

      Run_Work_Failing
        ("algorithms/work_failure",
         Points,
         Config,
         (Failure => Sweeps.Continue_After_Point_Failure, others => <>),
         Work_Failure_Result);
      Check
        (Sweeps.Status (Sweeps.Element (Work_Failure_Result, 2))
         = Sweeps.Point_Setup_Failed,
         "work failure status");
      Check
        (not Sweeps.Work_Available (Sweeps.Element (Work_Failure_Result, 2)),
         "failed work acquired a fabricated identity");
      declare
         procedure Read_Unavailable_Work is
            Ignored : constant Sweeps.Work_Amount :=
              Sweeps.Work_Per_Operation
                (Sweeps.Element (Work_Failure_Result, 2));
            pragma Unreferenced (Ignored);
         begin
            null;
         end Read_Unavailable_Work;
      begin
         Expect_Constraint_Error
           (Read_Unavailable_Work'Access, "unavailable point work accessor");
      end;
   end;

   declare
      Budget_Config : Flyology_Bench.Configuration := Config;
      Budget_Result : Sweeps.Ordinary_Sweep_Result (3);
   begin
      Budget_Config.Maximum_Sampling_Time := 0.001;
      Run_Budgeted
        ("algorithms/budget",
         Points,
         Budget_Config,
         (Failure => Sweeps.Continue_After_Point_Failure,
          Budget  => Sweeps.Whole_Sweep_Budget,
          Mode    => Sweeps.Collect_Measurements),
         Budget_Result);
      Check
        (Sweeps.Status (Sweeps.Element (Budget_Result, 2))
         = Sweeps.Point_Budget_Exhausted,
         "whole-sweep budget did not stop later point");
      Check
        (not Sweeps.Work_Available (Sweeps.Element (Budget_Result, 2)),
         "budget-skipped point acquired fabricated work");

      Run_Ordinary
        ("algorithms/dry",
         Points,
         Config,
         (Mode => Sweeps.Dry_Run, others => <>),
         Dry_Result);
      for Index in 1 .. Sweeps.Length (Dry_Result) loop
         Check
           (Sweeps.Status (Sweeps.Element (Dry_Result, Index))
            = Sweeps.Point_Dry_Run,
            "dry run became measured");
      end loop;
   end;

   declare
      Linear_Data    : Scaling.Observation_Set (5);
      Quadratic_Data : Scaling.Observation_Set (5);
      Constant_Data  : Scaling.Observation_Set (5);
      Bad_Data       : Scaling.Observation_Set (5);
      N_Log_N_Data   : Scaling.Observation_Set (5);
      Ambiguous_Data : Scaling.Observation_Set (4);
      Too_Short      : Scaling.Observation_Set (3);
      Degenerate     : Scaling.Observation_Set (4);
      Invalid        : Scaling.Observation_Set (4);
      Empty          : Scaling.Observation_Set (1);
      Mixed          : Scaling.Observation_Set (2);
   begin
      for Power in 0 .. 4 loop
         declare
            N : constant Sweeps.Exact_Value := 2 ** Power;
            P : constant Sweeps.Parameter_Point :=
              Sweeps.Point (Sweeps.Size_Parameter, N);
         begin
            Linear_Data.Append (P, 3.0 * Long_Float (N));
            Quadratic_Data.Append
              (P, 2.0 * Long_Float (N) * Long_Float (N));
            Constant_Data.Append (P, 7.0);
            Bad_Data.Append
              (P, (if Power mod 2 = 0 then 1.0 else 100.0));
            if Power < 3 then
               Too_Short.Append (P, Long_Float (N));
            end if;
            if Power < 4 then
               Invalid.Append
                 (P, (if Power = 2 then 0.0 else Long_Float (N)));
            end if;
         end;
      end loop;
      for Offset in 0 .. 3 loop
         Degenerate.Append
           (Sweeps.Point
              (Sweeps.Count_Parameter, Sweeps.Exact_Value (10 + Offset)),
            Long_Float (10 + Offset));
      end loop;
      for Power in 1 .. 5 loop
         declare
            N : constant Sweeps.Exact_Value := 2 ** Power;
            Input : constant Long_Float := Long_Float (N);
         begin
            N_Log_N_Data.Append
              (Sweeps.Point (Sweeps.Size_Parameter, N),
               5.0 * Input
               * Ada.Numerics.Long_Elementary_Functions.Log (Input));
         end;
      end loop;
      Mixed.Append (Sweeps.Point (Sweeps.Size_Parameter, 8), 8.0);
      declare
         procedure Append_Mixed_Kind is
         begin
            Mixed.Append (Sweeps.Point (Sweeps.Count_Parameter, 16), 16.0);
         end Append_Mixed_Kind;
      begin
         Expect_Constraint_Error
           (Append_Mixed_Kind'Access, "mixed scaling parameter kinds");
      end;
      declare
         Ambiguous_Inputs : constant array (Positive range 1 .. 4) of
           Sweeps.Exact_Value := [1_000, 1_200, 1_500, 2_000];
      begin
         for N of Ambiguous_Inputs loop
            declare
               Input : constant Long_Float := Long_Float (N);
            begin
               Ambiguous_Data.Append
                 (Sweeps.Point (Sweeps.Size_Parameter, N),
                  Input
                  * Ada.Numerics.Long_Elementary_Functions.Sqrt
                    (Ada.Numerics.Long_Elementary_Functions.Log (Input)));
            end;
         end loop;
      end;

      declare
         Linear_Fit : constant Scaling.Empirical_Scaling_Analysis :=
           Scaling.Analyze (Linear_Data);
         Quadratic_Fit : constant Scaling.Empirical_Scaling_Analysis :=
           Scaling.Analyze (Quadratic_Data);
         Constant_Fit : constant Scaling.Empirical_Scaling_Analysis :=
           Scaling.Analyze (Constant_Data);
         N_Log_N_Fit : constant Scaling.Empirical_Scaling_Analysis :=
           Scaling.Analyze (N_Log_N_Data);
         Ambiguous_Fit : constant Scaling.Empirical_Scaling_Analysis :=
           Scaling.Analyze (Ambiguous_Data);
         Bad_Fit : constant Scaling.Empirical_Scaling_Analysis :=
           Scaling.Analyze (Bad_Data);
         Empty_Fit : constant Scaling.Empirical_Scaling_Analysis :=
           Scaling.Analyze (Empty);
      begin
         Check (Scaling.Available (Linear_Fit), "linear fit unavailable");
         Check
           (Scaling.Selected_Model (Linear_Fit) = Scaling.Linear_Model,
            "linear model not selected");
         Check
           (Close
              (Scaling.Diagnostic
                 (Linear_Fit, Scaling.Linear_Model).Coefficient,
               3.0),
            "linear coefficient");
         Check (Scaling.Available (Quadratic_Fit), "quadratic fit unavailable");
         Check
           (Scaling.Selected_Model (Quadratic_Fit) = Scaling.Quadratic_Model,
            "quadratic model not selected");
         Check (Scaling.Available (Constant_Fit), "constant fit unavailable");
         Check
           (Scaling.Selected_Model (Constant_Fit) = Scaling.Constant_Model,
            "constant model not selected");
         Check (Scaling.Available (N_Log_N_Fit), "n log n fit unavailable");
         Check
           (Scaling.Selected_Model (N_Log_N_Fit) = Scaling.N_Log_N_Model,
            "n log n model not selected");
         Check
           (Scaling.Status (Ambiguous_Fit)
            = Scaling.Poor_Model_Identifiability,
            "poor model identifiability was accepted");
         Check
           (Scaling.Status (Bad_Fit) = Scaling.No_Adequate_Model,
            "inadequate data accepted");
         Check
           (Scaling.Status (Scaling.Analyze (Too_Short))
            = Scaling.Too_Few_Distinct_Points,
            "too few scaling points accepted");
         Check
           (Scaling.Input_Kind_Available (Scaling.Analyze (Too_Short))
            and then Scaling.Input_Kind (Scaling.Analyze (Too_Short))
              = Sweeps.Size_Parameter,
            "rejected scaling data lost its parameter kind");
         Check
           (Scaling.Input_Range_Available (Scaling.Analyze (Too_Short))
            and then Scaling.Minimum_Input (Scaling.Analyze (Too_Short)) = 1
            and then Scaling.Maximum_Input (Scaling.Analyze (Too_Short)) = 4,
            "rejected scaling data reported a false input range");
         Check
           (not Scaling.Input_Kind_Available (Empty_Fit)
            and then not Scaling.Input_Range_Available (Empty_Fit),
            "empty scaling data acquired sentinel input metadata");
         declare
            procedure Read_Empty_Range is
               Ignored : constant Sweeps.Exact_Value :=
                 Scaling.Minimum_Input (Empty_Fit);
               pragma Unreferenced (Ignored);
            begin
               null;
            end Read_Empty_Range;
         begin
            Expect_Constraint_Error
              (Read_Empty_Range'Access, "empty scaling range accessor");
         end;
         Check
           (Scaling.Status (Scaling.Analyze (Degenerate))
            = Scaling.Degenerate_Input_Range,
            "degenerate scaling range accepted");
         Check
           (Scaling.Status (Scaling.Analyze (Invalid))
            = Scaling.Invalid_Observation,
            "nonpositive scaling observation accepted");

         Ada.Text_IO.Put_Line ("-- sweep machine output begin --");
         Reporters.Put_CSV_Header;
         Reporters.Put_CSV ("group/case,""escaped""", Ordinary);
         Reporters.Put_CSV ("group/failure", Failure_Result);
         Reporters.Put_CSV ("group/work_failure", Work_Failure_Result);
         Reporters.Put_CSV ("group/dry", Dry_Result);
         Reporters.Put_Comparison_CSV_Header;
         Reporters.Put_Comparison_CSV
           ("group/case", "existing", "candidate", Paired);
         Reporters.Put_Scaling_CSV_Header;
         Reporters.Put_Scaling_CSV ("group/case", Linear_Fit);
         Reporters.Put_Scaling_CSV ("group/empty", Empty_Fit);
         Reporters.Put_NDJSON ("group/case,""escaped""", Ordinary);
         Reporters.Put_NDJSON ("group/failure", Failure_Result);
         Reporters.Put_NDJSON ("group/work_failure", Work_Failure_Result);
         Reporters.Put_NDJSON ("group/dry", Dry_Result);
         Reporters.Put_Comparison_NDJSON
           ("group/case", "existing", "candidate", Paired);
         Reporters.Put_Scaling_NDJSON ("group/case", Linear_Fit);
         Reporters.Put_Scaling_NDJSON ("group/empty", Empty_Fit);
         Ada.Text_IO.Put_Line ("-- sweep machine output end --");
      end;
   end;

   Ada.Text_IO.Put_Line ("flyology_bench sweeps smoke: PASS");
end Sweeps_Smoke;
