--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces.C;
with Flyology;
with Flyology.Debug_Producer_Selection;
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
--    poller_idle_cycle             a lightweight task suspending until its
--                                  event loop has nothing ready, so the loop
--                                  runs its whole idle path once per iteration
--    monotonic_clock_read          one platform monotonic reading, the unit of
--                                  work the loop's idle accounting adds
--    debug_selector_lightweight    automatic trace-shard selection on a
--                                  lightweight task
--    debug_selector_native         automatic trace-shard selection on a
--                                  native task
--
--  Run with no argument to print results. Pass "save <directory>" to persist
--  baselines and "check <directory>" to compare against them.

procedure Runtime_Callback_Bench is
   package Bench renames Flyology_Bench;

   type Callback_Access is access procedure;

   --  The loop's idle accounting is expressed in readings of this clock, so
   --  measuring the runtime's own primitive states the added cost directly
   --  rather than through a standard-library clock with a different
   --  platform implementation.
   type Timespec is record
      Seconds     : Interfaces.C.long;
      Nanoseconds : Interfaces.C.long;
   end record
   with Convention => C;

   function Monotonic_Clock (Value : access Timespec) return Interfaces.C.int;
   pragma Import (C, Monotonic_Clock, "flyology_monotonic_clock");

   --  Volatile so the escaping callback cannot be optimized away, which would
   --  remove the trampoline the benchmark exists to measure.
   Sink : Callback_Access := null;
   pragma Volatile (Sink);

   Observed : Natural := 0;
   pragma Volatile (Observed);

   Selected_Producer : Positive := 1;
   pragma Volatile (Selected_Producer);

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

   --  A positive delay leaves the event loop with nothing ready, so the loop
   --  takes its idle path: it stamps the wait, polls, and closes the wait.
   --  Yield_Now keeps the task runnable instead and never reaches that path.
   procedure Poller_Idle_Cycle is
   begin
      delay 0.000_000_001;
   end Poller_Idle_Cycle;

   Clock_Reading : aliased Timespec := (0, 0);
   Clock_Status  : Interfaces.C.int := 0;
   pragma Volatile (Clock_Status);

   procedure Monotonic_Clock_Read is
   begin
      Clock_Status := Monotonic_Clock (Clock_Reading'Access);
   end Monotonic_Clock_Read;

   procedure Select_Debug_Producer is
   begin
      Selected_Producer := Flyology.Debug_Producer_Selection.Choose (Producer_Count => 4);
   end Select_Debug_Producer;

   procedure Measure_Trampoline is new Bench.Measure (Trampoline_Cycle);
   procedure Measure_Dispatch is new Bench.Measure (Fiber_Dispatch);
   procedure Measure_Idle_Cycle is new Bench.Measure (Poller_Idle_Cycle);
   procedure Measure_Clock_Read is new Bench.Measure (Monotonic_Clock_Read);
   procedure Measure_Selection is new Bench.Measure (Select_Debug_Producer);

   Config : constant Bench.Configuration :=
     (Bench.Default_Configuration with delta Warmup_Time => 0.100, Measurement_Time => 0.750, Samples => 50);

   Lightweight_Trampoline : Bench.Measurement;
   Lightweight_Dispatch   : Bench.Measurement;
   Lightweight_Idle_Cycle : Bench.Measurement;
   Clock_Read             : Bench.Measurement;
   Lightweight_Selection  : Bench.Measurement;
   Native_Trampoline      : Bench.Measurement;
   Native_Selection       : Bench.Measurement;

   --  The environment task is native, so the lightweight measurements run in a
   --  task pinned to one execution group.
   task Lightweight_Probe
     with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Lightweight_Probe;

   task body Lightweight_Probe is
   begin
      Measure_Trampoline (Config => Config, Result => Lightweight_Trampoline);
      Measure_Dispatch (Config => Config, Result => Lightweight_Dispatch);
      Measure_Idle_Cycle (Config => Config, Result => Lightweight_Idle_Cycle);
      Measure_Selection (Config => Config, Result => Lightweight_Selection);
      if Selected_Producer /= 2 then
         raise Program_Error with "lightweight debug producer selector returned the wrong shard";
      end if;
   end Lightweight_Probe;

   type Case_Name is
     (Trampoline_Cycle_Lightweight,
      Trampoline_Cycle_Native,
      Fiber_Dispatch_Case,
      Poller_Idle_Cycle_Case,
      Monotonic_Clock_Read_Case,
      Debug_Selector_Lightweight,
      Debug_Selector_Native);

   function Label (Item : Case_Name) return String
   is (case Item is
         when Trampoline_Cycle_Lightweight => "trampoline_cycle_lightweight",
         when Trampoline_Cycle_Native      => "trampoline_cycle_native",
         when Fiber_Dispatch_Case          => "fiber_dispatch",
         when Poller_Idle_Cycle_Case       => "poller_idle_cycle",
         when Monotonic_Clock_Read_Case    => "monotonic_clock_read",
         when Debug_Selector_Lightweight   => "debug_selector_lightweight",
         when Debug_Selector_Native        => "debug_selector_native");

   function Result_Of (Item : Case_Name) return Bench.Measurement
   is (case Item is
         when Trampoline_Cycle_Lightweight => Lightweight_Trampoline,
         when Trampoline_Cycle_Native      => Native_Trampoline,
         when Fiber_Dispatch_Case          => Lightweight_Dispatch,
         when Poller_Idle_Cycle_Case       => Lightweight_Idle_Cycle,
         when Monotonic_Clock_Read_Case    => Clock_Read,
         when Debug_Selector_Lightweight   => Lightweight_Selection,
         when Debug_Selector_Native        => Native_Selection);

   Mode      : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1 then Ada.Command_Line.Argument (1) else "report");
   Directory : constant String :=
     (if Ada.Command_Line.Argument_Count >= 2 then Ada.Command_Line.Argument (2) else "");
   Regressed : Boolean := False;
begin
   --  Wait for the lightweight probe before measuring on this native task, so
   --  the two never contend for the same event loop.
   while not Lightweight_Probe'Terminated loop
      delay 0.005;
   end loop;
   Measure_Trampoline (Config => Config, Result => Native_Trampoline);
   Measure_Selection (Config => Config, Result => Native_Selection);
   Measure_Clock_Read (Config => Config, Result => Clock_Read);
   if Interfaces.C."/=" (Clock_Status, 0) then
      raise Program_Error with "monotonic clock read failed";
   end if;

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
            Saved  : constant Bench.Baselines.Baseline :=
              Bench.Baselines.Load (Directory & "/" & Label (Item) & ".baseline");
            Change : constant Bench.Baselines.Regression := Bench.Baselines.Compare (Saved, Result_Of (Item));
         begin
            Ada.Text_IO.Put_Line
              (Label (Item) & ": time change " & Bench.Baselines.Time_Change_Percent (Change)'Image & "%");
            if not Bench.Baselines.Compatible (Change) then
               Ada.Text_IO.Put_Line (Label (Item) & ": baseline host or build is incompatible");
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
