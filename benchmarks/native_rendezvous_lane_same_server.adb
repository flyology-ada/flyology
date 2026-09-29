--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;

procedure Native_Rendezvous_Lane_Same_Server is
   package CLI renames Ada.Command_Line;
   package RT renames Ada.Real_Time;
   package TIO renames Ada.Text_IO;

   use type RT.Time;

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

   Rounds        : constant Positive := Positive_Argument (1, 800_000);
   Warmup_Rounds : constant Positive := Positive_Argument (2, 300_000);

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

   function Measure (Count : Positive) return Long_Long_Float is
      Started : constant RT.Time := RT.Clock;
   begin
      for Iteration in 1 .. Count loop
         Server.Ping;
      end loop;
      return
        Long_Long_Float (RT.To_Duration (RT.Clock - Started))
        * 1_000_000_000.0
        / Long_Long_Float (Count);
   end Measure;

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

   Ignored : Long_Long_Float;
   Before  : Long_Long_Float;
   After   : Long_Long_Float;
begin
   delay 0.3;
   Ignored := Measure (Warmup_Rounds);
   Before := Measure (Rounds);
   declare
      Idle : Idle_Lightweight;
   begin
      Idle.Ready;
      delay 0.3;
      Ignored := Measure (Warmup_Rounds);
      After := Measure (Rounds);
      Idle.Stop;
   end;
   Server.Stop;
   TIO.Put_Line
     ("rounds="
      & Rounds'Image
      & " warmup_rounds="
      & Warmup_Rounds'Image
      & " before_ns="
      & Long_Long_Float'Image (Before)
      & " after_ns="
      & Long_Long_Float'Image (After)
      & " ratio="
      & Long_Long_Float'Image (After / Before));
   if Ignored < 0.0 then
      raise Program_Error with "unreachable negative warmup timing";
   end if;
end Native_Rendezvous_Lane_Same_Server;
