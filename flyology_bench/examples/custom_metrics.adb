--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Bench;
with Flyology_Bench.Manual_Timing;
with Flyology_Bench.Reporters;

procedure Custom_Metrics is
   Requests : Long_Long_Integer := 0;
   Dummy : Long_Long_Integer := 0 with Volatile;

   procedure Probe (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
   begin
      Snapshot := [others => (Status => Flyology_Bench.Metric_Not_Requested,
                              others => <>)];
      Snapshot (1) :=
        (Status => Flyology_Bench.Metric_Collected,
         Counter_Value => Requests, Sample_Value => 0.0);
   end Probe;

   procedure Request_Batch (Iterations : Flyology_Bench.Iteration_Count) is
   begin
      for Index in 1 .. Iterations loop
         --  A domain-specific count need not match the logical operation
         --  count. Here each request performs three cache lookups.
         Requests := Requests + 3;
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
   end Request_Batch;
   procedure Measure_Requests is new
     Flyology_Bench.Measure_Batched (Request_Batch);

   procedure Fake_Timed_Batch
     (Iterations : Flyology_Bench.Iteration_Count;
      Elapsed : out Long_Float;
      Status : out Flyology_Bench.Metric_Availability) is
   begin
      for Index in 1 .. Iterations loop
         Dummy := Dummy + Long_Long_Integer (Index);
      end loop;
      --  This deterministic simulated clock demonstrates the contract only.
      --  A device adapter must synchronize completed work before returning.
      Elapsed := 12.0 * Long_Float (Iterations);
      Status := Flyology_Bench.Metric_Collected;
   end Fake_Timed_Batch;

   package Fake_Timer is new Flyology_Bench.Manual_Timing
     (Source_Name => "example_simulated_clock", Unit => "ticks/op",
      Resolution => 1.0, Scope => Flyology_Bench.Simulated_Clock,
      Attribution => Flyology_Bench.Unattributable,
      Batch => Fake_Timed_Batch);

   Config : Flyology_Bench.Configuration :=
     Flyology_Bench.Default_Configuration;
   Result : Flyology_Bench.Measurement;
begin
   Config.Warmup_Time := 0.001;
   Config.Measurement_Time := 0.010;
   Config.Samples := 10;
   Config.Minimum_Sample_Time := 0.000_010;
   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics, Name => "cache_lookups", Unit => "lookups/op",
      Scope => Flyology_Bench.Caller_Defined_Window,
      Attribution => Flyology_Bench.Shared_Process_Window,
      Direction => Flyology_Bench.Lower_Is_Better);
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Probe'Unrestricted_Access);
   Measure_Requests (Config, Result);
   Flyology_Bench.Reporters.Put_Console
     ("domain_counter", Result, Style => Flyology_Bench.Reporters.Plain);
   Flyology_Bench.Reporters.Put_Extended_Metrics_CSV_Header;
   Flyology_Bench.Reporters.Put_Extended_Metrics_CSV
     ("domain_counter", Result);

   Config := Flyology_Bench.Default_Configuration;
   Config.Warmup_Time := 0.001;
   Config.Measurement_Time := 0.010;
   Config.Samples := 10;
   Fake_Timer.Measure (Config, Result);
   Flyology_Bench.Reporters.Put_Metrics_NDJSON
     ("manual_simulated_timer", Result);
end Custom_Metrics;
