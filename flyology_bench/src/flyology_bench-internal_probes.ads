--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with System;

--  Shared native measurement boundary for runner and recorder modes.
--
--  Every decision made here -- which clock to read, how a counter reading
--  is scaled, which resource values a host can supply -- is Ada. The
--  crate's native unit publishes only header constants and the few entry
--  points that exist on one platform alone.
private package Flyology_Bench.Internal_Probes is

   type Host_System is (Darwin, Linux, Unknown_System);
   type Host_Architecture is (AArch64, X86_64, Unknown_Architecture);

   function Operating_System return Host_System;
   function Architecture return Host_Architecture;

   --  Identifies the monotonic source: 1 names Mach absolute time and 2
   --  names CLOCK_MONOTONIC_RAW. A measurement carries the value and
   --  reports it, so the numbering is part of that published shape.
   Mach_Clock_Backend : constant := 1;
   Monotonic_Raw_Backend : constant := 2;

   function Clock_Backend return Natural;

   function Clock_Now return Interfaces.Unsigned_64;

   --  Reads the same clock without raising when the host refuses.
   procedure Read_Clock
     (Nanoseconds : out Interfaces.Unsigned_64;
      Available   : out Boolean);

   procedure Read_Clock_Resolution
     (Nanoseconds : out Interfaces.Unsigned_64;
      Available   : out Boolean);

   function Native_Thread_Id return Interfaces.Unsigned_64;

   type Placement_Outcome is
     (Advisory_Placement, Strict_Placement, Placement_Refused);

   function Place_Current_Thread (CPU : Natural) return Placement_Outcome;

   procedure Read_Process_Usage
     (CPU_Nanoseconds : out Interfaces.Unsigned_64;
      Resident_Bytes  : out Interfaces.Unsigned_64;
      Available       : out Boolean);

   --  Positions within a resource snapshot. The recorder stores snapshots
   --  by index, so the numbering is fixed rather than incidental.
   Process_CPU_Index : constant := 0;
   Thread_CPU_Index : constant := 1;
   Resident_Bytes_Index : constant := 2;
   Minor_Faults_Index : constant := 3;
   Major_Faults_Index : constant := 4;
   Voluntary_Switches_Index : constant := 5;
   Involuntary_Switches_Index : constant := 6;
   Disk_Read_Bytes_Index : constant := 7;
   Disk_Written_Bytes_Index : constant := 8;
   Input_Operations_Index : constant := 9;
   Output_Operations_Index : constant := 10;

   procedure Read_Resource_Snapshot
     (Values    : out Resource_Values;
      Mask      : out Interfaces.Unsigned_64;
      Available : out Boolean);

   Maximum_Host_CPUs : constant := 1_024;
   type Host_CPU_Counters is
     array (Natural range 0 .. Maximum_Host_CPUs - 1)
       of Interfaces.Unsigned_64;

   procedure Read_Host_CPU
     (Busy      : out Host_CPU_Counters;
      Total     : out Host_CPU_Counters;
      CPU_Count : out Natural;
      Available : out Boolean);

   --  Optimization barriers. Neither is inlined, so a caller keeps the same
   --  opaque call the measured code saw before these moved out of C.
   procedure Escape (Value : System.Address);
   procedure Clobber_Memory;

   function Mask_Bit (Bit : Natural) return Interfaces.Unsigned_64;
   function Mask_Has
     (Mask : Interfaces.Unsigned_64;
      Bit  : Natural) return Boolean;

end Flyology_Bench.Internal_Probes;
