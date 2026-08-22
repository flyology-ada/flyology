--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Bench;
with Flyology_Bench.Scaling;
with Flyology_Bench.Sweeps;
with Flyology_Bench.Sweeps.Reporters;

--  Compare two in-place sorting implementations across the same ordered size
--  points. The output describes this run only; it makes no host performance
--  claim. Empirical scaling diagnostics summarize only the observed range.

procedure Sweep_Comparison is
   use type Flyology_Bench.Sweeps.Point_Status;

   package Sweeps renames Flyology_Bench.Sweeps;
   package Scaling renames Flyology_Bench.Scaling;
   package Reporters renames Flyology_Bench.Sweeps.Reporters;

   Maximum_Size : constant := 1_024;
   type Value_Array is array (Positive range 1 .. Maximum_Size) of Integer;

   Current_Size   : Positive := 64;
   Reference_Data : Value_Array;
   Contender_Data : Value_Array;

   procedure Prepare (Data : out Value_Array) is
   begin
      for Index in 1 .. Current_Size loop
         Data (Index) := Integer (Current_Size - Index + 1);
      end loop;
   end Prepare;

   procedure Insertion_Sort is
      Value    : Integer;
      Position : Natural;
   begin
      Prepare (Reference_Data);
      for Index in 2 .. Current_Size loop
         Value := Reference_Data (Index);
         Position := Index;
         while Position > 1 and then Reference_Data (Position - 1) > Value loop
            Reference_Data (Position) := Reference_Data (Position - 1);
            Position := Position - 1;
         end loop;
         Reference_Data (Position) := Value;
      end loop;
   end Insertion_Sort;

   procedure Shell_Sort is
      Gap      : Natural := Current_Size / 2;
      Value    : Integer;
      Position : Natural;
   begin
      Prepare (Contender_Data);
      while Gap > 0 loop
         for Index in Gap + 1 .. Current_Size loop
            Value := Contender_Data (Index);
            Position := Index;
            while Position > Gap and then Contender_Data (Position - Gap) > Value loop
               Contender_Data (Position) := Contender_Data (Position - Gap);
               Position := Position - Gap;
            end loop;
            Contender_Data (Position) := Value;
         end loop;
         Gap := Gap / 2;
      end loop;
   end Shell_Sort;

   procedure Choose_Size (Item : Sweeps.Parameter_Point) is
   begin
      Current_Size := Positive (Sweeps.Value (Item));
   end Choose_Size;

   function Work_For (Item : Sweeps.Parameter_Point) return Sweeps.Work_Amount
   is (Sweeps.Work (Sweeps.Value (Item), Sweeps.Items, Scaling => Sweeps.Decimal_Scaling));

   procedure Compare_Sorts is new
     Flyology_Bench.Compare (Reference_Operation => Insertion_Sort, Contender_Operation => Shell_Sort);

   procedure Run is new
     Sweeps.Compare_Sweep (Select_Point => Choose_Size, Work_For => Work_For, Run_Point => Compare_Sorts);

   Points                 : Sweeps.Point_Set (5);
   Results                : Sweeps.Paired_Sweep_Result (5);
   Insertion_Observations : Scaling.Observation_Set (5);
   Shell_Observations     : Scaling.Observation_Set (5);
   Config                 : constant Flyology_Bench.Configuration :=
     (Warmup_Time           => 0.010,
      Measurement_Time      => 0.100,
      Samples               => 20,
      Minimum_Sample_Time   => 0.000_050,
      Maximum_Sampling_Time => 0.500,
      others                => <>);
begin
   Points.Append (Sweeps.Point (Sweeps.Size_Parameter, 64, "64-items"));
   Points.Append (Sweeps.Point (Sweeps.Size_Parameter, 128, "128-items"));
   Points.Append (Sweeps.Point (Sweeps.Size_Parameter, 256, "256-items"));
   Points.Append (Sweeps.Point (Sweeps.Size_Parameter, 512, "512-items"));
   Points.Append (Sweeps.Point (Sweeps.Size_Parameter, 1_024, "1024-items"));

   Run
     (Case_Name => "sorting/in_place",
      Points    => Points,
      Config    => Config,
      Policy    =>
        (Failure => Sweeps.Stop_On_Point_Failure,
         Budget  => Sweeps.Per_Point_Budget,
         Mode    => Sweeps.Collect_Measurements),
      Result    => Results);

   Reporters.Put_Comparison_Console ("sorting/in_place", "insertion", "shell", Results);

   for Index in 1 .. Sweeps.Length (Results) loop
      declare
         Item : constant Sweeps.Paired_Point_Result := Sweeps.Element (Results, Index);
         Pair : constant Flyology_Bench.Comparison := Sweeps.Data (Item);
      begin
         if Sweeps.Status (Item) = Sweeps.Point_Measured then
            Insertion_Observations.Append
              (Sweeps.Parameter (Item),
               Flyology_Bench.Median_Nanoseconds (Flyology_Bench.Reference_Measurement (Pair)));
            Shell_Observations.Append
              (Sweeps.Parameter (Item),
               Flyology_Bench.Median_Nanoseconds (Flyology_Bench.Contender_Measurement (Pair)));
         end if;
      end;
   end loop;

   Reporters.Put_Scaling_Console ("sorting/in_place/insertion", Scaling.Analyze (Insertion_Observations));
   Reporters.Put_Scaling_Console ("sorting/in_place/shell", Scaling.Analyze (Shell_Observations));
end Sweep_Comparison;
