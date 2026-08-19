--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Bench;
with Flyology_Bench.Reporters;
with Interfaces;
with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;

procedure Basic is
   use type Interfaces.Unsigned_32;
   use type Flyology_Bench.Iteration_Count;
   use type Flyology_Bench.Metric_Set;

   Reference_Value : Interfaces.Unsigned_32 := 1;
   Contender_Value : Interfaces.Unsigned_32 := 1;
   Third_Value : Interfaces.Unsigned_32 := 1;
   Noisy_Value : Interfaces.Unsigned_32 := 1;
   Memory_Value : Interfaces.Unsigned_32 := 1;

   type Mix_Case is
     (One_Mix, Two_Mixes, Three_Mixes, Noisy_One_Mix,
      Parallel_CPU_Burn, Memory_Hungry, Aggregated_Wait);

   subtype Worker_Slot is Positive range 1 .. 4;
   type Worker_Result_Array is array (Worker_Slot) of Interfaces.Unsigned_32
     with Volatile_Components;
   Worker_Results : Worker_Result_Array := (others => 1);

   Chunk_Bytes : constant := 2 * 1_024 * 1_024;
   Maximum_Retained_Bytes : constant := 128 * 1_024 * 1_024;
   type Byte_Array is array (Natural range 0 .. Chunk_Bytes - 1)
     of Interfaces.Unsigned_8;
   type Memory_Chunk;
   type Memory_Chunk_Access is access Memory_Chunk;
   type Memory_Chunk is record
      Data : Byte_Array;
      Next : Memory_Chunk_Access;
   end record;
   Retained_Chunks : Memory_Chunk_Access := null;
   Retained_Bytes : Natural := 0;

   procedure Keep is new
     Flyology_Bench.Do_Not_Optimize (Interfaces.Unsigned_32);

   procedure Integer_Mix is
   begin
      Reference_Value := Reference_Value * 1_664_525 + 1_013_904_223;
      if (Reference_Value and 16#0FFF_FFFF#) = 0 then
         --  Rare deterministic scheduler hiccup for the terminal demo.
         delay 0.008;
      end if;
   end Integer_Mix;

   procedure Integer_Mix_Contender is
   begin
      Contender_Value := Contender_Value * 1_664_525 + 1_013_904_223;
      if (Contender_Value and 16#0FFF_FFFF#) = 0 then
         delay 0.008;
      end if;
      --  A second mix makes the contender intentionally slower for the demo.
      Contender_Value := Contender_Value * 1_664_525 + 1_013_904_223;
   end Integer_Mix_Contender;

   procedure Integer_Mix_Third is
   begin
      for Round in 1 .. 3 loop
         Third_Value := Third_Value * 1_664_525 + 1_013_904_223;
      end loop;
      if (Third_Value and 16#0FFF_FFFF#) = 0 then
         delay 0.008;
      end if;
   end Integer_Mix_Third;

   procedure Integer_Mix_Noisy is
   begin
      Noisy_Value := Noisy_Value * 1_664_525 + 1_013_904_223;
      if (Noisy_Value and 16#03FF_FFFF#) = 0 then
         delay 0.012;
      end if;
   end Integer_Mix_Noisy;

   procedure Parallel_Batch
     (Iterations : Flyology_Bench.Iteration_Count)
   is
      task type Burner
        (Count : Flyology_Bench.Iteration_Count;
         Slot  : Worker_Slot);

      task body Burner is
         Value : Interfaces.Unsigned_32 := Worker_Results (Slot);
      begin
         for Iteration in Flyology_Bench.Iteration_Count range 1 .. Count loop
            Value := Value * 1_664_525 + 1_013_904_223;
         end loop;
         Worker_Results (Slot) := Value;
      end Burner;

      --  Four full streams make process CPU exceed one core while keeping the
      --  wall time per logical iteration comparable to the serial cases.
      Worker_1 : Burner (Iterations, 1);
      Worker_2 : Burner (Iterations, 2);
      Worker_3 : Burner (Iterations, 3);
      Worker_4 : Burner (Iterations, 4);
   begin
      null;
   end Parallel_Batch;

   procedure Memory_Batch
     (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      if Retained_Bytes < Maximum_Retained_Bytes then
         Retained_Chunks :=
           new Memory_Chunk'
             (Data =>
                (others => Interfaces.Unsigned_8 (Retained_Bytes mod 251)),
              Next => Retained_Chunks);
         Retained_Bytes := Retained_Bytes + Chunk_Bytes;
      end if;
      for Iteration in Flyology_Bench.Iteration_Count range 1 .. Iterations loop
         Memory_Value := Memory_Value * 1_664_525 + 1_013_904_223;
      end loop;
   end Memory_Batch;

   procedure Wait_Batch
     (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      --  Model two nanoseconds of elapsed waiting per logical operation while
      --  consuming almost no CPU in the aggregate wait.
      delay Duration (Long_Float (Iterations) * 2.0E-9);
   end Wait_Batch;

   procedure Run is new Flyology_Bench.Measure (Integer_Mix);

   procedure Mix_Batch
     (Which      : Mix_Case;
      Iterations : Flyology_Bench.Iteration_Count) is
   begin
      case Which is
         when One_Mix =>
            for Iteration in Flyology_Bench.Iteration_Count range 1 .. Iterations loop
               Integer_Mix;
            end loop;
         when Two_Mixes =>
            for Iteration in Flyology_Bench.Iteration_Count range 1 .. Iterations loop
               Integer_Mix_Contender;
            end loop;
         when Three_Mixes =>
            for Iteration in Flyology_Bench.Iteration_Count range 1 .. Iterations loop
               Integer_Mix_Third;
            end loop;
         when Noisy_One_Mix =>
            for Iteration in Flyology_Bench.Iteration_Count range 1 .. Iterations loop
               Integer_Mix_Noisy;
            end loop;
         when Parallel_CPU_Burn =>
            Parallel_Batch (Iterations);
         when Memory_Hungry =>
            Memory_Batch (Iterations);
         when Aggregated_Wait =>
            Wait_Batch (Iterations);
      end case;
   end Mix_Batch;

   procedure Compare_All is new Flyology_Bench.Compare_Many
     (Case_Id => Mix_Case, Batch => Mix_Batch);

   procedure Put_Table is new
     Flyology_Bench.Reporters.Put_Multi_Comparison_Console (Mix_Case);
   procedure Put_CSV is new
     Flyology_Bench.Reporters.Put_Multi_Comparison_CSV (Mix_Case);
   procedure Put_Metrics_CSV is new
     Flyology_Bench.Reporters.Put_Multi_Comparison_Metrics_CSV (Mix_Case);
   procedure Put_JSON is new
     Flyology_Bench.Reporters.Put_Multi_Comparison_JSON (Mix_Case);

   Usage : constant String :=
     "usage: basic [--metrics=all|--metrics=perf] "
     & "[--require-perf[=core|all]]";

   --  Which hardware axes a strict run insists on. All_Axes keeps the strong
   --  reading that every selected PMU axis must be collected. Core_Axes is
   --  the documented opt-out for a host whose PMU implements cycles and
   --  instructions but rejects a generic cache or branch event.
   type Perf_Requirement is (No_Requirement, Core_Axes, All_Axes);

   function Metrics_From_Arguments return Flyology_Bench.Metric_Set is
      Result : Flyology_Bench.Metric_Set :=
        Flyology_Bench.All_Builtin_Metrics;
   begin
      for Index in 1 .. Ada.Command_Line.Argument_Count loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Index);
         begin
            if Argument = "--metrics=perf" then
               Result := Flyology_Bench.Time_Metrics
                 or Flyology_Bench.Linux_Hardware_Metrics;
            elsif Argument = "--metrics=all"
              or else Argument = "--require-perf"
              or else Argument = "--require-perf=all"
              or else Argument = "--require-perf=core"
            then
               null;
            else
               raise Constraint_Error with Usage;
            end if;
         end;
      end loop;
      return Result;
   end Metrics_From_Arguments;

   function Requirement_From_Arguments return Perf_Requirement is
      Result : Perf_Requirement := No_Requirement;
   begin
      for Index in 1 .. Ada.Command_Line.Argument_Count loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Index);
         begin
            if Argument = "--require-perf"
              or else Argument = "--require-perf=all"
            then
               Result := All_Axes;
            elsif Argument = "--require-perf=core" then
               Result := Core_Axes;
            end if;
         end;
      end loop;
      return Result;
   end Requirement_From_Arguments;

   Result : Flyology_Bench.Measurement;
   Multi_Result : Flyology_Bench.Multi_Comparison;
   Output_Mode : constant String :=
     Ada.Environment_Variables.Value
       ("FLYOLOGY_BENCH_OUTPUT", Default => "terminal");
   Wait_For_Quiet_CPU : constant Boolean :=
     Ada.Environment_Variables.Value
       ("FLYOLOGY_BENCH_QUIESCENCE", Default => "0") = "1";
   Watch_Interference : constant Boolean :=
     Ada.Environment_Variables.Value
       ("FLYOLOGY_BENCH_INTERFERENCE", Default => "0") = "1";
   Selected_Metrics : constant Flyology_Bench.Metric_Set :=
     Metrics_From_Arguments;
   Require_Perf : constant Perf_Requirement := Requirement_From_Arguments;
   --  A policy's settings exist only while it is enabled, so a run-time
   --  switch selects between two aggregates rather than filling one in.
   --
   --  These belong inline in Single_Base_Config below, written as
   --  CPU_Quiescence => (if Wait_For_Quiet_CPU then (...) else (...)). That
   --  spelling aborts GNAT 15 and 16: a boxed aggregate inside a conditional
   --  expression inside an enclosing aggregate, for a type with a checked
   --  predicate. Hoisting them out moves the conditional out of the
   --  enclosing aggregate and compiles. See issue #55.
   Quiescence_Gate : constant Flyology_Bench.CPU_Quiescence_Policy :=
     (if Wait_For_Quiet_CPU
      then (Enabled                     => True,
            Maximum_Average_CPU_Percent => 20.0,
            Maximum_Core_CPU_Percent    => 50.0,
            Stable_Time                 => 0.500,
            Poll_Interval               => 0.100,
            Timeout                     => 10.0)
      else (Enabled => False));
   Interference_Watch : constant Flyology_Bench.Interference_Policy :=
     (if Watch_Interference
      then (Enabled  => True,
            Response => Flyology_Bench.Retake,
            others   => <>)
      else (Enabled => False, Response => Flyology_Bench.Observe));
   Single_Base_Config : constant Flyology_Bench.Configuration :=
     (Warmup_Time                  => 0.200,
      Measurement_Time             => 1.000,
      Maximum_Sampling_Time        => 1.500,
      Samples                      => 60,
      Minimum_Sample_Time          => 0.001,
      Maximum_Iterations           => Flyology_Bench.Iteration_Count'Last,
      Comparison_Batching          => Flyology_Bench.Equal_Time,
      Shootout_Scheduling          => Flyology_Bench.Balanced_Rounds,
      Subtract_Timer_Cost          => False,
      Practical_Threshold_Percent => 1.0,
      Random_Seed                  => 42,
      Metrics                      => Selected_Metrics,
      Scheduler_Probe              => null,
      CPU_Quiescence               => Quiescence_Gate,
      Interference                 => Interference_Watch,
      Placement                    => (others => <>),
      Host_Lock                    => (others => <>),
      Collect_Process_Telemetry    => False,
      Progress                     => null,
      Progress_Name                => <>);
   Multi_Base_Config : constant Flyology_Bench.Configuration :=
     (Single_Base_Config with delta
        Warmup_Time => 0.100,
        Measurement_Time => 3.000,
        Maximum_Sampling_Time => 2.000,
        Minimum_Sample_Time => 0.000_200,
        Shootout_Scheduling => Flyology_Bench.Sequential_Cases);
   Single_Config : constant Flyology_Bench.Configuration :=
     (if Output_Mode = "terminal"
      then Flyology_Bench.Reporters.Terminal_Mode
        (Single_Base_Config, "integer mix")
      else Single_Base_Config);
   Multi_Config : constant Flyology_Bench.Configuration :=
     (if Output_Mode = "terminal"
      then Flyology_Bench.Reporters.Terminal_Mode
        (Multi_Base_Config, "mix shootout")
      else Multi_Base_Config);
begin
   Keep (Reference_Value);
   Keep (Contender_Value);
   Keep (Third_Value);
   Keep (Noisy_Value);
   Keep (Memory_Value);
   for Slot in Worker_Slot loop
      Keep (Worker_Results (Slot));
   end loop;
   Run (Config => Single_Config, Result => Result);
   if Require_Perf /= No_Requirement then
      declare
         use type Ada.Strings.Unbounded.Unbounded_String;

         Last_Required : constant Flyology_Bench.Metric_Axis :=
           (if Require_Perf = Core_Axes
            then Flyology_Bench.Instructions_Per_Cycle
            else Flyology_Bench.Branch_Misses);
         Missing : Ada.Strings.Unbounded.Unbounded_String;
      begin
         for Axis in Flyology_Bench.CPU_Cycles .. Last_Required loop
            if Selected_Metrics (Axis)
              and then not Flyology_Bench.Metric_Available (Result, Axis)
            then
               if Missing /= Ada.Strings.Unbounded.Null_Unbounded_String then
                  Ada.Strings.Unbounded.Append (Missing, "; ");
               end if;
               Ada.Strings.Unbounded.Append
                 (Missing,
                  Flyology_Bench.Metric_Name (Axis) & " unavailable: "
                  & Flyology_Bench.Metric_Availability'Image
                      (Flyology_Bench.Metric_Status (Result, Axis)));
            end if;
         end loop;
         if Missing /= Ada.Strings.Unbounded.Null_Unbounded_String then
            raise Program_Error with
              (if Require_Perf = Core_Axes
               then "required core hardware metrics: "
               else "required hardware metrics: ")
              & Ada.Strings.Unbounded.To_String (Missing);
         end if;
      end;
   end if;
   if Output_Mode = "terminal" then
      Flyology_Bench.Reporters.Put_Console ("integer_mix", Result);
   end if;
   Compare_All (Config => Multi_Config, Result => Multi_Result);
   Keep (Reference_Value);
   Keep (Contender_Value);
   Keep (Third_Value);
   Keep (Noisy_Value);
   Keep (Memory_Value);
   for Slot in Worker_Slot loop
      Keep (Worker_Results (Slot));
   end loop;
   if Output_Mode = "terminal" then
      Put_Table (Multi_Result, Show_Individual_Details => True);
   elsif Output_Mode = "csv" then
      Flyology_Bench.Reporters.Put_Multi_Comparison_CSV_Header;
      Put_CSV (Multi_Result);
      Flyology_Bench.Reporters.Put_Comparison_Metrics_CSV_Header;
      Put_Metrics_CSV (Multi_Result);
   elsif Output_Mode = "json" then
      Put_JSON (Multi_Result);
   else
      raise Constraint_Error with
        "FLYOLOGY_BENCH_OUTPUT must be terminal, csv, or json";
   end if;
end Basic;
