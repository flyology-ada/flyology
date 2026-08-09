--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Finalization;
with Interfaces;
with Interfaces.C;
with System;

--  Shared native measurement boundary for runner and recorder modes.
--  @exclude
package Flyology_Bench_Internal_Probes is
   use type Interfaces.Unsigned_64;
   use type Interfaces.C.int;

   --  @exclude
   function Native_Clock_Now
     (Value : access Interfaces.Unsigned_64) return Interfaces.C.int;
   pragma Import (C, Native_Clock_Now, "flyology_bench_clock_now");

   --  @exclude
   function Native_Clock_Resolution
     (Value : access Interfaces.Unsigned_64) return Interfaces.C.int;
   pragma Import
     (C, Native_Clock_Resolution, "flyology_bench_clock_resolution");

   --  @exclude
   function Native_Clock_Backend return Interfaces.C.int;
   pragma Import (C, Native_Clock_Backend, "flyology_bench_clock_backend");

   --  @exclude
   Resource_Value_Count : constant := 11;
   --  @exclude
   type Native_Resource_Values is
     array (Natural range 0 .. Resource_Value_Count - 1)
       of aliased Interfaces.Unsigned_64
     with Convention => C;

   --  @exclude
   function Native_Resource_Snapshot
     (Values         : System.Address;
      Capacity       : Interfaces.C.size_t;
      Available_Mask : access Interfaces.Unsigned_64)
      return Interfaces.C.int;
   pragma Import
     (C, Native_Resource_Snapshot, "flyology_bench_resource_snapshot");

   --  @exclude
   function Native_Thread_Id return Interfaces.Unsigned_64;
   pragma Import
     (C, Native_Thread_Id, "flyology_bench_native_thread_id");

   --  @exclude
   Perf_Value_Count : constant := 5;
   --  @exclude
   type Native_Perf_FDs is
     array (Natural range 0 .. Perf_Value_Count - 1) of Interfaces.C.int
     with Convention => C;
   --  @exclude
   type Native_Perf_Statuses is
     array (Natural range 0 .. Perf_Value_Count - 1) of Interfaces.C.int
     with Convention => C;
   --  @exclude
   type Native_Perf_Counters is
     array (Natural range 0 .. Perf_Value_Count - 1)
       of Interfaces.Unsigned_64
     with Convention => C;
   --  @exclude
   type Native_Perf_State is record
      FDs              : Native_Perf_FDs := (others => -1);
      Available_Mask   : Interfaces.Unsigned_64 := 0;
      Statuses         : Native_Perf_Statuses := (others => 0);
      IPC_Grouped      : Interfaces.C.int := 0;
      Baseline_Value   : Native_Perf_Counters := (others => 0);
      Baseline_Enabled : Native_Perf_Counters := (others => 0);
      Baseline_Running : Native_Perf_Counters := (others => 0);
   end record
     with Convention => C;
   --  @exclude
   type Native_Perf_Values is
     array (Natural range 0 .. Perf_Value_Count - 1)
       of aliased Interfaces.Unsigned_64
     with Convention => C;

   --  @exclude
   function Native_Perf_Initialize
     (State          : access Native_Perf_State;
      Requested_Mask : Interfaces.Unsigned_64) return Interfaces.C.int;
   pragma Import
     (C, Native_Perf_Initialize, "flyology_bench_perf_initialize");
   --  @exclude
   function Native_Perf_Start
     (State : access Native_Perf_State) return Interfaces.C.int;
   pragma Import (C, Native_Perf_Start, "flyology_bench_perf_start");
   --  @exclude
   function Native_Perf_Finish
     (State          : access Native_Perf_State;
      Values         : System.Address;
      Capacity       : Interfaces.C.size_t;
      Available_Mask : access Interfaces.Unsigned_64)
      return Interfaces.C.int;
   pragma Import (C, Native_Perf_Finish, "flyology_bench_perf_finish");
   --  @exclude
   procedure Native_Perf_Close (State : access Native_Perf_State);
   pragma Import (C, Native_Perf_Close, "flyology_bench_perf_close");

   --  @exclude
   type Perf_Handle is new Ada.Finalization.Limited_Controlled with record
      State       : aliased Native_Perf_State;
      Initialized : Boolean := False;
   end record;
   --  @exclude Internal descriptor cleanup hook.
   --  @param Object Internal counter handle.
   overriding procedure Finalize (Object : in out Perf_Handle);

   --  @exclude
   function Native_Recording_Perf_Start
     (Requested_Mask : Interfaces.Unsigned_64;
      Session        : access Interfaces.Unsigned_64) return Interfaces.C.int;
   pragma Import
     (C, Native_Recording_Perf_Start,
      "flyology_bench_recording_perf_start");
   --  @exclude
   procedure Native_Recording_Perf_Stop
     (Session : Interfaces.Unsigned_64);
   pragma Import
     (C, Native_Recording_Perf_Stop,
      "flyology_bench_recording_perf_stop");
   --  @exclude
   function Native_Recording_Perf_Snapshot
     (Session        : Interfaces.Unsigned_64;
      Values         : System.Address;
      Enabled        : System.Address;
      Running        : System.Address;
      Statuses       : System.Address;
      Capacity       : Interfaces.C.size_t;
      Available_Mask : access Interfaces.Unsigned_64) return Interfaces.C.int;
   pragma Import
     (C, Native_Recording_Perf_Snapshot,
      "flyology_bench_recording_perf_snapshot");

   --  @exclude
   function Clock_Now return Interfaces.Unsigned_64;
   --  @exclude
   function Mask_Has
     (Mask : Interfaces.Unsigned_64;
      Bit  : Natural) return Boolean;
   --  @exclude
   procedure Read_Resource_Snapshot
     (Values    : out Native_Resource_Values;
      Mask      : out Interfaces.Unsigned_64;
      Available : out Boolean);
end Flyology_Bench_Internal_Probes;
