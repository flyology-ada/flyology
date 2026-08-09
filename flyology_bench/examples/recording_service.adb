--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Environment_Variables;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology_Bench;
with Flyology_Bench.Recording;
with Flyology_Bench.Recording.Reporters;
with Interfaces;

--  A long-lived service owns the measured code and receives work through Ada
--  rendezvous. Client tasks drive it externally, so the benchmark runner
--  cannot surround a procedure call. Instrumentation instead marks the start
--  and finish of each request inside the service workers.
procedure Recording_Service is
   use type Interfaces.Unsigned_64;
   package Recording renames Flyology_Bench.Recording;
   package Reporters renames Flyology_Bench.Recording.Reporters;

   type Work_Kind is (Quick, CPU_Heavy, Memory_Burst, Wait_Bound);
   type Benchmark_Array is array (Work_Kind) of Recording.Benchmark;
   type Result_Array is array (Work_Kind) of Recording.Recorded_Measurement;

   Recorder : Recording.Recorder
     (Maximum_Benchmarks => Work_Kind'Pos (Work_Kind'Last) + 1,
      Retained_Samples   => 256);
   Benchmarks : Benchmark_Array;
   Results    : Result_Array;

   Accumulator : Interfaces.Unsigned_64 := 1 with Volatile;

   type Bytes is array (Positive range <>) of Interfaces.Unsigned_8;
   type Bytes_Access is access Bytes;
   procedure Free is new Ada.Unchecked_Deallocation (Bytes, Bytes_Access);

   task type Service_Worker is
      entry Submit (Kind : Work_Kind; Sequence : Positive);
      entry Shutdown;
   end Service_Worker;

   task body Service_Worker is
      Stopping : Boolean := False;
   begin
      while not Stopping loop
         select
            accept Submit (Kind : Work_Kind; Sequence : Positive) do
               declare
                  Sample  : Recording.Span;
                  Outcome : Recording.Sample_Outcome := Recording.Success;
                  Payload : Bytes_Access := null;
               begin
                  Recording.Begin_Sample
                    (Recorder, Benchmarks (Kind), Sample);
                  case Kind is
                     when Quick =>
                        Accumulator := Accumulator xor
                          Interfaces.Unsigned_64 (Sequence);
                     when CPU_Heavy =>
                        for Index in 1 .. 1_800_000 loop
                           Accumulator := Interfaces.Rotate_Left
                             (Accumulator xor Interfaces.Unsigned_64 (Index), 7);
                        end loop;
                     when Memory_Burst =>
                        Payload := new Bytes (1 .. 2 * 1_024 * 1_024);
                        for Page in 0 .. (Payload'Length / 4_096) - 1 loop
                           Payload (Payload'First + Page * 4_096) :=
                             Interfaces.Unsigned_8 (Sequence mod 256);
                        end loop;
                     when Wait_Bound =>
                        delay 0.018;
                  end case;

                  --  Deliberate, sparse hiccups make the live p95 and final
                  --  distribution visibly different from the median.
                  if Sequence mod 31 = 0 then
                     delay 0.045;
                  end if;
                  if Sequence mod 37 = 0 then
                     Outcome := Recording.Failure;
                  end if;
                  Recording.Finish (Sample, Outcome);
                  Free (Payload);
               end;
            end Submit;
         or
            accept Shutdown do
               Stopping := True;
            end Shutdown;
         end select;
      end loop;
   end Service_Worker;

   Workers : array (Positive range 1 .. 4) of Service_Worker;

   function Output_Mode return String is
     (if Ada.Environment_Variables.Exists
        ("FLYOLOGY_BENCH_RECORDING_OUTPUT")
      then Ada.Environment_Variables.Value
        ("FLYOLOGY_BENCH_RECORDING_OUTPUT")
      else "terminal");
begin
   Recording.Register (Recorder, "quick request", Benchmarks (Quick));
   Recording.Register (Recorder, "cpu-heavy request", Benchmarks (CPU_Heavy));
   Recording.Register
     (Recorder, "memory-burst request", Benchmarks (Memory_Burst));
   Recording.Register (Recorder, "wait-bound request", Benchmarks (Wait_Bound));

   Recording.Start
     (Recorder,
      (Metrics => Flyology_Bench.All_Builtin_Metrics,
       Retention => Recording.Reservoir,
       Random_Seed => 42,
       others => <>));
   if Output_Mode = "terminal" then
      Recording.Start_Live_Terminal
        (Recorder, Refresh_Interval => 0.100, ANSI => True);
   end if;

   --  These clients stand in for an external load generator. They decide when
   --  work arrives; the service workers decide where measurement begins and
   --  ends. Four workers allow spans to overlap.
   declare
      task type Client (Identity : Positive);
      task body Client is
         Kind : Work_Kind;
      begin
         for Sequence in 1 .. 48 loop
            Kind := Work_Kind'Val ((Sequence + Identity) mod 4);
            Workers (((Sequence + Identity) mod Workers'Length) + 1).Submit
              (Kind, Sequence + (Identity - 1) * 48);
         end loop;
      end Client;

      Client_1 : Client (1);
      Client_2 : Client (2);
      Client_3 : Client (3);
      Client_4 : Client (4);
      Client_5 : Client (5);
      Client_6 : Client (6);
      Client_7 : Client (7);
      Client_8 : Client (8);
   begin
      null;
   end;

   Recording.Stop (Recorder);
   if Output_Mode = "terminal" then
      Recording.Stop_Live_Terminal (Recorder);
   end if;
   for Worker of Workers loop
      Worker.Shutdown;
   end loop;
   for Kind in Work_Kind loop
      Recording.Snapshot (Recorder, Benchmarks (Kind), Results (Kind));
   end loop;

   if Output_Mode = "csv" then
      Reporters.Put_CSV_Header;
      for Kind in Work_Kind loop
         Reporters.Put_CSV (Results (Kind));
      end loop;
   elsif Output_Mode = "json" then
      for Kind in Work_Kind loop
         Reporters.Put_JSON (Results (Kind));
      end loop;
   else
      Ada.Text_IO.Put_Line
        ("Final snapshots (process-scoped axes can include overlapping work):");
      for Kind in Work_Kind loop
         Reporters.Put_Console (Results (Kind));
         Ada.Text_IO.New_Line;
      end loop;
      for Kind in Work_Kind'Succ (Work_Kind'First) .. Work_Kind'Last loop
         declare
            Compared : Recording.Recorded_Comparison;
         begin
            Recording.Compare_Independent
              (Results (Work_Kind'First), Results (Kind), Compared,
               Random_Seed => 42);
            Reporters.Put_Comparison_Console (Compared);
         end;
      end loop;
   end if;
end Recording_Service;
