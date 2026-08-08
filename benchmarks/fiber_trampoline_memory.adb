--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces.C;
with Flyology;

--  Memory guard for the runtime's per-fiber trampoline cursor.
--
--  A fiber that creates a nested-subprogram callback owns the mapped page
--  behind it until the scheduler reaps the fiber, so committed memory scales
--  with the number of fibers holding callbacks rather than with the number of
--  event-loop threads. This program holds Count lightweight tasks suspended
--  with, or without, a live callback and reports the resident-set difference.
--
--  Usage: fiber_trampoline_memory [count] [with|without]
procedure Fiber_Trampoline_Memory is
   use type Interfaces.C.unsigned_long_long;

   function Resident_Bytes return Interfaces.C.unsigned_long_long;
   pragma Import (C, Resident_Bytes, "flyology_bench_resident_bytes");

   Count : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Positive'Value (Ada.Command_Line.Argument (1))
      else 512);

   Use_Callbacks : constant Boolean :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Ada.Command_Line.Argument (2) = "with"
      else True);

   type Callback_Access is access procedure;

   --  Volatile so an escaping callback survives optimization and really needs
   --  a trampoline.
   Sink : Callback_Access := null;
   pragma Volatile (Sink);
   Observed : Natural := 0;
   pragma Volatile (Observed);

   protected Gate is
      procedure Arrive;
      entry Await_All;
      procedure Release;
      entry Await_Release;
   private
      Arrived   : Natural := 0;
      Released  : Boolean := False;
   end Gate;

   protected body Gate is
      procedure Arrive is
      begin
         Arrived := Arrived + 1;
      end Arrive;

      entry Await_All when Arrived = Count is
      begin
         null;
      end Await_All;

      procedure Release is
      begin
         Released := True;
      end Release;

      entry Await_Release when Released is
      begin
         null;
      end Await_Release;
   end Gate;

   --  One shared execution group is the realistic worst case: every fiber
   --  holding a callback would otherwise have shared that thread's one page.
   task type Holder with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Holder;

   task body Holder is
      --  Suspending inside Hold keeps this fiber's trampoline live, which is
      --  exactly the state that pins a page to the fiber.
      procedure Hold is
         Value : Natural := 0;
         procedure Callback is
         begin
            Value := Value + 1;
            Observed := Value;
         end Callback;
      begin
         Sink := Callback'Unrestricted_Access;
         Gate.Arrive;
         Gate.Await_Release;
      end Hold;
   begin
      if Use_Callbacks then
         Hold;
      else
         Gate.Arrive;
         Gate.Await_Release;
      end if;
   end Holder;

   type Holder_Array is array (Positive range <>) of Holder;
   type Holder_Array_Access is access Holder_Array;

   Before   : Interfaces.C.unsigned_long_long;
   After    : Interfaces.C.unsigned_long_long;
   Holders  : Holder_Array_Access;
   Per_Task : Long_Float;
begin
   Before := Resident_Bytes;
   Holders := new Holder_Array (1 .. Count);
   Gate.Await_All;
   After := Resident_Bytes;
   Gate.Release;

   Per_Task :=
     Long_Float (After - Before) / Long_Float (Count);
   Ada.Text_IO.Put_Line
     ("fibers="
      & Count'Image
      & " callbacks="
      & (if Use_Callbacks then "with" else "without")
      & " resident_delta_bytes="
      & Interfaces.C.unsigned_long_long'Image (After - Before)
      & " bytes_per_fiber="
      & Long_Float'Image (Per_Task));
   pragma Unreferenced (Holders);
end Fiber_Trampoline_Memory;
