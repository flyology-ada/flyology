--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;

package body Native_Rendezvous_Lane_Benchmark is
   package CLI renames Ada.Command_Line;
   package RT renames Ada.Real_Time;
   package TIO renames Ada.Text_IO;

   use type RT.Time;

   Default_Rounds : constant := 200_000;

   function Positive_Argument (Position : Positive; Default : Positive) return Positive is
   begin
      if CLI.Argument_Count < Position then
         return Default;
      end if;
      return Positive'Value (CLI.Argument (Position));
   exception
      when Constraint_Error =>
         raise Program_Error with "benchmark arguments must be positive integers";
   end Positive_Argument;

   function Rendezvous_Nanoseconds (Rounds : Positive) return Long_Long_Float is
      task Server is
         pragma Task_Info (Flyology.Native_Task);
         entry Ping;
         entry Stop;
      end Server;

      task body Server is
         Running : Boolean := True;
      begin
         while Running loop
            select
               accept Ping;
            or
               accept Stop do
                  Running := False;
               end Stop;
            end select;
         end loop;
      end Server;

      Started : RT.Time;
      Elapsed : Duration;
   begin
      Started := RT.Clock;
      for Iteration in 1 .. Rounds loop
         Server.Ping;
      end loop;
      Elapsed := RT.To_Duration (RT.Clock - Started);
      Server.Stop;
      return Long_Long_Float (Elapsed) * 1_000_000_000.0 / Long_Long_Float (Rounds);
   end Rendezvous_Nanoseconds;

   task type Idle_Lightweight is
      pragma Task_Info (Flyology.Lightweight_Task);
      entry Ready;
      entry Stop;
   end Idle_Lightweight;

   task body Idle_Lightweight is
   begin
      accept Ready;
      accept Stop;
   end Idle_Lightweight;

   procedure Measure
     (Mode          : String;
      Rounds        : Positive;
      Warmup_Rounds : Positive)
   is
      Ignored : Long_Long_Float;
      Result  : Long_Long_Float;
   begin
      delay 0.3;
      Ignored := Rendezvous_Nanoseconds (Warmup_Rounds);
      Result := Rendezvous_Nanoseconds (Rounds);
      TIO.Put_Line
        ("mode="
         & Mode
         & " rounds="
         & Rounds'Image
         & " warmup_rounds="
         & Warmup_Rounds'Image
         & " ns_per_rendezvous="
         & Long_Long_Float'Image (Result));
      if Ignored < 0.0 then
         raise Program_Error with "unreachable negative warmup timing";
      end if;
   end Measure;

   procedure Run (With_Idle_Lightweight : Boolean) is
      Rounds        : constant Positive := Positive_Argument (1, Default_Rounds);
      Warmup_Rounds : constant Positive := Positive_Argument (2, Default_Rounds);
   begin
      if With_Idle_Lightweight then
         declare
            Idle : Idle_Lightweight;
         begin
            Idle.Ready;
            Measure ("treatment", Rounds, Warmup_Rounds);
            Idle.Stop;
         end;
      else
         Measure ("control", Rounds, Warmup_Rounds);
      end if;
   end Run;
end Native_Rendezvous_Lane_Benchmark;
