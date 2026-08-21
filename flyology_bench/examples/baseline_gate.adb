--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Text_IO;
with Flyology_Bench;
with Flyology_Bench.Baselines;
with Flyology_Bench.Reporters;
with Interfaces;

procedure Baseline_Gate is
   package Baselines renames Flyology_Bench.Baselines;
   use type Interfaces.Unsigned_64;

   Usage : constant String :=
     "usage: baseline_gate (record|check) BASELINE_PATH";
   Benchmark_Name : constant String := "baseline_gate_example";
   Value : Interfaces.Unsigned_64 := 1 with Volatile;
   Inject_Regression : constant Boolean :=
     Ada.Environment_Variables.Value
       ("FLYOLOGY_BENCH_GATE_REGRESSION", Default => "0") = "1";

   procedure Work is
   begin
      Value := Value * 6_364_136_223_846_793_005
        + 1_442_695_040_888_963_407;
      if Inject_Regression then
         delay 0.001;
      end if;
   end Work;

   procedure Measure is new Flyology_Bench.Measure (Work);

   Config : constant Flyology_Bench.Configuration :=
     (Flyology_Bench.Default_Configuration with delta
        Warmup_Time           => 0.005,
        Measurement_Time      => 0.030,
        Maximum_Sampling_Time => 0.100,
        Samples               => 20,
        Minimum_Sample_Time   => 0.000_100,
        Metrics               => Flyology_Bench.Time_Metrics,
        Random_Seed           => 97);
   CI_Gate_Policy : constant Baselines.Gate_Policy :=
     (Baselines.Fail_Closed_Gate_Policy with delta
        On_Inconclusive => Baselines.Report_Only);
   Result : Flyology_Bench.Measurement;
begin
   if Ada.Command_Line.Argument_Count /= 2
     or else
       (Ada.Command_Line.Argument (1) /= "record"
        and then Ada.Command_Line.Argument (1) /= "check")
   then
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Usage);
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Measure (Config, Result);
   if Ada.Command_Line.Argument (1) = "record" then
      Baselines.Save
        (Ada.Command_Line.Argument (2), Benchmark_Name, Result);
      Ada.Text_IO.Put_Line
        ("recorded baseline " & Ada.Command_Line.Argument (2));
   else
      declare
         Gate : constant Baselines.Gate_Result :=
           Baselines.Evaluate_Gate
             (Ada.Command_Line.Argument (2),
              Benchmark_Name,
              Result,
              Policy => CI_Gate_Policy,
              Random_Seed => 97);
         Output : constant String :=
           Ada.Environment_Variables.Value
             ("FLYOLOGY_BENCH_OUTPUT", Default => "terminal");
      begin
         if Output = "terminal" then
            Flyology_Bench.Reporters.Put_Gate_Console (Gate);
         elsif Output = "csv" then
            Flyology_Bench.Reporters.Put_Gate_CSV_Header;
            Flyology_Bench.Reporters.Put_Gate_CSV (Gate);
         elsif Output = "json" then
            Flyology_Bench.Reporters.Put_Gate_JSON (Gate);
         else
            raise Constraint_Error with
              "FLYOLOGY_BENCH_OUTPUT must be terminal, csv, or json";
         end if;
         if Baselines.Rejected (Gate) then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end;
   end if;
end Baseline_Gate;
