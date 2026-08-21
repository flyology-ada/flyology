--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology_Bench;
with Flyology_Bench.Workers;

procedure Fresh_Process is
   package W renames Flyology_Bench.Workers;
   package US renames Ada.Strings.Unbounded;
   use type W.Worker_Outcome;

   Counter : Natural := 0 with Volatile;

   procedure Increment is
   begin
      Counter := Counter + 1;
   end Increment;

   procedure Benchmark is new Flyology_Bench.Measure (Increment);

   Config : constant Flyology_Bench.Configuration :=
     (Flyology_Bench.Default_Configuration with delta
        Warmup_Time      => 0.010,
        Measurement_Time => 0.050,
        Samples          => Flyology_Bench.Sample_Count'First,
        Random_Seed      => 2026);
begin
   if W.Worker_Mode then
      declare
         Request : W.Worker_Request;
      begin
         Request := W.Current_Request;
         W.Announce_Ready (Request);
         declare
            Result : Flyology_Bench.Measurement;
         begin
            Benchmark (W.Requested_Configuration (Request), Result);
            W.Return_Result (Request, Result);
         end;
      exception
         when Error : others =>
            W.Return_Benchmark_Exception
              (Request,
               Ada.Exceptions.Exception_Name (Error),
               Ada.Exceptions.Exception_Message (Error));
      end;
      return;
   end if;

   declare
      In_Process : Flyology_Bench.Measurement;
      Fresh : W.Worker_Result_Array (1 .. 2);
      Launch : constant W.Launch_Configuration :=
        (Repetitions          => 2,
         Startup_Timeout      => 2.0,
         Total_Timeout        => 10.0,
         Termination_Grace    => 0.100,
         Diagnostic_Capacity  => 8_192,
         Directory            => W.Inherit_Directory,
         Working_Directory    => US.Null_Unbounded_String);
      Env : constant W.Environment := W.Create_Environment;
   begin
      Benchmark (Config, In_Process);
      Ada.Text_IO.Put_Line
        ("in-process median ns:"
         & Long_Float'Image
             (Flyology_Bench.Median_Nanoseconds (In_Process)));

      W.Run
        (Ada.Command_Line.Command_Name, "increment",
         W.Ordinary_Measurement, Config, Launch, Env, Fresh);
      for Result of Fresh loop
         if W.Outcome (Result) = W.Normal_Result then
            Ada.Text_IO.Put_Line
              ("fresh worker" & Positive'Image (W.Repetition (Result))
               & " seed" & Long_Long_Integer'Image (W.Seed (Result))
               & " median ns:"
               & Long_Float'Image
                   (Flyology_Bench.Median_Nanoseconds
                      (W.Measurement_Value (Result)))
               & " spawn ns:" & Long_Float'Image (W.Spawn_Nanoseconds (Result))
               & " setup ns:" & Long_Float'Image (W.Setup_Nanoseconds (Result)));
         else
            Ada.Text_IO.Put_Line
              ("fresh worker failed: " & W.Reason (Result));
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         end if;
      end loop;
   end;
end Fresh_Process;
