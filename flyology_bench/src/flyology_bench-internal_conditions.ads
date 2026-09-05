--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

private package Flyology_Bench.Internal_Conditions is

   Maximum_Throttle_Sources : constant := 2 * 1_024;
   subtype Throttle_Source_Index is Positive range 1 .. Maximum_Throttle_Sources;
   type Throttle_Key_Array is array (Throttle_Source_Index) of Interfaces.Unsigned_16;
   type Throttle_Flag_Array is array (Throttle_Source_Index) of Interfaces.Unsigned_8;
   type Throttle_Total_Array is array (Throttle_Source_Index) of Interfaces.Unsigned_64;

   --  One compact ordered table belongs to a benchmark run. Source keys use
   --  the first online logical CPU that represented a core or package during
   --  the deterministic scan; a representative change is conservatively a
   --  topology discontinuity.
   type Throttle_Continuity is record
      Initialized : Boolean := False;
      Count       : Natural range 0 .. Maximum_Throttle_Sources := 0;
      Keys        : Throttle_Key_Array := (others => 0);
      Flags       : Throttle_Flag_Array := (others => 0);
      Events      : Throttle_Total_Array := (others => 0);
      Times_MS    : Throttle_Total_Array := (others => 0);
   end record;

   procedure Observe_Throttle_Source
     (Continuity          : in out Throttle_Continuity;
      Position            : Throttle_Source_Index;
      Key                 : Interfaces.Unsigned_16;
      Event_Available     : Boolean;
      Event_Total         : Interfaces.Unsigned_64;
      Time_Available      : Boolean;
      Time_Total_MS       : Interfaces.Unsigned_64;
      Event_Discontinuous : in out Boolean;
      Time_Discontinuous  : in out Boolean);

   procedure Complete_Throttle_Observation
     (Continuity          : in out Throttle_Continuity;
      Count               : Natural;
      Event_Discontinuous : in out Boolean;
      Time_Discontinuous  : in out Boolean)
   with Pre => Count <= Maximum_Throttle_Sources;

   type Snapshot is record
      Profile_Availability        : Condition_Availability := Condition_Unavailable;
      Profile_Detector            : Condition_Detector := No_Condition_Detector;
      Profile                     : Performance_Profile := Profile_Unknown;
      Power_Source                : Host_Power_Source := Power_Source_Unknown;
      Low_Power_Availability      : Condition_Availability := Condition_Unavailable;
      Low_Power_Detector          : Condition_Detector := No_Condition_Detector;
      Low_Power_Mode              : Low_Power_Mode_State := Low_Power_Mode_Unknown;
      Process_Profile_Avail       : Condition_Availability := Condition_Unavailable;
      Process_Profile_Detector    : Condition_Detector := No_Condition_Detector;
      Process_Profile             : Process_Performance_Profile := Process_Profile_Unknown;
      Thermal_Availability        : Condition_Availability := Condition_Unavailable;
      Thermal_Detector            : Condition_Detector := No_Condition_Detector;
      Thermal_State               : Host_Thermal_State := Thermal_State_Unknown;
      Degradation_Availability    : Condition_Availability := Condition_Unavailable;
      Degradation                 : Performance_Degradation := Degradation_Unknown;
      Throttle_Availability       : Condition_Availability := Condition_Unavailable;
      Throttle_Time_Avail         : Condition_Availability := Condition_Unavailable;
      Throttle_Detector           : Condition_Detector := No_Condition_Detector;
      Throttle_Total              : Interfaces.Unsigned_64 := 0;
      Throttle_Time_Total_MS      : Interfaces.Unsigned_64 := 0;
      Throttle_Discontinuous      : Boolean := False;
      Throttle_Time_Discontinuous : Boolean := False;
   end record;

   --  Read configured and live operating conditions. Configured profile
   --  probes may launch a platform utility and are therefore optional for
   --  frequent window-boundary readings. Every probe runs outside harness
   --  wall timestamps.
   procedure Read
     (Value           : out Snapshot;
      Continuity      : in out Throttle_Continuity;
      Include_Profile : Boolean := True;
      Deadline        : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last);

   --  Exercise the bounded command mechanism without exposing it through the
   --  public benchmark API. Used by the crate's native-boundary smoke test.
   procedure Capture_For_Test
     (Command       : String;
      Argument      : String;
      Timeout_MS    : Positive;
      Success       : out Boolean;
      Output_Length : out Natural);

   --  Exercise the real Linux sysfs and profile classifiers against a
   --  caller-selected fixture root without opening the system bus. This is a
   --  private crate-test seam, not part of the benchmark API.
   procedure Read_Linux_For_Test
     (Sysfs_Root                : String;
      PPD_Profile               : String;
      PPD_Profile_Available     : Boolean;
      PPD_Degradation           : String;
      PPD_Degradation_Available : Boolean;
      Value                     : out Snapshot;
      Continuity                : in out Throttle_Continuity);

end Flyology_Bench.Internal_Conditions;
