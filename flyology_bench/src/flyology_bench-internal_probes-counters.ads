--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Finalization;
with Interfaces.C;

--  Hardware counter groups opened through perf_event_open.
--
--  Linux is the only host that answers; elsewhere every requested counter
--  reports Unsupported_Platform and no descriptor is opened.
package Flyology_Bench.Internal_Probes.Counters is

   subtype Counter_Index is Natural range 0 .. Perf_Value_Count - 1;

   Cycles_Index : constant := 0;
   Instructions_Index : constant := 1;
   Cache_Misses_Index : constant := 2;
   Branches_Index : constant := 3;
   Branch_Misses_Index : constant := 4;

   type Group is limited private;

   --  Opens one descriptor per requested counter. Cycles and instructions
   --  join one counting group when both are requested and both open, so
   --  instructions per cycle is never formed from two differently bounded
   --  windows.
   procedure Open
     (Counters       : in out Group;
      Requested_Mask : Interfaces.Unsigned_64);

   --  Records a baseline for every open counter and then enables them.
   procedure Start (Counters : in out Group);

   --  Disables every open counter and reports each one's scaled delta
   --  against the baseline taken by Start.
   procedure Finish
     (Counters : in out Group;
      Result   : out Perf_Values;
      Mask     : out Interfaces.Unsigned_64);

   --  Reads every open counter without disabling it, together with the
   --  multiplexing time accounting a caller needs to scale a span.
   procedure Sample
     (Counters : in out Group;
      Result   : out Perf_Values;
      Enabled  : out Perf_Values;
      Running  : out Perf_Values;
      Status   : out Perf_Status_Values;
      Mask     : out Interfaces.Unsigned_64);

   procedure Close (Counters : in out Group);

   function Status
     (Counters : Group;
      Index    : Counter_Index) return Metric_Availability;

   --  Ties a group's descriptors to a scope, so an abandoned measurement
   --  cannot leave counters open.
   type Handle is new Ada.Finalization.Limited_Controlled with record
      Counters    : Group;
      Initialized : Boolean := False;
   end record;

   overriding procedure Finalize (Object : in out Handle);

private

   use type Interfaces.C.int;

   type Descriptors is array (Counter_Index) of Interfaces.C.int;

   --  Per-sample values are differences between a baseline captured while
   --  the counters are disabled and a reading taken after they are disabled
   --  again. PERF_EVENT_IOC_RESET cannot serve instead: it clears only the
   --  event's own count, never the inherited child count that an inheriting
   --  event accumulates, so a reset-and-read-absolute scheme reports counts
   --  that grow monotonically across samples once child tasks contribute.
   type Group is limited record
      Descriptor       : Descriptors := [others => -1];
      Mask             : Interfaces.Unsigned_64 := 0;
      Outcome          : Perf_Status_Values :=
        [others => Metric_Not_Requested];
      Grouped          : Boolean := False;
      Baseline_Value   : Perf_Values := [others => 0];
      Baseline_Enabled : Perf_Values := [others => 0];
      Baseline_Running : Perf_Values := [others => 0];
   end record;

end Flyology_Bench.Internal_Probes.Counters;
