--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Text_IO;
with Flyology;
with Flyology.Fairness;
with Flyology_Bench;
with Flyology_Bench.Baselines;
with Flyology_Bench.Reporters;

--  Timing guard for the runtime's nested-subprogram trampoline handling.
--
--  Flyology gives each lightweight task its own trampoline allocation cursor
--  because GNAT's per-pthread cursor corrupts callbacks that outlive a fiber
--  suspension. These measurements keep that correctness fix honest about cost:
--
--    trampoline_cycle_lightweight  create and release one trampoline inside a
--                                  lightweight task, the rewritten path
--    trampoline_cycle_native       the same cycle on a native task, which must
--                                  keep the compiler's per-thread behaviour
--    fiber_dispatch                a lightweight task yielding to its event
--                                  loop and back, the scheduler's hottest loop
--
--  Run with no argument to print results. Pass "save <directory>" to persist
--  baselines and "check <directory>" to compare against them.
procedure Runtime_Callback_Bench is
   package Bench renames Flyology_Bench;

   type Callback_Access is access procedure;

   --  Volatile so the escaping callback cannot be optimized away, which would
   --  remove the trampoline the benchmark exists to measure.
   Sink : Callback_Access := null;
   pragma Volatile (Sink);

   Observed : Natural := 0;
   pragma Volatile (Observed);

   --  Entering this procedure creates a trampoline and returning releases it,
   --  because Callback reads and writes the frame that declares it.
   procedure Trampoline_Cycle is
      Value : Natural := Observed;
      procedure Callback is
      begin
         Value := Value + 1;
         Observed := Value;
      end Callback;
   begin
      Sink := Callback'Unrestricted_Access;
   end Trampoline_Cycle;

   procedure Fiber_Dispatch is
   begin
      Flyology.Fairness.Yield_Now;
   end Fiber_Dispatch;

   procedure Measure_Trampoline is new Bench.Measure (Trampoline_Cycle);
   procedure Measure_Dispatch is new Bench.Measure (Fiber_Dispatch);

   Config : constant Bench.Configuration :=
     (Bench.Default_Configuration with delta
        Warmup_Time      => 0.100,
        Measurement_Time => 0.750,
        Samples          => 50);

   Lightweight_Trampoline : Bench.Measurement;
   Lightweight_Dispatch   : Bench.Measurement;
   Native_Trampoline      : Bench.Measurement;

   --  The environment task is native, so the lightweight measurements run in a
   --  task pinned to one execution group.
   task Lightweight_Probe with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Lightweight_Probe;

   task body Lightweight_Probe is
   begin
      Measure_Trampoline (Config => Config, Result => Lightweight_Trampoline);
      Measure_Dispatch (Config => Config, Result => Lightweight_Dispatch);
   end Lightweight_Probe;

   type Case_Name is
     (Trampoline_Cycle_Lightweight, Trampoline_Cycle_Native, Fiber_Dispatch_Case);

   function Label (Item : Case_Name) return String is
     (case Item is
         when Trampoline_Cycle_Lightweight => "trampoline_cycle_lightweight",
         when Trampoline_Cycle_Native      => "trampoline_cycle_native",
         when Fiber_Dispatch_Case          => "fiber_dispatch");

   function Result_Of (Item : Case_Name) return Bench.Measurement is
     (case Item is
         when Trampoline_Cycle_Lightweight => Lightweight_Trampoline,
         when Trampoline_Cycle_Native      => Native_Trampoline,
         when Fiber_Dispatch_Case          => Lightweight_Dispatch);

   Mode      : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1)
      else "report");
   Directory : constant String :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Ada.Command_Line.Argument (2)
      else "");
   Regressed : Boolean := False;
begin
   --  Wait for the lightweight probe before measuring on this native task, so
   --  the two never contend for the same event loop.
   while not Lightweight_Probe'Terminated loop
      delay 0.005;
   end loop;
   Measure_Trampoline (Config => Config, Result => Native_Trampoline);

   for Item in Case_Name loop
      Flyology_Bench.Reporters.Put_Console (Label (Item), Result_Of (Item));
   end loop;

   if Mode = "save" then
      if Directory = "" then
         raise Constraint_Error with "save requires a baseline directory";
      end if;
      for Item in Case_Name loop
         Bench.Baselines.Save
           (Name   => Label (Item),
            Result => Result_Of (Item),
            Path   => Directory & "/" & Label (Item) & ".baseline");
      end loop;
      Ada.Text_IO.Put_Line ("baselines saved to " & Directory);
   elsif Mode = "check" then
      if Directory = "" then
         raise Constraint_Error with "check requires a baseline directory";
      end if;
      for Item in Case_Name loop
         declare
            Saved : constant Bench.Baselines.Baseline :=
              Bench.Baselines.Load
                (Directory & "/" & Label (Item) & ".baseline");
            Change : constant Bench.Baselines.Regression :=
              Bench.Baselines.Compare (Saved, Result_Of (Item));
         begin
            Ada.Text_IO.Put_Line
              (Label (Item)
               & ": time change "
               & Bench.Baselines.Time_Change_Percent (Change)'Image
               & "%");
            if not Bench.Baselines.Compatible (Change) then
               Ada.Text_IO.Put_Line
                 (Label (Item) & ": baseline host or build is incompatible");
            elsif Bench.Baselines.Time_Change_Percent (Change) > 10.0 then
               Ada.Text_IO.Put_Line (Label (Item) & ": REGRESSED");
               Regressed := True;
            end if;
         end;
      end loop;
      if Regressed then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   elsif Mode /= "report" then
      raise Constraint_Error with "mode must be report, save, or check";
   end if;
end Runtime_Callback_Bench;
