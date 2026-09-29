--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Flyology;
with Interfaces.C;
with System.Flyology.Scheduler;

procedure Native_Lane_Lookup_Reproduction is
   package C renames Interfaces.C;
   package Scheduler renames System.Flyology.Scheduler;
   package TIO renames Ada.Text_IO;

   use type C.unsigned_long_long;

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

   subtype Ping_Number is Positive range 1 .. 10;
   type Count_Array is array (Ping_Number) of C.unsigned_long_long;

   Before : Count_Array;
   After  : Count_Array;

   procedure Measure (Phase : String; Counts : out Count_Array) is
      Previous : C.unsigned_long_long;
   begin
      Scheduler.Reset_Lane_Predicate_Lookups;
      Previous := Scheduler.Lane_Predicate_Lookups;
      TIO.Put_Line (Phase & " zero=" & Previous'Image);
      for Ping in Ping_Number loop
         Server.Ping;
         Counts (Ping) := Scheduler.Lane_Predicate_Lookups;
         TIO.Put_Line
           (Phase
            & " ping="
            & Ping'Image
            & " total="
            & Counts (Ping)'Image
            & " delta="
            & C.unsigned_long_long'Image (Counts (Ping) - Previous));
         if Counts (Ping) < Previous then
            raise Program_Error with "lane-predicate lookup count decreased";
         end if;
         Previous := Counts (Ping);
      end loop;
   end Measure;
begin
   Measure ("before_activation", Before);
   declare
      Idle : Idle_Lightweight;
   begin
      Idle.Ready;
      Measure ("after_activation", After);

      if (for some Count of Before => Count /= 0) then
         raise Program_Error with "native rendezvous looked up the registry before event activation";
      elsif After (After'First) = 0 or else After (After'Last) <= After (After'First) then
         raise Program_Error with "native rendezvous did not reproduce post-activation registry lookups";
      end if;
      Idle.Stop;
   end;
   Server.Stop;
end Native_Lane_Lookup_Reproduction;
