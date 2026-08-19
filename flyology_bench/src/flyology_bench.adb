--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Numerics.Long_Elementary_Functions;
with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology_Bench.Host_Control;
with Flyology_Bench.Host_Lock;
with Flyology_Bench_Internal_Probes;
with Interfaces.C;
with System;

package body Flyology_Bench is
   package Math renames Ada.Numerics.Long_Elementary_Functions;
   use Flyology_Bench_Internal_Probes;

   use type Interfaces.Unsigned_64;
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;

   Bootstrap_Resamples : constant := 2_000;

   procedure Escape (Value : System.Address);
   pragma Import (C, Escape, "flyology_bench_escape");

   procedure Memory_Barrier;
   pragma Import (C, Memory_Barrier, "flyology_bench_clobber_memory");

   function Native_Host_CPU_Snapshot
     (Busy_Ticks  : System.Address;
      Total_Ticks : System.Address;
      Capacity    : Interfaces.C.size_t;
      CPU_Count   : access Interfaces.C.size_t) return Interfaces.C.int;
   pragma Import
     (C, Native_Host_CPU_Snapshot, "flyology_bench_host_cpu_snapshot");

   Maximum_Host_CPUs : constant := 1_024;
   type Host_CPU_Counters is
     array (Natural range 0 .. Maximum_Host_CPUs - 1)
       of aliased Interfaces.Unsigned_64
     with Convention => C;

   type Float_Array is array (Positive range <>) of Long_Float;

   procedure Free_Metric_Store is new Ada.Unchecked_Deallocation
     (Metric_Store, Metric_Store_Access);

   overriding procedure Adjust (Object : in out Metric_Store_Handle) is
   begin
      if Object.Data /= null then
         Object.Data.References := Object.Data.References + 1;
      end if;
   end Adjust;

   overriding procedure Finalize (Object : in out Metric_Store_Handle) is
   begin
      if Object.Data = null then
         return;
      elsif Object.Data.References = 1 then
         Free_Metric_Store (Object.Data);
      else
         Object.Data.References := Object.Data.References - 1;
         Object.Data := null;
      end if;
   end Finalize;

   type Sample_Probe_State is record
      Resource_Before      : Native_Resource_Values := (others => 0);
      Resource_Before_Mask : Interfaces.Unsigned_64 := 0;
      Scheduler_Before     : Flyology_Scheduler_Snapshot;
   end record;

   function Has_Any (Set : Metric_Set) return Boolean is
   begin
      for Axis in Metric_Axis loop
         if Set (Axis) then
            return True;
         end if;
      end loop;
      return False;
   end Has_Any;

   function Resource_Metrics_Requested (Config : Configuration) return Boolean
   is
   begin
      for Axis in Process_CPU_Time .. Filesystem_Output_Operations loop
         if Config.Metrics (Axis) then
            return True;
         end if;
      end loop;
      return Config.Collect_Process_Telemetry;
   end Resource_Metrics_Requested;

   function Scheduler_Metrics_Requested
     (Config : Configuration) return Boolean
   is
   begin
      for Axis in Flyology_Dispatches .. Flyology_Migrations loop
         if Config.Metrics (Axis) then
            return True;
         end if;
      end loop;
      return False;
   end Scheduler_Metrics_Requested;

   function Perf_Status
     (Perf  : Perf_Handle;
      Index : Natural) return Metric_Availability
   is
      Value : constant Interfaces.C.int := Perf.State.Statuses (Index);
   begin
      if Value < 0
        or else Value > Interfaces.C.int (Metric_Availability'Pos
          (Metric_Availability'Last))
      then
         return Probe_Failed;
      end if;
      return Metric_Availability'Val (Natural (Value));
   end Perf_Status;

   procedure Initialize_Metrics
     (Config : Configuration;
      Result : in out Measurement) is
   begin
      if Has_Any (Config.Metrics) then
         Result.Metric_Data.Data := new Metric_Store'
           (References => 1,
            Requested  => Config.Metrics,
            Available  => Config.Metrics,
            Status     => (others => Metric_Not_Requested),
            Values     => (others => (others => 0.0)),
            Summaries  => (others => (others => <>)));
         for Axis in Metric_Axis loop
            if Config.Metrics (Axis) then
               Result.Metric_Data.Data.Status (Axis) := Metric_Collected;
            end if;
         end loop;
         if Scheduler_Metrics_Requested (Config)
           and then Config.Scheduler_Probe = null
         then
            for Axis in Flyology_Dispatches .. Flyology_Migrations loop
               Result.Metric_Data.Data.Available (Axis) := False;
               Result.Metric_Data.Data.Status (Axis) := Probe_Failed;
            end loop;
         end if;
      end if;
   end Initialize_Metrics;

   procedure Initialize_Perf
     (Config : Configuration;
      Perf   : in out Perf_Handle)
   is
      Requested : Interfaces.Unsigned_64 := 0;
   begin
      for Axis in CPU_Cycles .. Branch_Misses loop
         if Config.Metrics (Axis) and then Axis /= Instructions_Per_Cycle then
            declare
               Index : constant Natural :=
                 (case Axis is
                    when CPU_Cycles    => 0,
                    when Instructions  => 1,
                    when Cache_Misses  => 2,
                    when Branches      => 3,
                    when Branch_Misses => 4,
                    when others        => 0);
            begin
               Requested := Requested or Interfaces.Shift_Left
                 (Interfaces.Unsigned_64'(1), Index);
            end;
         end if;
      end loop;
      if Config.Metrics (Instructions_Per_Cycle) then
         Requested := Requested or 3;
      end if;
      if Requested /= 0 then
         if Native_Perf_Initialize (Perf.State'Access, Requested) /= 0 then
            raise Program_Error with "Linux perf initialization failed";
         end if;
         Perf.Initialized := True;
      end if;
   end Initialize_Perf;

   procedure Start_Sample
     (Config : Configuration;
      Perf   : in out Perf_Handle;
      State  : out Sample_Probe_State)
   is
      Ignored : Boolean;
   begin
      State := (others => <>);
      if Resource_Metrics_Requested (Config) then
         Read_Resource_Snapshot
           (State.Resource_Before, State.Resource_Before_Mask, Ignored);
      end if;
      if Scheduler_Metrics_Requested (Config)
        and then Config.Scheduler_Probe /= null
      then
         Config.Scheduler_Probe.all (State.Scheduler_Before);
      end if;
      if Perf.Initialized and then Native_Perf_Start (Perf.State'Access) /= 0
      then
         raise Program_Error with "Linux perf counter start failed";
      end if;
   end Start_Sample;

   function Elapsed_Nanoseconds
     (Started  : Interfaces.Unsigned_64;
      Finished : Interfaces.Unsigned_64) return Long_Float
   is
   begin
      if Finished < Started then
         raise Program_Error with "platform monotonic clock moved backwards";
      end if;
      return Long_Float (Finished - Started);
   end Elapsed_Nanoseconds;

   function Duration_Nanoseconds (Value : Duration) return Interfaces.Unsigned_64
   is
      Rounded : constant Long_Float :=
        Long_Float'Rounding (Long_Float (Value) * 1_000_000_000.0);
   begin
      if Value > 0.0 and then Rounded < 1.0 then
         return 1;
      end if;
      return Interfaces.Unsigned_64 (Rounded);
   end Duration_Nanoseconds;

   procedure Notify
     (Config    : Configuration;
      Phase     : Progress_Phase;
      Completed : Natural := 0;
      Total     : Natural := 0) is
   begin
      if Config.Progress /= null then
         Config.Progress.all
           (Ada.Strings.Unbounded.To_String (Config.Progress_Name),
            Phase, Completed, Total);
      end if;
   end Notify;

   function Sampling_Limit_Reached
     (Config    : Configuration;
      Started   : Interfaces.Unsigned_64;
      Completed : Natural;
      Excluded  : Interfaces.Unsigned_64 := 0) return Boolean
   is
      Elapsed : constant Interfaces.Unsigned_64 := Clock_Now - Started;
   begin
      --  Time spent suspended waiting for the host is not collection time,
      --  so it must not silently truncate the sample count.
      return Config.Maximum_Sampling_Time > 0.0
        and then Completed >= Natural (Sample_Count'First)
        and then Elapsed >= Excluded
        and then Elapsed - Excluded
          >= Duration_Nanoseconds (Config.Maximum_Sampling_Time);
   end Sampling_Limit_Reached;

   procedure Record_Process_Telemetry
     (Result           : in out Measurement;
      Index            : Sample_Index;
      Elapsed          : Long_Float;
      CPU_Before       : Interfaces.Unsigned_64;
      CPU_After        : Interfaces.Unsigned_64;
      RSS_Before       : Interfaces.Unsigned_64;
      RSS_After        : Interfaces.Unsigned_64;
      Usage_Available  : Boolean) is
   begin
      if not Usage_Available
        or else CPU_After < CPU_Before
        or else Elapsed <= 0.0
      then
         return;
      end if;
      Result.Telemetry_Available := True;
      Result.Telemetry_CPU (Index) :=
        100.0 * Long_Float (CPU_After - CPU_Before) / Elapsed;
      Result.Telemetry_RSS (Index) := Long_Float (RSS_After);
      Result.Telemetry_RSS_Delta (Index) :=
        Long_Float (RSS_After) - Long_Float (RSS_Before);
      Result.Telemetry_CPU_Total := Result.Telemetry_CPU_Total
        + Long_Float (CPU_After - CPU_Before);
      Result.Telemetry_Wall_Total := Result.Telemetry_Wall_Total + Elapsed;
      if Result.Telemetry_RSS_Start = 0.0 then
         Result.Telemetry_RSS_Start := Long_Float (RSS_Before);
      end if;
      Result.Telemetry_RSS_Final := Long_Float (RSS_After);
      Result.Telemetry_RSS_Peak := Long_Float'Max
        (Result.Telemetry_RSS_Peak, Long_Float (RSS_After));
      Result.Telemetry_RSS_Change_Total :=
        Result.Telemetry_RSS_Change_Total
        + Long_Float (RSS_After) - Long_Float (RSS_Before);
      Result.Telemetry_RSS_Change_Peak := Long_Float'Max
        (Result.Telemetry_RSS_Change_Peak,
         Long_Float (RSS_After) - Long_Float (RSS_Before));
   end Record_Process_Telemetry;

   procedure Finish_Sample
     (Config      : Configuration;
      Perf        : in out Perf_Handle;
      State       : Sample_Probe_State;
      Result      : in out Measurement;
      Index       : Sample_Index;
      Iterations  : Iteration_Count;
      Raw_Elapsed : Long_Float)
   is
      Resource_After      : Native_Resource_Values := (others => 0);
      Resource_After_Mask : Interfaces.Unsigned_64 := 0;
      Resource_OK         : Boolean := False;
      Perf_Values         : Native_Perf_Values := (others => 0);
      Perf_Mask           : aliased Interfaces.Unsigned_64 := 0;
      Scheduler_After     : Flyology_Scheduler_Snapshot;
      Per_Operation       : constant Long_Float := Long_Float (Iterations);
      Reported_Elapsed    : Long_Float := Raw_Elapsed;

      procedure Unavailable
        (Axis   : Metric_Axis;
         Reason : Metric_Availability := Probe_Failed) is
      begin
         if Result.Metric_Data.Data /= null then
            if Result.Metric_Data.Data.Available (Axis) then
               Result.Metric_Data.Data.Status (Axis) := Reason;
            end if;
            Result.Metric_Data.Data.Available (Axis) := False;
         end if;
      end Unavailable;

      procedure Store (Axis : Metric_Axis; Value : Long_Float) is
      begin
         if Result.Metric_Data.Data /= null
           and then Result.Metric_Data.Data.Requested (Axis)
           and then Result.Metric_Data.Data.Available (Axis)
         then
            Result.Metric_Data.Data.Values (Axis, Index) := Value;
         end if;
      end Store;

      procedure Store_Resource_Delta
        (Axis          : Metric_Axis;
         Resource_Bit  : Natural)
      is
      begin
         if Mask_Has (State.Resource_Before_Mask, Resource_Bit)
           and then Mask_Has (Resource_After_Mask, Resource_Bit)
           and then Resource_After (Resource_Bit)
             >= State.Resource_Before (Resource_Bit)
         then
            Store
              (Axis,
               Long_Float
                 (Resource_After (Resource_Bit)
                  - State.Resource_Before (Resource_Bit))
                 / Per_Operation);
         else
            Unavailable (Axis);
         end if;
      end Store_Resource_Delta;

      function Scheduler_Delta
        (Before : Interfaces.Unsigned_64;
         After  : Interfaces.Unsigned_64) return Long_Float is
      begin
         if After < Before then
            raise Constraint_Error with
              "Flyology scheduler probe counters must be monotonic";
         end if;
         return Long_Float (After - Before) / Per_Operation;
      end Scheduler_Delta;
   begin
      if Perf.Initialized
        and then Native_Perf_Finish
          (Perf.State'Access,
           Perf_Values (Perf_Values'First)'Address,
           Interfaces.C.size_t (Perf_Values'Length),
           Perf_Mask'Access) /= 0
      then
         raise Program_Error with "Linux perf counter read failed";
      end if;
      if Scheduler_Metrics_Requested (Config)
        and then Config.Scheduler_Probe /= null
      then
         Config.Scheduler_Probe.all (Scheduler_After);
      end if;
      if Resource_Metrics_Requested (Config) then
         Read_Resource_Snapshot
           (Resource_After, Resource_After_Mask, Resource_OK);
      end if;

      if Config.Collect_Process_Telemetry then
         Record_Process_Telemetry
           (Result, Index, Raw_Elapsed,
            State.Resource_Before (0), Resource_After (0),
            State.Resource_Before (2), Resource_After (2),
            Resource_OK
              and then Mask_Has (State.Resource_Before_Mask, 0)
              and then Mask_Has (Resource_After_Mask, 0)
              and then Mask_Has (State.Resource_Before_Mask, 2)
              and then Mask_Has (Resource_After_Mask, 2));
      end if;

      if Result.Metric_Data.Data = null then
         return;
      end if;
      if Config.Subtract_Timer_Cost
        and then Raw_Elapsed > Result.Timer_Cost
      then
         Reported_Elapsed := Raw_Elapsed - Result.Timer_Cost;
      end if;
      Store (Wall_Time, Reported_Elapsed / Per_Operation);

      if Result.Metric_Data.Data.Requested (Process_CPU_Time) then
         Store_Resource_Delta (Process_CPU_Time, 0);
      end if;
      if Result.Metric_Data.Data.Requested (Thread_CPU_Time) then
         Store_Resource_Delta (Thread_CPU_Time, 1);
      end if;
      if Result.Metric_Data.Data.Requested (Process_RSS) then
         if Resource_OK and then Mask_Has (Resource_After_Mask, 2) then
            Store (Process_RSS, Long_Float (Resource_After (2)));
         else
            Unavailable (Process_RSS);
         end if;
      end if;
      if Result.Metric_Data.Data.Requested (Process_RSS_Change) then
         if Resource_OK
           and then Mask_Has (State.Resource_Before_Mask, 2)
           and then Mask_Has (Resource_After_Mask, 2)
         then
            Store
              (Process_RSS_Change,
               (Long_Float (Resource_After (2))
                - Long_Float (State.Resource_Before (2))) / Per_Operation);
         else
            Unavailable (Process_RSS_Change);
         end if;
      end if;
      if Result.Metric_Data.Data.Requested (Minor_Page_Faults) then
         Store_Resource_Delta (Minor_Page_Faults, 3);
      end if;
      if Result.Metric_Data.Data.Requested (Major_Page_Faults) then
         Store_Resource_Delta (Major_Page_Faults, 4);
      end if;
      if Result.Metric_Data.Data.Requested (Voluntary_Context_Switches) then
         Store_Resource_Delta (Voluntary_Context_Switches, 5);
      end if;
      if Result.Metric_Data.Data.Requested (Involuntary_Context_Switches) then
         Store_Resource_Delta (Involuntary_Context_Switches, 6);
      end if;
      if Result.Metric_Data.Data.Requested (Disk_Read_Bytes) then
         Store_Resource_Delta (Disk_Read_Bytes, 7);
      end if;
      if Result.Metric_Data.Data.Requested (Disk_Written_Bytes) then
         Store_Resource_Delta (Disk_Written_Bytes, 8);
      end if;
      if Result.Metric_Data.Data.Requested (Filesystem_Input_Operations) then
         Store_Resource_Delta (Filesystem_Input_Operations, 9);
      end if;
      if Result.Metric_Data.Data.Requested (Filesystem_Output_Operations) then
         Store_Resource_Delta (Filesystem_Output_Operations, 10);
      end if;

      for Axis in CPU_Cycles .. Branch_Misses loop
         if Result.Metric_Data.Data.Requested (Axis) then
            if Axis = Instructions_Per_Cycle then
               if Mask_Has (Perf_Mask, 0)
                 and then Mask_Has (Perf_Mask, 1)
                 and then Perf_Values (0) > 0
               then
                  Store
                    (Axis,
                     Long_Float (Perf_Values (1))
                       / Long_Float (Perf_Values (0)));
               else
                  Unavailable
                    (Axis,
                     (if not Mask_Has (Perf_Mask, 0)
                      then Perf_Status (Perf, 0)
                      elsif not Mask_Has (Perf_Mask, 1)
                      then Perf_Status (Perf, 1)
                      else Probe_Failed));
               end if;
            else
               declare
                  Perf_Index : constant Natural :=
                    (case Axis is
                       when CPU_Cycles    => 0,
                       when Instructions  => 1,
                       when Cache_Misses  => 2,
                       when Branches      => 3,
                       when Branch_Misses => 4,
                       when others        => 0);
               begin
                  if Mask_Has (Perf_Mask, Perf_Index) then
                     Store
                       (Axis,
                        Long_Float (Perf_Values (Perf_Index))
                          / Per_Operation);
                  else
                     Unavailable
                       (Axis, Perf_Status (Perf, Perf_Index));
                  end if;
               end;
            end if;
         end if;
      end loop;

      if Scheduler_Metrics_Requested (Config) then
         if Config.Scheduler_Probe = null
           or else not State.Scheduler_Before.Available
           or else not Scheduler_After.Available
         then
            for Axis in Flyology_Dispatches .. Flyology_Migrations loop
               Unavailable (Axis);
            end loop;
         else
            Store
              (Flyology_Dispatches,
               Scheduler_Delta
                 (State.Scheduler_Before.Dispatches,
                  Scheduler_After.Dispatches));
            Store
              (Flyology_Poll_Batches,
               Scheduler_Delta
                 (State.Scheduler_Before.Poll_Batches,
                  Scheduler_After.Poll_Batches));
            Store
              (Flyology_Poll_Events,
               Scheduler_Delta
                 (State.Scheduler_Before.Poll_Events,
                  Scheduler_After.Poll_Events));
            Store
              (Flyology_Wakeups,
               Scheduler_Delta
                 (State.Scheduler_Before.Wakeups,
                  Scheduler_After.Wakeups));
            Store
              (Flyology_Migrations,
               Scheduler_Delta
                 (State.Scheduler_Before.Migrations_In,
                  Scheduler_After.Migrations_In)
               + Scheduler_Delta
                 (State.Scheduler_Before.Migrations_Out,
                  Scheduler_After.Migrations_Out));
         end if;
      end if;
   end Finish_Sample;

   procedure Read_Host_CPU
     (Busy      : out Host_CPU_Counters;
      Total     : out Host_CPU_Counters;
      CPU_Count : out Natural)
   is
      Count : aliased Interfaces.C.size_t := 0;
   begin
      Busy := (others => 0);
      Total := (others => 0);
      if Native_Host_CPU_Snapshot
          (Busy (Busy'First)'Address,
           Total (Total'First)'Address,
           Interfaces.C.size_t (Maximum_Host_CPUs),
           Count'Access) /= 0
        or else Count = 0
        or else Count > Interfaces.C.size_t (Maximum_Host_CPUs)
      then
         raise Program_Error with "host CPU utilization query failed";
      end if;
      CPU_Count := Natural (Count);
   end Read_Host_CPU;

   procedure Host_CPU_Utilization
     (Previous_Busy  : Host_CPU_Counters;
      Previous_Total : Host_CPU_Counters;
      Current_Busy   : Host_CPU_Counters;
      Current_Total  : Host_CPU_Counters;
      CPU_Count      : Natural;
      Average        : out Long_Float;
      Peak           : out Long_Float;
      Available      : out Boolean)
   is
      Busy_Sum  : Long_Float := 0.0;
      Total_Sum : Long_Float := 0.0;
   begin
      Average := 0.0;
      Peak := 0.0;
      Available := False;
      for CPU in 0 .. CPU_Count - 1 loop
         if Current_Busy (CPU) < Previous_Busy (CPU)
           or else Current_Total (CPU) < Previous_Total (CPU)
         then
            return;
         end if;
         declare
            Busy_Delta : constant Interfaces.Unsigned_64 :=
              Current_Busy (CPU) - Previous_Busy (CPU);
            Total_Delta : constant Interfaces.Unsigned_64 :=
              Current_Total (CPU) - Previous_Total (CPU);
         begin
            if Busy_Delta > Total_Delta then
               return;
            elsif Total_Delta > 0 then
               Busy_Sum := Busy_Sum + Long_Float (Busy_Delta);
               Total_Sum := Total_Sum + Long_Float (Total_Delta);
               Peak := Long_Float'Max
                 (Peak,
                  100.0 * Long_Float (Busy_Delta)
                    / Long_Float (Total_Delta));
            end if;
         end;
      end loop;
      if Total_Sum > 0.0 then
         Average := 100.0 * Busy_Sum / Total_Sum;
         Available := True;
      end if;
   end Host_CPU_Utilization;

   Maximum_Watched_CPUs : constant := 128;
   type Watched_CPU_Array is
     array (1 .. Maximum_Watched_CPUs) of Natural;

   --  Rolling state for the mid-run interference watch. One window spans a
   --  whole number of collection units and is judged only after it closes,
   --  so a response never lands between the two halves of a paired sample or
   --  inside a balanced multi-way round.
   type Interference_Watch is record
      Active         : Boolean := False;
      Watched        : Watched_CPU_Array := (others => 0);
      Watched_Total  : Natural := 0;
      Open           : Boolean := False;
      Busy           : Host_CPU_Counters := (others => 0);
      Total          : Host_CPU_Counters := (others => 0);
      CPU_Count      : Natural := 0;
      Own_Process    : Interfaces.Unsigned_64 := 0;
      Own_Thread     : Interfaces.Unsigned_64 := 0;
      Own_Valid      : Boolean := False;
      Wall           : Interfaces.Unsigned_64 := 0;
      Retakes        : Natural := 0;
      Paused_Total   : Interfaces.Unsigned_64 := 0;
      Foreign_Sum    : Long_Float := 0.0;
      Report         : Environment_Report;
      Foreign        : Sample_Array (Sample_Index'Range) := (others => 0.0);
   end record;

   --  What the caller must do with the window that just closed.
   --  @enum Accept_Window Keep the collected units and continue.
   --  @enum Retake_Window Discard them and collect the same units again.
   --  @enum Settle_And_Retake Wait for the host, re-warm, then collect again.
   type Window_Action is (Accept_Window, Retake_Window, Settle_And_Retake);

   --  Per-sample telemetry is written by index and survives a retake intact,
   --  but the summary fields are running sums and a running maximum. A
   --  discarded window has to give its contribution back, or the reported CPU
   --  share and elapsed time describe samples that were thrown away.
   type Telemetry_Snapshot is record
      Available        : Boolean := False;
      CPU_Total        : Long_Float := 0.0;
      Wall_Total       : Long_Float := 0.0;
      RSS_Start        : Long_Float := 0.0;
      RSS_Final        : Long_Float := 0.0;
      RSS_Peak         : Long_Float := 0.0;
      RSS_Change_Total : Long_Float := 0.0;
      RSS_Change_Peak  : Long_Float := 0.0;
   end record;

   function Save_Telemetry (Result : Measurement) return Telemetry_Snapshot is
     (Available        => Result.Telemetry_Available,
      CPU_Total        => Result.Telemetry_CPU_Total,
      Wall_Total       => Result.Telemetry_Wall_Total,
      RSS_Start        => Result.Telemetry_RSS_Start,
      RSS_Final        => Result.Telemetry_RSS_Final,
      RSS_Peak         => Result.Telemetry_RSS_Peak,
      RSS_Change_Total => Result.Telemetry_RSS_Change_Total,
      RSS_Change_Peak  => Result.Telemetry_RSS_Change_Peak);

   procedure Restore_Telemetry
     (Result : in out Measurement;
      Saved  : Telemetry_Snapshot) is
   begin
      Result.Telemetry_Available := Saved.Available;
      Result.Telemetry_CPU_Total := Saved.CPU_Total;
      Result.Telemetry_Wall_Total := Saved.Wall_Total;
      Result.Telemetry_RSS_Start := Saved.RSS_Start;
      Result.Telemetry_RSS_Final := Saved.RSS_Final;
      Result.Telemetry_RSS_Peak := Saved.RSS_Peak;
      Result.Telemetry_RSS_Change_Total := Saved.RSS_Change_Total;
      Result.Telemetry_RSS_Change_Peak := Saved.RSS_Change_Peak;
   end Restore_Telemetry;

   --  Our own CPU time over the window, read once as both totals.
   --
   --  Host-wide attribution subtracts the whole process, because every thread
   --  of it contributes to the host counters. Core-scoped attribution
   --  subtracts only the placed thread, because only that thread is bound to
   --  the watched CPUs. Subtracting the whole process there would deduct time
   --  our threads spent on CPUs outside the watched set and under-report
   --  foreign load, which fails silently; subtracting only the placed thread
   --  over-reports instead, which is visible. The difference between the two
   --  is what the dilution check measures.
   procedure Read_Own_CPU
     (Process_CPU : out Interfaces.Unsigned_64;
      Thread_CPU  : out Interfaces.Unsigned_64;
      Valid       : out Boolean)
   is
      Values    : Native_Resource_Values := (others => 0);
      Mask      : Interfaces.Unsigned_64 := 0;
      Available : Boolean := False;
   begin
      Read_Resource_Snapshot (Values, Mask, Available);
      Valid := Available
        and then Mask_Has (Mask, 0)
        and then Mask_Has (Mask, 1);
      if not Valid then
         Process_CPU := 0;
         Thread_CPU := 0;
         return;
      end if;
      Process_CPU := Values (0);
      Thread_CPU := Values (1);
   end Read_Own_CPU;

   --  Foreign share of the watched CPUs' capacity, in percent. The host busy
   --  ratio is scaled by wall time rather than converted from ticks, so the
   --  platform tick length never enters the arithmetic.
   procedure Foreign_Utilization
     (Watch          : Interference_Watch;
      Current_Busy   : Host_CPU_Counters;
      Current_Total  : Host_CPU_Counters;
      Own_Delta      : Long_Float;
      Other_Delta    : Long_Float;
      Wall_Delta     : Long_Float;
      Foreign        : out Long_Float;
      Dilution       : out Long_Float;
      Available      : out Boolean)
   is
      Busy_Sum  : Long_Float := 0.0;
      Total_Sum : Long_Float := 0.0;
      Counted   : Natural := 0;
      Capacity  : Long_Float;
      Busy_Time : Long_Float;

      procedure Accumulate (CPU : Natural) is
      begin
         if Current_Busy (CPU) < Watch.Busy (CPU)
           or else Current_Total (CPU) < Watch.Total (CPU)
         then
            return;
         end if;
         declare
            Busy_Delta : constant Interfaces.Unsigned_64 :=
              Current_Busy (CPU) - Watch.Busy (CPU);
            Total_Delta : constant Interfaces.Unsigned_64 :=
              Current_Total (CPU) - Watch.Total (CPU);
         begin
            if Busy_Delta > Total_Delta or else Total_Delta = 0 then
               return;
            end if;
            Busy_Sum := Busy_Sum + Long_Float (Busy_Delta);
            Total_Sum := Total_Sum + Long_Float (Total_Delta);
            Counted := Counted + 1;
         end;
      end Accumulate;
   begin
      Foreign := 0.0;
      Dilution := 0.0;
      Available := False;
      if Watch.Report.Attribution = Core_Scoped then
         for Index in 1 .. Watch.Watched_Total loop
            if Watch.Watched (Index) < Watch.CPU_Count then
               Accumulate (Watch.Watched (Index));
            end if;
         end loop;
      else
         for CPU in 0 .. Watch.CPU_Count - 1 loop
            Accumulate (CPU);
         end loop;
      end if;
      if Counted = 0 or else Total_Sum <= 0.0 or else Wall_Delta <= 0.0 then
         return;
      end if;
      Capacity := Long_Float (Counted) * Wall_Delta;
      Busy_Time := (Busy_Sum / Total_Sum) * Capacity;
      Foreign := 100.0 * Long_Float'Max (0.0, Busy_Time - Own_Delta)
        / Capacity;
      --  The share of the watched capacity that this process's other threads
      --  could account for. It is an upper bound: they may have run entirely
      --  on CPUs outside the watched set.
      Dilution := 100.0 * Long_Float'Max (0.0, Other_Delta) / Capacity;
      Available := True;
   end Foreign_Utilization;

   procedure Open_Interference_Window (Watch : in out Interference_Watch) is
   begin
      if not Watch.Active then
         return;
      end if;
      Read_Host_CPU (Watch.Busy, Watch.Total, Watch.CPU_Count);
      Read_Own_CPU (Watch.Own_Process, Watch.Own_Thread, Watch.Own_Valid);
      Watch.Wall := Clock_Now;
      Watch.Open := True;
   end Open_Interference_Window;

   --  Close the open window, record what it saw, and decide what happens to
   --  the units it covered.
   procedure Judge_Window
     (Config : Configuration;
      Watch  : in out Interference_Watch;
      First  : Sample_Index;
      Last   : Sample_Index;
      Action : out Window_Action)
   is
      Current_Busy  : Host_CPU_Counters := (others => 0);
      Current_Total : Host_CPU_Counters := (others => 0);
      Current_Count : Natural := 0;
      Process_After : Interfaces.Unsigned_64;
      Thread_After  : Interfaces.Unsigned_64;
      Own_Valid     : Boolean;
      Finished      : Interfaces.Unsigned_64;
      Foreign       : Long_Float := 0.0;
      Dilution      : Long_Float := 0.0;
      Available     : Boolean := False;
      Wall_Delta    : Long_Float := 0.0;
      Units         : constant Natural := Natural (Last) - Natural (First) + 1;
   begin
      Action := Accept_Window;
      if not Watch.Active or else not Watch.Open then
         return;
      end if;
      Watch.Open := False;
      Read_Host_CPU (Current_Busy, Current_Total, Current_Count);
      Read_Own_CPU (Process_After, Thread_After, Own_Valid);
      Finished := Clock_Now;

      if Current_Count = Watch.CPU_Count
        and then Finished > Watch.Wall
        and then Own_Valid
        and then Watch.Own_Valid
        and then Process_After >= Watch.Own_Process
        and then Thread_After >= Watch.Own_Thread
      then
         Wall_Delta := Long_Float (Finished - Watch.Wall);
         declare
            Process_Delta : constant Long_Float :=
              Long_Float (Process_After - Watch.Own_Process);
            Thread_Delta : constant Long_Float :=
              Long_Float (Thread_After - Watch.Own_Thread);
         begin
            Foreign_Utilization
              (Watch, Current_Busy, Current_Total,
               (if Watch.Report.Attribution = Core_Scoped
                then Thread_Delta else Process_Delta),
               Process_Delta - Thread_Delta,
               Wall_Delta, Foreign, Dilution, Available);
         end;
      end if;

      if not Available then
         return;
      end if;

      --  Placement binds only the calling thread, so another thread of this
      --  process can occupy a watched CPU, where its time is
      --  indistinguishable from foreign load. Once those threads can account
      --  for more of the watched capacity than the configured limit, the
      --  core-scoped answer cannot address the question the limit asks. The
      --  run drops to host-wide, which is well defined for a multi-threaded
      --  process, rather than reporting its own runtime as interference. The
      --  window that revealed it is not recorded, because its value was
      --  computed under the attribution being abandoned.
      if Watch.Report.Attribution = Core_Scoped
        and then Dilution > Config.Interference.Maximum_Foreign_CPU_Percent
      then
         Watch.Report.Attribution := Host_Wide;
         Watch.Report.Attribution_Diluted := True;
         Watch.Report.Watched_CPUs := 0;
         Watch.Watched_Total := 0;
         return;
      end if;

      for Index in First .. Last loop
         Watch.Foreign (Index) := Foreign;
      end loop;
      Watch.Report.Watched := True;
      Watch.Report.Windows := Watch.Report.Windows + 1;
      Watch.Report.Peak_Foreign_CPU_Percent := Long_Float'Max
        (Watch.Report.Peak_Foreign_CPU_Percent, Foreign);
      Watch.Foreign_Sum := Watch.Foreign_Sum + Foreign;

      if Foreign <= Config.Interference.Maximum_Foreign_CPU_Percent then
         Watch.Report.Observed_Samples :=
           Watch.Report.Observed_Samples + Units;
         return;
      end if;

      --  A window shorter than the configured minimum is recorded but never
      --  acted on: below one counter tick the estimate is mostly
      --  quantization, and discarding samples over it would be noise
      --  masquerading as hygiene.
      if Wall_Delta < Long_Float (Duration_Nanoseconds
        (Config.Interference.Window))
      then
         Watch.Report.Contaminated_Samples :=
           Watch.Report.Contaminated_Samples + Units;
         Watch.Report.Observed_Samples :=
           Watch.Report.Observed_Samples + Units;
         return;
      end if;

      if Config.Interference.Response = Observe
        or else Watch.Retakes + Units > Config.Interference.Maximum_Retakes
      then
         if Config.Interference.Response /= Observe then
            Watch.Report.Budget_Exhausted := True;
         end if;
         Watch.Report.Contaminated_Samples :=
           Watch.Report.Contaminated_Samples + Units;
         Watch.Report.Observed_Samples :=
           Watch.Report.Observed_Samples + Units;
         return;
      end if;

      Watch.Retakes := Watch.Retakes + Units;
      Watch.Report.Retaken_Samples := Watch.Report.Retaken_Samples + Units;
      Action :=
        (if Config.Interference.Response = Pause
         then Settle_And_Retake
         else Retake_Window);
   end Judge_Window;

   --  Suspend collection until foreign load stays within its limit for
   --  Settle_Time, bounded by whatever remains of the pause budget.
   procedure Await_Foreign_Settle
     (Config : Configuration;
      Watch  : in out Interference_Watch)
   is
      Budget    : constant Interfaces.Unsigned_64 :=
        Duration_Nanoseconds (Config.Interference.Maximum_Pause_Time);
      Required  : constant Interfaces.Unsigned_64 :=
        Duration_Nanoseconds (Config.Interference.Settle_Time);
      Started   : constant Interfaces.Unsigned_64 := Clock_Now;
      Stable    : Interfaces.Unsigned_64 := 0;
      Foreign   : Long_Float;
      Available : Boolean;
      Current_Busy  : Host_CPU_Counters := (others => 0);
      Current_Total : Host_CPU_Counters := (others => 0);
      Current_Count : Natural := 0;
      Process_After : Interfaces.Unsigned_64;
      Thread_After  : Interfaces.Unsigned_64;
      Own_Valid : Boolean;
      Finished  : Interfaces.Unsigned_64;
      Completed : Natural;
      Dilution  : Long_Float;
   begin
      if Watch.Paused_Total >= Budget then
         Watch.Report.Budget_Exhausted := True;
         return;
      end if;
      Watch.Report.Pauses := Watch.Report.Pauses + 1;
      Notify (Config, Waiting_For_CPU_Quiescence, 0, 100);
      loop
         Open_Interference_Window (Watch);
         delay Config.Interference.Window;
         Read_Host_CPU (Current_Busy, Current_Total, Current_Count);
         Read_Own_CPU (Process_After, Thread_After, Own_Valid);
         Finished := Clock_Now;
         Available := False;
         Foreign := 0.0;
         if Current_Count = Watch.CPU_Count
           and then Finished > Watch.Wall
           and then Own_Valid
           and then Watch.Own_Valid
           and then Process_After >= Watch.Own_Process
           and then Thread_After >= Watch.Own_Thread
         then
            declare
               Process_Delta : constant Long_Float :=
                 Long_Float (Process_After - Watch.Own_Process);
               Thread_Delta : constant Long_Float :=
                 Long_Float (Thread_After - Watch.Own_Thread);
            begin
               Foreign_Utilization
                 (Watch, Current_Busy, Current_Total,
                  (if Watch.Report.Attribution = Core_Scoped
                   then Thread_Delta else Process_Delta),
                  Process_Delta - Thread_Delta,
                  Long_Float (Finished - Watch.Wall),
                  Foreign, Dilution, Available);
            end;
         end if;
         Watch.Open := False;

         if Available
           and then Foreign
             <= Config.Interference.Maximum_Foreign_CPU_Percent
         then
            Stable := Stable + (Finished - Watch.Wall);
         else
            Stable := 0;
         end if;
         Completed := Natural'Min
           (100,
            Natural (Long_Float'Floor
              (100.0 * Long_Float (Stable)
               / Long_Float'Max (1.0, Long_Float (Required)))));
         Notify (Config, Waiting_For_CPU_Quiescence, Completed, 100);
         exit when Stable >= Required;
         --  Exhausting the budget degrades the run to Observe rather than
         --  discarding everything collected so far.
         if Clock_Now - Started >= Budget - Watch.Paused_Total then
            Watch.Report.Budget_Exhausted := True;
            exit;
         end if;
      end loop;
      declare
         Spent : constant Interfaces.Unsigned_64 := Clock_Now - Started;
      begin
         Watch.Paused_Total := Watch.Paused_Total + Spent;
         Watch.Report.Paused_Nanoseconds :=
           Watch.Report.Paused_Nanoseconds + Long_Float (Spent);
      end;
   end Await_Foreign_Settle;

   --  Number of collection units judged together. Interference watching is
   --  the only reason to group units at all; without it every unit is judged
   --  alone and the collection loop keeps its original shape.
   function Units_Per_Window
     (Config           : Configuration;
      Unit_Nanoseconds : Long_Float;
      Total_Units      : Positive) return Positive
   is
      Required : Long_Float;
      Units    : Long_Float;
   begin
      if not Config.Interference.Enabled or else Unit_Nanoseconds <= 0.0 then
         return 1;
      end if;
      Required :=
        Long_Float (Duration_Nanoseconds (Config.Interference.Window));
      --  Batch duration varies from sample to sample, so a window sized to
      --  only just reach the minimum would regularly fall short of it and
      --  silently degrade to observation. The margin buys that back.
      Units := Long_Float'Max
        (1.0, Long_Float'Ceiling (1.25 * Required / Unit_Nanoseconds));
      if Units >= Long_Float (Total_Units) then
         return Total_Units;
      end if;
      return Positive (Units);
   end Units_Per_Window;

   procedure Apply_Environment
     (Watch           : Interference_Watch;
      Result          : in out Measurement;
      Include_Samples : Boolean := True) is
   begin
      Result.Environment_Data := Watch.Report;
      if Include_Samples then
         Result.Foreign_CPU := Watch.Foreign;
      end if;
      if Watch.Report.Windows > 0 then
         Result.Environment_Data.Mean_Foreign_CPU_Percent :=
           Watch.Foreign_Sum / Long_Float (Watch.Report.Windows);
      end if;
   end Apply_Environment;

   procedure Add_Watched_CPU
     (Watch : in out Interference_Watch;
      CPU   : Natural) is
   begin
      for Index in 1 .. Watch.Watched_Total loop
         if Watch.Watched (Index) = CPU then
            return;
         end if;
      end loop;
      if Watch.Watched_Total < Maximum_Watched_CPUs then
         Watch.Watched_Total := Watch.Watched_Total + 1;
         Watch.Watched (Watch.Watched_Total) := CPU;
      end if;
   end Add_Watched_CPU;

   --  First line of a Linux pseudo-file, or the empty string when it cannot
   --  be read. Placement inspection is Linux-only, so an absent file is an
   --  ordinary answer rather than an error.
   function Read_First_Line (Path : String) return String is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      declare
         Line : constant String := Ada.Text_IO.Get_Line (File);
      begin
         Ada.Text_IO.Close (File);
         return Line;
      end;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Read_First_Line;

   --  /proc pads its fields with tabs, which Ada.Strings.Fixed.Trim does not
   --  remove by default. A retained tab makes Natural'Value raise, and the
   --  CPU list then parses as empty.
   Blanks : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (' ' & ASCII.HT & ASCII.CR & ASCII.LF);

   function Unpadded (Value : String) return String is
     (Ada.Strings.Fixed.Trim (Value, Blanks, Blanks));

   --  Value of one /proc/self/status field, without its name or padding.
   function Status_Field (Name : String) return String is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "/proc/self/status");
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            if Line'Length > Name'Length + 1
              and then Line (Line'First .. Line'First + Name'Length)
                = Name & ":"
            then
               declare
                  Value : constant String := Unpadded
                    (Line (Line'First + Name'Length + 1 .. Line'Last));
               begin
                  Ada.Text_IO.Close (File);
                  return Value;
               end;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      return "";
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Status_Field;

   --  Add every CPU named by a Linux list such as "0-3,8,10-11".
   procedure Add_CPU_List
     (Watch : in out Interference_Watch;
      Text  : String)
   is
      First : Natural := Text'First;
   begin
      while First <= Text'Last loop
         declare
            Last  : Natural := Text'Last;
            Dash  : Natural := 0;
            Low   : Natural;
            High  : Natural;
         begin
            for Index in First .. Text'Last loop
               if Text (Index) = ',' then
                  Last := Index - 1;
                  exit;
               end if;
            end loop;
            for Index in First .. Last loop
               if Text (Index) = '-' then
                  Dash := Index;
                  exit;
               end if;
            end loop;
            begin
               if Dash > 0 then
                  Low := Natural'Value (Unpadded (Text (First .. Dash - 1)));
                  High := Natural'Value (Unpadded (Text (Dash + 1 .. Last)));
               else
                  Low := Natural'Value (Unpadded (Text (First .. Last)));
                  High := Low;
               end if;
               for CPU in Low .. High loop
                  Add_Watched_CPU (Watch, CPU);
               end loop;
            exception
               when Constraint_Error =>
                  null;
            end;
            First := Last + 2;
         end;
      end loop;
   end Add_CPU_List;

   --  Build the set of logical CPUs whose busy time is entirely foreign. SMT
   --  siblings belong in it: a sibling saturated by another process slows the
   --  measurement while leaving the placed CPU's own busy share clean.
   procedure Collect_Watched_CPUs
     (Config : Configuration;
      Watch  : in out Interference_Watch)
   is
      Allowed : constant String := Status_Field ("Cpus_allowed_list");
      Placed  : Natural;
   begin
      if Allowed = "" then
         return;
      end if;
      Add_CPU_List (Watch, Allowed);
      if not Config.Placement.Include_Siblings then
         return;
      end if;
      Placed := Watch.Watched_Total;
      for Index in 1 .. Placed loop
         Add_CPU_List
           (Watch,
            Read_First_Line
              ("/sys/devices/system/cpu/cpu"
               & Ada.Strings.Fixed.Trim
                   (Natural'Image (Watch.Watched (Index)), Ada.Strings.Both)
               & "/topology/thread_siblings_list"));
      end loop;
   end Collect_Watched_CPUs;

   --  Claim host CPU capacity, place the benchmark thread, and decide how
   --  foreign load will be attributed. Runs before the preflight gate: a
   --  quiet verdict obtained before blocking on the claim would be stale by
   --  the time collection started.
   procedure Prepare_Environment
     (Config : Configuration;
      Watch  : in out Interference_Watch;
      Lock   : in out Host_Lock.Claim)
   is
      use type Host_Lock.Acquisition;
      use type Host_Lock.Path_Isolation;
      use type Host_Control.Placement_Strength;
   begin
      if Config.Host_Lock.Enabled then
         declare
            Path : constant String :=
              Ada.Strings.Unbounded.To_String (Config.Host_Lock.Path);
            Step : constant Duration :=
              Duration'Max (0.001, Config.Host_Lock.Poll_Interval);
            Waited  : Duration := 0.0;
            Outcome : Host_Lock.Acquisition;
         begin
            Notify (Config, Waiting_For_CPU_Quiescence, 0, 100);
            loop
               Host_Lock.Try_Acquire (Lock, Outcome, Path => Path);
               exit when Outcome /= Host_Lock.Busy;
               exit when Waited >= Config.Host_Lock.Timeout;
               --  Waiting idle rather than spinning: a busy waiter would be
               --  the very foreign load the holder is trying to avoid.
               delay Step;
               Waited := Waited + Step;
               Notify
                 (Config, Waiting_For_CPU_Quiescence,
                  (if Config.Host_Lock.Timeout > 0.0
                   then Natural'Min
                     (100,
                      Natural (Long_Float'Floor
                        (100.0 * Long_Float (Waited)
                         / Long_Float (Config.Host_Lock.Timeout))))
                   else 100),
                  100);
            end loop;
            case Outcome is
               when Host_Lock.Acquired =>
                  Watch.Report.Host_Lock :=
                    (if Host_Lock.Isolation (Lock)
                       = Host_Lock.Private_Namespace
                     then Lock_Namespace_Scoped
                     else Lock_Held);
               when Host_Lock.Busy =>
                  Watch.Report.Host_Lock := Lock_Busy;
               when Host_Lock.Path_Unusable =>
                  Watch.Report.Host_Lock := Lock_Path_Unusable;
            end case;
         end;
         if Config.Host_Lock.Require_Machine_Scope
           and then Watch.Report.Host_Lock /= Lock_Held
         then
            raise Host_Lock_Unavailable with
              "host CPU claim is not machine-wide ("
              & Host_Lock_Outcome'Image (Watch.Report.Host_Lock) & ")";
         end if;
      end if;

      if Config.Placement.Enabled then
         begin
            Watch.Report.Placement :=
              (if Host_Control.Pin_Current_Thread (Config.Placement.CPU)
                 = Host_Control.Strict
               then Placement_Strict
               else Placement_Advisory);
         exception
            when Program_Error =>
               Watch.Report.Placement := Placement_Rejected;
         end;
         if Config.Placement.Require_Strict
           and then Watch.Report.Placement /= Placement_Strict
         then
            raise Placement_Unavailable with
              "strict benchmark thread placement is unavailable on this host";
         end if;
         --  Only a strict binding tells us which CPUs are ours. A Darwin
         --  affinity tag is a scheduler hint whose value is not a CPU index,
         --  so attribution there stays host-wide.
         if Watch.Report.Placement = Placement_Strict then
            Collect_Watched_CPUs (Config, Watch);
         end if;
      end if;

      if Watch.Watched_Total > 0 then
         Watch.Report.Attribution := Core_Scoped;
         Watch.Report.Watched_CPUs := Watch.Watched_Total;
      else
         Watch.Report.Attribution := Host_Wide;
      end if;
      Watch.Active := Config.Interference.Enabled;
   end Prepare_Environment;

   procedure Await_CPU_Quiescence (Config : Configuration) is
      Previous_Busy  : Host_CPU_Counters := (others => 0);
      Previous_Total : Host_CPU_Counters := (others => 0);
      Current_Busy   : Host_CPU_Counters := (others => 0);
      Current_Total  : Host_CPU_Counters := (others => 0);
      Previous_Count : Natural;
      Current_Count  : Natural;
      Started        : Interfaces.Unsigned_64;
      Previous_Time  : Interfaces.Unsigned_64;
      Current_Time   : Interfaces.Unsigned_64;
      Stable_NS      : Interfaces.Unsigned_64 := 0;
      Required_NS    : Interfaces.Unsigned_64;
      Timeout_NS     : Interfaces.Unsigned_64;
      Average        : Long_Float := 0.0;
      Peak           : Long_Float := 0.0;
      Available      : Boolean;
      Completed      : Natural;
   begin
      if not Config.CPU_Quiescence.Enabled then
         return;
      end if;

      Required_NS := Duration_Nanoseconds (Config.CPU_Quiescence.Stable_Time);
      Timeout_NS := Duration_Nanoseconds (Config.CPU_Quiescence.Timeout);
      Read_Host_CPU (Previous_Busy, Previous_Total, Previous_Count);
      Started := Clock_Now;
      Previous_Time := Started;
      Notify (Config, Waiting_For_CPU_Quiescence, 0, 100);

      loop
         delay Config.CPU_Quiescence.Poll_Interval;
         Read_Host_CPU (Current_Busy, Current_Total, Current_Count);
         Current_Time := Clock_Now;
         if Current_Count = Previous_Count then
            Host_CPU_Utilization
              (Previous_Busy, Previous_Total, Current_Busy, Current_Total,
               Current_Count, Average, Peak, Available);
         else
            Available := False;
         end if;

         if Available
           and then Average
             <= Config.CPU_Quiescence.Maximum_Average_CPU_Percent
           and then Peak <= Config.CPU_Quiescence.Maximum_Core_CPU_Percent
         then
            Stable_NS := Stable_NS + (Current_Time - Previous_Time);
         else
            Stable_NS := 0;
         end if;

         Completed := Natural'Min
           (100,
            Natural
              (Long_Float'Floor
                 (100.0 * Long_Float (Stable_NS)
                  / Long_Float (Required_NS))));
         Notify
           (Config, Waiting_For_CPU_Quiescence, Completed, 100);
         exit when Stable_NS >= Required_NS;

         if Current_Time - Started >= Timeout_NS then
            raise CPU_Quiescence_Timeout with
              "host CPU did not remain below the configured limits"
              & " (last average" & Long_Float'Image (Average) & "%, peak"
              & Long_Float'Image (Peak) & "%)";
         end if;

         Previous_Busy := Current_Busy;
         Previous_Total := Current_Total;
         Previous_Count := Current_Count;
         Previous_Time := Current_Time;
      end loop;
   end Await_CPU_Quiescence;

   procedure Sort (Values : in out Float_Array) is
   begin
      for Index in Values'First + 1 .. Values'Last loop
         declare
            Value    : constant Long_Float := Values (Index);
            Position : Positive := Index;
         begin
            while Position > Values'First
              and then Values (Position - 1) > Value
            loop
               Values (Position) := Values (Position - 1);
               Position := Position - 1;
            end loop;
            Values (Position) := Value;
         end;
      end loop;
   end Sort;

   function Percentile
     (Ordered : Float_Array;
      Fraction : Long_Float) return Long_Float
   is
      Position : constant Long_Float :=
        Long_Float (Ordered'First)
        + Fraction * Long_Float (Ordered'Length - 1);
      Lower    : constant Positive := Positive (Long_Float'Floor (Position));
      Upper    : constant Positive := Positive (Long_Float'Ceiling (Position));
      Weight   : constant Long_Float := Position - Long_Float (Lower);
   begin
      return Ordered (Lower) * (1.0 - Weight) + Ordered (Upper) * Weight;
   end Percentile;

   procedure Characterize_Clock
     (Backend             : out Natural;
      Nominal_Resolution  : out Long_Float;
      Observed_Resolution : out Long_Float;
      Minimum_Cost        : out Long_Float;
      Median_Cost         : out Long_Float)
   is
      Count      : constant := 512;
      Resolution : aliased Interfaces.Unsigned_64;
      Values     : Float_Array (1 .. Count);
      Previous   : Interfaces.Unsigned_64 := Clock_Now;
   begin
      if Native_Clock_Resolution (Resolution'Access) /= 0 then
         raise Program_Error with "platform clock resolution query failed";
      end if;
      Backend := Natural (Native_Clock_Backend);
      Nominal_Resolution := Long_Float (Resolution);
      Observed_Resolution := Long_Float'Last;
      Minimum_Cost := Long_Float'Last;
      for Index in Values'Range loop
         declare
            Current : constant Interfaces.Unsigned_64 := Clock_Now;
            Elapsed : constant Long_Float :=
              Elapsed_Nanoseconds (Previous, Current);
         begin
            Values (Index) := Elapsed;
            if Elapsed > 0.0 then
               Observed_Resolution :=
                 Long_Float'Min (Observed_Resolution, Elapsed);
               Minimum_Cost := Long_Float'Min (Minimum_Cost, Elapsed);
            end if;
            Previous := Current;
         end;
      end loop;
      Sort (Values);
      Median_Cost := Percentile (Values, 0.5);
      if Observed_Resolution = Long_Float'Last then
         Observed_Resolution := 0.0;
      end if;
      if Minimum_Cost = Long_Float'Last then
         Minimum_Cost := 0.0;
      end if;
   end Characterize_Clock;

   procedure Validate (Config : Configuration) is
   begin
      if Config.Warmup_Time < 0.0 then
         raise Constraint_Error with "warmup time must not be negative";
      elsif Config.Measurement_Time <= 0.0 then
         raise Constraint_Error with "measurement time must be positive";
      elsif Config.Maximum_Sampling_Time < 0.0 then
         raise Constraint_Error with
           "maximum sampling time must not be negative";
      elsif Config.Minimum_Sample_Time <= 0.0 then
         raise Constraint_Error with "minimum sample time must be positive";
      elsif Config.Maximum_Iterations = 0 then
         raise Constraint_Error with "maximum iterations must be positive";
      elsif Config.Practical_Threshold_Percent < 0.0
        or else Config.Practical_Threshold_Percent >= 100.0
      then
         raise Constraint_Error with
           "practical threshold must be in the range 0 .. 100 percent";
      elsif Config.CPU_Quiescence.Enabled
        and then
          (Config.CPU_Quiescence.Maximum_Average_CPU_Percent < 0.0
           or else Config.CPU_Quiescence.Maximum_Average_CPU_Percent > 100.0)
      then
         raise Constraint_Error with
           "maximum average host CPU must be in the range 0 .. 100 percent";
      elsif Config.CPU_Quiescence.Enabled
        and then
          (Config.CPU_Quiescence.Maximum_Core_CPU_Percent < 0.0
           or else Config.CPU_Quiescence.Maximum_Core_CPU_Percent > 100.0)
      then
         raise Constraint_Error with
           "maximum per-core CPU must be in the range 0 .. 100 percent";
      elsif Config.CPU_Quiescence.Enabled
        and then Config.CPU_Quiescence.Stable_Time <= 0.0
      then
         raise Constraint_Error with
           "CPU quiescence stable time must be positive";
      elsif Config.CPU_Quiescence.Enabled
        and then Config.CPU_Quiescence.Poll_Interval <= 0.0
      then
         raise Constraint_Error with
           "CPU quiescence poll interval must be positive";
      elsif Config.CPU_Quiescence.Enabled
        and then Config.CPU_Quiescence.Timeout
          < Config.CPU_Quiescence.Stable_Time
      then
         raise Constraint_Error with
           "CPU quiescence timeout must cover the stable interval";
      elsif Config.CPU_Quiescence.Enabled
        and then Config.CPU_Quiescence.Poll_Interval
          > Config.CPU_Quiescence.Timeout
      then
         raise Constraint_Error with
           "CPU quiescence poll interval must not exceed the timeout";
      elsif Config.Interference.Enabled
        and then (Config.Interference.Maximum_Foreign_CPU_Percent < 0.0
                  or else Config.Interference.Maximum_Foreign_CPU_Percent
                    > 100.0)
      then
         raise Constraint_Error with
           "interference foreign CPU limit must be a percentage";
      elsif Config.Interference.Enabled
        and then Config.Interference.Window <= 0.0
      then
         raise Constraint_Error with
           "interference observation window must be positive";
      elsif Config.Interference.Enabled
        and then Config.Interference.Response = Pause
        and then Config.Interference.Settle_Time <= 0.0
      then
         raise Constraint_Error with
           "interference settle time must be positive";
      elsif Config.Interference.Enabled
        and then Config.Interference.Response = Pause
        and then Config.Interference.Maximum_Pause_Time
          < Config.Interference.Settle_Time
      then
         raise Constraint_Error with
           "interference pause budget must cover one settle interval";
      elsif Config.Interference.Enabled
        and then Config.Interference.Rewarm_Time < 0.0
      then
         raise Constraint_Error with
           "interference re-warm time must not be negative";
      elsif Config.Host_Lock.Enabled
        and then Config.Host_Lock.Timeout < 0.0
      then
         raise Constraint_Error with
           "host CPU claim timeout must not be negative";
      elsif Config.Host_Lock.Enabled
        and then Config.Host_Lock.Poll_Interval <= 0.0
      then
         raise Constraint_Error with
           "host CPU claim poll interval must be positive";
      end if;
   end Validate;

   function Next_Random
     (State : in out Interfaces.Unsigned_64) return Interfaces.Unsigned_64 is
   begin
      State := State xor Interfaces.Shift_Left (State, 13);
      State := State xor Interfaces.Shift_Right (State, 7);
      State := State xor Interfaces.Shift_Left (State, 17);
      return State;
   end Next_Random;

   procedure Analyze (Result : in out Measurement) is
      Count      : constant Positive := Positive (Result.Sample_Total);
      Ordered    : Float_Array (1 .. Count);
      Deviations : Float_Array (1 .. Count);
      Sum        : Long_Float := 0.0;
      Sum_Square : Long_Float := 0.0;
      Q1         : Long_Float;
      Q3         : Long_Float;
      IQR        : Long_Float;
   begin
      for Index in Ordered'Range loop
         Ordered (Index) := Result.Values (Sample_Index (Index));
         Sum := Sum + Ordered (Index);
      end loop;
      Sort (Ordered);

      Result.Minimum := Ordered (Ordered'First);
      Result.Maximum := Ordered (Ordered'Last);
      Result.Mean := Sum / Long_Float (Count);
      Result.Median := Percentile (Ordered, 0.5);
      Result.P95 := Percentile (Ordered, 0.95);
      Result.P99 := Percentile (Ordered, 0.99);

      for Index in Ordered'Range loop
         declare
            Difference : constant Long_Float := Ordered (Index) - Result.Mean;
         begin
            Sum_Square := Sum_Square + Difference * Difference;
            Deviations (Index) := abs (Ordered (Index) - Result.Median);
         end;
      end loop;
      Sort (Deviations);
      Result.MAD := Percentile (Deviations, 0.5);
      Result.Standard_Deviation :=
        Math.Sqrt (Sum_Square / Long_Float (Count - 1));
      if Result.Mean /= 0.0 then
         Result.CV_Percent :=
           100.0 * Result.Standard_Deviation / Result.Mean;
      end if;

      if Count > 2 then
         declare
            Numerator : Long_Float := 0.0;
            Left_Sum  : Long_Float := 0.0;
            Right_Sum : Long_Float := 0.0;
         begin
            for Index in 2 .. Count loop
               declare
                  Left : constant Long_Float :=
                    Result.Values (Sample_Index (Index - 1)) - Result.Mean;
                  Right : constant Long_Float :=
                    Result.Values (Sample_Index (Index)) - Result.Mean;
               begin
                  Numerator := Numerator + Left * Right;
                  Left_Sum := Left_Sum + Left * Left;
                  Right_Sum := Right_Sum + Right * Right;
               end;
            end loop;
            if Left_Sum > 0.0 and then Right_Sum > 0.0 then
               Result.Lag_One :=
                 Numerator / Math.Sqrt (Left_Sum * Right_Sum);
            end if;
         end;
      end if;

      Q1 := Percentile (Ordered, 0.25);
      Q3 := Percentile (Ordered, 0.75);
      IQR := Q3 - Q1;
      for Index in Ordered'Range loop
         if Ordered (Index) < Q1 - 3.0 * IQR then
            Result.Outlier_Total.Low_Severe :=
              Result.Outlier_Total.Low_Severe + 1;
         elsif Ordered (Index) < Q1 - 1.5 * IQR then
            Result.Outlier_Total.Low_Mild :=
              Result.Outlier_Total.Low_Mild + 1;
         elsif Ordered (Index) > Q3 + 3.0 * IQR then
            Result.Outlier_Total.High_Severe :=
              Result.Outlier_Total.High_Severe + 1;
         elsif Ordered (Index) > Q3 + 1.5 * IQR then
            Result.Outlier_Total.High_Mild :=
              Result.Outlier_Total.High_Mild + 1;
         end if;
      end loop;

      declare
         Means : Float_Array (1 .. Bootstrap_Resamples);
         State : Interfaces.Unsigned_64 :=
           16#9E37_79B9_7F4A_7C15# xor
           Interfaces.Unsigned_64 (Result.Random_Seed_Value);
         Block_Length : constant Positive :=
           Positive'Max
             (2, Positive (Long_Float'Ceiling (Math.Sqrt (Long_Float (Count)))));
      begin
         for Resample in Means'Range loop
            Sum := 0.0;
            declare
               Drawn : Natural := 0;
            begin
               while Drawn < Count loop
                  declare
                     Start : constant Positive :=
                       Positive
                         (Natural
                            (Next_Random (State)
                             mod Interfaces.Unsigned_64 (Count)) + 1);
                  begin
                     for Offset in 0 .. Block_Length - 1 loop
                        exit when Drawn = Count;
                        declare
                           Index : constant Positive :=
                             ((Start - 1 + Offset) mod Count) + 1;
                        begin
                           Sum := Sum
                             + Result.Values (Sample_Index (Index));
                           Drawn := Drawn + 1;
                        end;
                     end loop;
                  end;
               end loop;
            end;
            Means (Resample) := Sum / Long_Float (Count);
         end loop;
         Sort (Means);
         Result.Confidence_Low := Percentile (Means, 0.025);
         Result.Confidence_High := Percentile (Means, 0.975);
      end;
   end Analyze;

   procedure Analyze_Metrics (Result : in out Measurement) is
   begin
      if Result.Metric_Data.Data = null then
         return;
      end if;
      for Axis in Metric_Axis loop
         if Result.Metric_Data.Data.Requested (Axis)
           and then Result.Metric_Data.Data.Available (Axis)
         then
            declare
               Count   : constant Positive := Positive (Result.Sample_Total);
               Ordered : Float_Array (1 .. Count);
               Means   : Float_Array (1 .. Bootstrap_Resamples);
               Sum     : Long_Float := 0.0;
               State   : Interfaces.Unsigned_64 :=
                 16#243F_6A88_85A3_08D3# xor
                 Interfaces.Unsigned_64 (Result.Random_Seed_Value)
                 xor Interfaces.Unsigned_64 (Metric_Axis'Pos (Axis) + 1);
               Block_Length : constant Positive :=
                 Positive'Max
                   (2, Positive
                     (Long_Float'Ceiling (Math.Sqrt (Long_Float (Count)))));
               Summary : Metric_Summary;
            begin
               for Sample in Ordered'Range loop
                  Ordered (Sample) := Result.Metric_Data.Data.Values
                    (Axis, Sample_Index (Sample));
                  Sum := Sum + Ordered (Sample);
               end loop;
               Sort (Ordered);
               Summary.Available := True;
               Summary.Samples := Count;
               Summary.Minimum := Ordered (Ordered'First);
               Summary.Maximum := Ordered (Ordered'Last);
               Summary.Mean := Sum / Long_Float (Count);
               Summary.Median := Percentile (Ordered, 0.5);
               Summary.P95 := Percentile (Ordered, 0.95);
               Summary.P99 := Percentile (Ordered, 0.99);

               for Resample in Means'Range loop
                  Sum := 0.0;
                  declare
                     Drawn : Natural := 0;
                  begin
                     while Drawn < Count loop
                        declare
                           Start : constant Positive := Positive
                             (Natural
                               (Next_Random (State)
                                mod Interfaces.Unsigned_64 (Count)) + 1);
                        begin
                           for Offset in 0 .. Block_Length - 1 loop
                              exit when Drawn = Count;
                              declare
                                 Sample : constant Positive :=
                                   ((Start - 1 + Offset) mod Count) + 1;
                              begin
                                 Sum := Sum + Result.Metric_Data.Data.Values
                                   (Axis, Sample_Index (Sample));
                                 Drawn := Drawn + 1;
                              end;
                           end loop;
                        end;
                     end loop;
                  end;
                  Means (Resample) := Sum / Long_Float (Count);
               end loop;
               Sort (Means);
               Summary.Confidence_Low := Percentile (Means, 0.025);
               Summary.Confidence_High := Percentile (Means, 0.975);
               Result.Metric_Data.Data.Summaries (Axis) := Summary;
            end;
         end if;
      end loop;
   end Analyze_Metrics;

   procedure Analyze_Metric_Comparisons (Result : in out Comparison) is
      Count : constant Positive :=
        Positive (Result.Reference_Data.Sample_Total);
   begin
      for Axis in Metric_Axis loop
         if Result.Reference_Data.Metric_Data.Data /= null
           and then Result.Contender_Data.Metric_Data.Data /= null
           and then Result.Reference_Data.Metric_Data.Data.Available (Axis)
           and then Result.Contender_Data.Metric_Data.Data.Available (Axis)
           and then Result.Reference_Data.Metric_Data.Data.Requested (Axis)
           and then Result.Contender_Data.Metric_Data.Data.Requested (Axis)
         then
            declare
               Samples : Float_Array (1 .. Count);
               Bootstrap : Float_Array (1 .. Bootstrap_Resamples);
               Positive_Only : Boolean := True;
               Sum : Long_Float := 0.0;
               State : Interfaces.Unsigned_64 :=
                 16#1319_8A2E_0370_7344# xor
                 Interfaces.Unsigned_64 (Result.Random_Seed_Value)
                 xor Interfaces.Unsigned_64 (Metric_Axis'Pos (Axis) + 1);
               Block_Length : constant Positive :=
                 Positive'Max
                   (2, Positive
                     (Long_Float'Ceiling (Math.Sqrt (Long_Float (Count)))));
               Item : Metric_Comparison_Result;
            begin
               Item.Available := True;
               Item.Reference_Median :=
                 Result.Reference_Data.Metric_Data.Data.Summaries (Axis).Median;
               Item.Contender_Median :=
                 Result.Contender_Data.Metric_Data.Data.Summaries (Axis).Median;
               for Sample in Samples'Range loop
                  if Result.Reference_Data.Metric_Data.Data.Values
                       (Axis, Sample_Index (Sample)) <= 0.0
                    or else Result.Contender_Data.Metric_Data.Data.Values
                       (Axis, Sample_Index (Sample)) <= 0.0
                  then
                     Positive_Only := False;
                  end if;
               end loop;

               if Positive_Only then
                  Item.Method := Relative_Ratio;
                  for Sample in Samples'Range loop
                     Samples (Sample) := Math.Log
                       (Result.Contender_Data.Metric_Data.Data.Values
                          (Axis, Sample_Index (Sample))
                        / Result.Reference_Data.Metric_Data.Data.Values
                          (Axis, Sample_Index (Sample)));
                     Sum := Sum + Samples (Sample);
                  end loop;
                  Item.Change := 100.0
                    * (Math.Exp (Sum / Long_Float (Count)) - 1.0);
               else
                  Item.Method := Absolute_Difference;
                  for Sample in Samples'Range loop
                     Samples (Sample) :=
                       Result.Contender_Data.Metric_Data.Data.Values
                         (Axis, Sample_Index (Sample))
                       - Result.Reference_Data.Metric_Data.Data.Values
                         (Axis, Sample_Index (Sample));
                     Sum := Sum + Samples (Sample);
                  end loop;
                  Item.Change := Sum / Long_Float (Count);
               end if;

               for Resample in Bootstrap'Range loop
                  Sum := 0.0;
                  declare
                     Drawn : Natural := 0;
                  begin
                     while Drawn < Count loop
                        declare
                           Start : constant Positive := Positive
                             (Natural
                               (Next_Random (State)
                                mod Interfaces.Unsigned_64 (Count)) + 1);
                        begin
                           for Offset in 0 .. Block_Length - 1 loop
                              exit when Drawn = Count;
                              Sum := Sum + Samples
                                (((Start - 1 + Offset) mod Count) + 1);
                              Drawn := Drawn + 1;
                           end loop;
                        end;
                     end loop;
                  end;
                  if Item.Method = Relative_Ratio then
                     Bootstrap (Resample) := 100.0
                       * (Math.Exp (Sum / Long_Float (Count)) - 1.0);
                  else
                     Bootstrap (Resample) := Sum / Long_Float (Count);
                  end if;
               end loop;
               Sort (Bootstrap);
               Item.Confidence_Low := Percentile (Bootstrap, 0.025);
               Item.Confidence_High := Percentile (Bootstrap, 0.975);

               if Direction (Axis) = Diagnostic then
                  Item.Verdict := Metric_Diagnostic;
               elsif Item.Method = Relative_Ratio then
                  declare
                     Threshold : constant Long_Float :=
                       Result.Practical_Threshold;
                  begin
                     if Item.Confidence_Low >= -Threshold
                       and then Item.Confidence_High <= Threshold
                     then
                        Item.Verdict := Metric_Practically_Equivalent;
                     elsif Direction (Axis) = Lower_Is_Better
                       and then Item.Confidence_High < -Threshold
                     then
                        Item.Verdict := Contender_Better;
                     elsif Direction (Axis) = Lower_Is_Better
                       and then Item.Confidence_Low > Threshold
                     then
                        Item.Verdict := Reference_Better;
                     elsif Direction (Axis) = Higher_Is_Better
                       and then Item.Confidence_Low > Threshold
                     then
                        Item.Verdict := Contender_Better;
                     elsif Direction (Axis) = Higher_Is_Better
                       and then Item.Confidence_High < -Threshold
                     then
                        Item.Verdict := Reference_Better;
                     end if;
                  end;
               elsif Item.Confidence_Low = 0.0
                 and then Item.Confidence_High = 0.0
               then
                  Item.Verdict := Metric_Practically_Equivalent;
               elsif Direction (Axis) = Lower_Is_Better
                 and then Item.Confidence_High < 0.0
               then
                  Item.Verdict := Contender_Better;
               elsif Direction (Axis) = Lower_Is_Better
                 and then Item.Confidence_Low > 0.0
               then
                  Item.Verdict := Reference_Better;
               elsif Direction (Axis) = Higher_Is_Better
                 and then Item.Confidence_Low > 0.0
               then
                  Item.Verdict := Contender_Better;
               elsif Direction (Axis) = Higher_Is_Better
                 and then Item.Confidence_High < 0.0
               then
                  Item.Verdict := Reference_Better;
               end if;
               Result.Metric_Comparisons (Axis) := Item;
            end;
         end if;
      end loop;
   end Analyze_Metric_Comparisons;

   procedure Analyze_Comparison (Result : in out Comparison) is
      Count      : constant Positive :=
        Positive (Result.Reference_Data.Sample_Total);
      Ratios     : Float_Array (1 .. Count);
      Log_Ratios : Float_Array (1 .. Count);
      Log_Sum    : Long_Float := 0.0;
      Difference_Sum : Long_Float := 0.0;
      Reference_First_Log_Sum : Long_Float := 0.0;
      Contender_First_Log_Sum : Long_Float := 0.0;
   begin
      for Index in 1 .. Count loop
         declare
            Reference_Time : constant Long_Float :=
              Result.Reference_Data.Values (Sample_Index (Index));
            Contender_Time : constant Long_Float :=
              Result.Contender_Data.Values (Sample_Index (Index));
            Ratio          : Long_Float;
         begin
            if Reference_Time <= 0.0 or else Contender_Time <= 0.0 then
               raise Program_Error with
                 "comparison produced a zero-duration sample; increase the "
                 & "minimum sample time or disable timer-cost subtraction";
            end if;
            Ratio := Reference_Time / Contender_Time;
            Result.Speedup_Values (Sample_Index (Index)) := Ratio;
            Ratios (Index) := Ratio;
            Log_Ratios (Index) := Math.Log (Ratio);
            Log_Sum := Log_Sum + Log_Ratios (Index);
            if Result.Reference_First_Order (Sample_Index (Index)) then
               Reference_First_Log_Sum :=
                 Reference_First_Log_Sum + Log_Ratios (Index);
            else
               Contender_First_Log_Sum :=
                 Contender_First_Log_Sum + Log_Ratios (Index);
            end if;
            Difference_Sum :=
              Difference_Sum + Contender_Time - Reference_Time;

            if Contender_Time < Reference_Time then
               Result.Contender_Win_Total :=
                 Result.Contender_Win_Total + 1;
            elsif Reference_Time < Contender_Time then
               Result.Reference_Win_Total :=
                 Result.Reference_Win_Total + 1;
            else
               Result.Tie_Total := Result.Tie_Total + 1;
            end if;
         end;
      end loop;

      Result.Geometric_Speedup :=
        Math.Exp (Log_Sum / Long_Float (Count));
      Result.Mean_Time_Difference :=
        Difference_Sum / Long_Float (Count);
      Sort (Ratios);
      Result.Median_Speedup_Value := Percentile (Ratios, 0.5);

      if Result.Reference_First > 0 and then Result.Contender_First > 0 then
         Result.Order_Effect :=
           100.0
           * (Math.Exp
                (Reference_First_Log_Sum
                   / Long_Float (Result.Reference_First)
                 - Contender_First_Log_Sum
                   / Long_Float (Result.Contender_First))
              - 1.0);
      end if;

      if Count > 2 then
         declare
            Mean_Log : constant Long_Float :=
              Log_Sum / Long_Float (Count);
            Numerator : Long_Float := 0.0;
            Left_Sum  : Long_Float := 0.0;
            Right_Sum : Long_Float := 0.0;
         begin
            for Index in 2 .. Count loop
               declare
                  Left : constant Long_Float :=
                    Log_Ratios (Index - 1) - Mean_Log;
                  Right : constant Long_Float :=
                    Log_Ratios (Index) - Mean_Log;
               begin
                  Numerator := Numerator + Left * Right;
                  Left_Sum := Left_Sum + Left * Left;
                  Right_Sum := Right_Sum + Right * Right;
               end;
            end loop;
            if Left_Sum > 0.0 and then Right_Sum > 0.0 then
               Result.Lag_One :=
                 Numerator / Math.Sqrt (Left_Sum * Right_Sum);
            end if;
         end;
      end if;

      declare
         Bootstrap_Speedups : Float_Array (1 .. Bootstrap_Resamples);
         State : Interfaces.Unsigned_64 :=
           16#D1B5_4A32_D192_ED03# xor
           Interfaces.Unsigned_64 (Result.Random_Seed_Value);
         Block_Length : constant Positive :=
           Positive'Max
             (2, Positive (Long_Float'Ceiling (Math.Sqrt (Long_Float (Count)))));
      begin
         for Resample in Bootstrap_Speedups'Range loop
            Log_Sum := 0.0;
            declare
               Drawn : Natural := 0;
            begin
               while Drawn < Count loop
                  declare
                     Start : constant Positive :=
                       Positive
                         (Natural
                            (Next_Random (State)
                             mod Interfaces.Unsigned_64 (Count)) + 1);
                  begin
                     for Offset in 0 .. Block_Length - 1 loop
                        exit when Drawn = Count;
                        declare
                           Index : constant Positive :=
                             ((Start - 1 + Offset) mod Count) + 1;
                        begin
                           Log_Sum := Log_Sum + Log_Ratios (Index);
                           Drawn := Drawn + 1;
                        end;
                     end loop;
                  end;
               end loop;
            end;
            Bootstrap_Speedups (Resample) :=
              Math.Exp (Log_Sum / Long_Float (Count));
         end loop;
         Sort (Bootstrap_Speedups);
         Result.Speedup_CI_Low :=
           Percentile (Bootstrap_Speedups, 0.025);
         Result.Speedup_CI_High :=
           Percentile (Bootstrap_Speedups, 0.975);
      end;

      declare
         Change_Low : constant Long_Float :=
           100.0 * (1.0 / Result.Speedup_CI_High - 1.0);
         Change_High : constant Long_Float :=
           100.0 * (1.0 / Result.Speedup_CI_Low - 1.0);
         Threshold : constant Long_Float := Result.Practical_Threshold;
      begin
         if Change_High < -Threshold then
            Result.Verdict_Value := Contender_Faster;
         elsif Change_Low > Threshold then
            Result.Verdict_Value := Reference_Faster;
         elsif Change_Low >= -Threshold and then Change_High <= Threshold then
            Result.Verdict_Value := Practically_Equivalent;
         else
            Result.Verdict_Value := Inconclusive;
         end if;
      end;
      Analyze_Metric_Comparisons (Result);
   end Analyze_Comparison;

   generic
      with procedure Run_Batch (Iterations : Iteration_Count);
      with procedure Prepare_Batch;
      with procedure Finish_Batch;
   procedure Measure_Core
     (Config : Configuration;
      Result : out Measurement);

   procedure Measure_Core
     (Config : Configuration;
      Result : out Measurement)
   is
      Batch_Iterations : Iteration_Count := 1;
      Target_NS        : Long_Float;
      Clock_Cost       : Long_Float;
      Calibration_Hits : Natural := 0;
      Perf             : Perf_Handle;
      Watch            : Interference_Watch;
      Lock             : Host_Lock.Claim;

      function Time_Batch (Iterations : Iteration_Count) return Long_Float is
         Started  : Interfaces.Unsigned_64;
         Finished : Interfaces.Unsigned_64;
      begin
         Prepare_Batch;
         Memory_Barrier;
         Started := Clock_Now;
         begin
            Run_Batch (Iterations);
         exception
            when others =>
               Finished := Clock_Now;
               Memory_Barrier;
               Finish_Batch;
               raise;
         end;
         Finished := Clock_Now;
         Memory_Barrier;
         Finish_Batch;
         return Elapsed_Nanoseconds (Started, Finished);
      end Time_Batch;

      function Time_Sampled_Batch (Index : Sample_Index) return Long_Float is
         Probe    : Sample_Probe_State;
         Started  : Interfaces.Unsigned_64;
         Finished : Interfaces.Unsigned_64;
         Elapsed  : Long_Float;
      begin
         Prepare_Batch;
         begin
            Start_Sample (Config, Perf, Probe);
            Memory_Barrier;
            Started := Clock_Now;
            Run_Batch (Batch_Iterations);
            Finished := Clock_Now;
            Memory_Barrier;
            Elapsed := Elapsed_Nanoseconds (Started, Finished);
            Finish_Sample
              (Config, Perf, Probe, Result, Index,
               Batch_Iterations, Elapsed);
         exception
            when others =>
               Memory_Barrier;
               Finish_Batch;
               raise;
         end;
         Finish_Batch;
         return Elapsed;
      end Time_Sampled_Batch;

      procedure Increase_Batch (Elapsed : Long_Float) is
         Scale     : Long_Float;
         Candidate : Iteration_Count;
      begin
         if Batch_Iterations = Config.Maximum_Iterations then
            return;
         elsif Elapsed <= 0.0 then
            Scale := 2.0;
         else
            Scale := Long_Float'Max (2.0, Target_NS / Elapsed);
            Scale := Long_Float'Min (Scale, 2.0);
         end if;

         if Scale >= Long_Float (Config.Maximum_Iterations)
           / Long_Float (Batch_Iterations)
         then
            Candidate := Config.Maximum_Iterations;
         else
            Candidate :=
              Iteration_Count
                (Long_Float'Floor
                   (Long_Float (Batch_Iterations) * Scale));
            Candidate := Iteration_Count'Max (Candidate, Batch_Iterations + 1);
            Candidate :=
              Iteration_Count'Min (Candidate, Config.Maximum_Iterations);
         end if;
         Batch_Iterations := Candidate;
      end Increase_Batch;

   begin
      Validate (Config);
      Result := (others => <>);
      Result.Sample_Total := Config.Samples;
      Result.Random_Seed_Value := Config.Random_Seed;
      Initialize_Metrics (Config, Result);
      Notify (Config, Starting);
      Prepare_Environment (Config, Watch, Lock);
      Await_CPU_Quiescence (Config);
      Characterize_Clock
        (Backend             => Result.Clock_Backend_Id,
         Nominal_Resolution  => Result.Clock_Resolution,
         Observed_Resolution => Result.Observed_Resolution,
         Minimum_Cost        => Clock_Cost,
         Median_Cost         => Result.Median_Timer_Cost);
      Result.Timer_Cost := Clock_Cost;
      Target_NS :=
        Long_Float'Max
          (Long_Float (Config.Minimum_Sample_Time) * 1_000_000_000.0,
           Long_Float (Config.Measurement_Time) * 1_000_000_000.0
             / Long_Float (Config.Samples));

      if Config.Warmup_Time > 0.0 then
         declare
            Started  : constant Interfaces.Unsigned_64 := Clock_Now;
            Span     : constant Interfaces.Unsigned_64 :=
              Duration_Nanoseconds (Config.Warmup_Time);
            Deadline : constant Interfaces.Unsigned_64 := Started + Span;
            Elapsed  : Long_Float;
            Current  : Interfaces.Unsigned_64;
         begin
            Notify (Config, Warming, 0, 100);
            loop
               Elapsed := Time_Batch (Batch_Iterations);
               if Elapsed < Target_NS * 0.5
                 and then Batch_Iterations < Config.Maximum_Iterations
               then
                  Increase_Batch (Elapsed);
               end if;
               Current := Clock_Now;
               Notify
                 (Config, Warming,
                  Natural'Min
                    (100, Natural
                       (Long_Float'Floor
                          (100.0 * Long_Float (Current - Started)
                           / Long_Float (Span)))),
                  100);
               exit when Current >= Deadline;
            end loop;
         end;
      end if;

      Notify (Config, Calibrating);
      loop
         declare
            Elapsed : constant Long_Float := Time_Batch (Batch_Iterations);
         begin
            if Elapsed >= Target_NS * 0.9 then
               Calibration_Hits := Calibration_Hits + 1;
            else
               Calibration_Hits := 0;
               Increase_Batch (Elapsed);
            end if;
            exit when Calibration_Hits >= 3
              or else Batch_Iterations = Config.Maximum_Iterations;
         end;
      end loop;

      Result.Iterations := Batch_Iterations;
      Initialize_Perf (Config, Perf);
      declare
         Sampling_Started : constant Interfaces.Unsigned_64 := Clock_Now;
         Completed : Natural := 0;
         Total_Samples : constant Positive := Natural (Config.Samples);
         Group : constant Positive :=
           Units_Per_Window (Config, Target_NS, Total_Samples);
         Window_First : Positive := 1;
         Window_Last  : Positive;
         Action : Window_Action;

         --  A resumed run has cold caches, predictors, and frequency state.
         --  Without this the first sample after a pause is exactly the
         --  outlier the pause was meant to avoid.
         procedure Rewarm is
            Deadline : Interfaces.Unsigned_64;
            Elapsed  : Long_Float;
         begin
            if Config.Interference.Rewarm_Time <= 0.0 then
               return;
            end if;
            Deadline := Clock_Now
              + Duration_Nanoseconds (Config.Interference.Rewarm_Time);
            Notify (Config, Warming, 0, 100);
            loop
               Elapsed := Time_Batch (Batch_Iterations);
               Escape (Elapsed'Address);
               exit when Clock_Now >= Deadline;
            end loop;
            Notify (Config, Warming, 100, 100);
         end Rewarm;
      begin
         Notify (Config, Sampling, 0, Natural (Config.Samples));
         while Window_First <= Total_Samples loop
            Window_Last :=
              Positive'Min (Window_First + Group - 1, Total_Samples);
            loop
               declare
                  Saved : constant Telemetry_Snapshot :=
                    Save_Telemetry (Result);
               begin
               Open_Interference_Window (Watch);
               for Index in Window_First .. Window_Last loop
                  declare
                     Elapsed : Long_Float;
                  begin
                     Elapsed := Time_Sampled_Batch (Sample_Index (Index));
                     if Config.Subtract_Timer_Cost
                       and then Elapsed > Clock_Cost
                     then
                        Elapsed := Elapsed - Clock_Cost;
                     end if;
                     Result.Values (Sample_Index (Index)) :=
                       Elapsed / Long_Float (Batch_Iterations);
                  end;
                  Completed := Natural'Max (Completed, Index);
                  Notify
                    (Config, Sampling, Completed, Natural (Config.Samples));
               end loop;
               Judge_Window
                 (Config, Watch, Sample_Index (Window_First),
                  Sample_Index (Window_Last), Action);
               exit when Action = Accept_Window;
               Restore_Telemetry (Result, Saved);
               if Action = Settle_And_Retake then
                  Await_Foreign_Settle (Config, Watch);
                  Rewarm;
               end if;
               end;
            end loop;
            exit when Sampling_Limit_Reached
              (Config, Sampling_Started, Completed, Watch.Paused_Total);
            Window_First := Window_Last + 1;
         end loop;
         Result.Sample_Total := Sample_Count (Completed);
      end;
      Apply_Environment (Watch, Result);
      Notify (Config, Analyzing);
      Analyze (Result);
      Analyze_Metrics (Result);
      Result.Median_Batch :=
        Result.Median * Long_Float (Result.Iterations);
      Notify (Config, Finished, 1, 1);
   end Measure_Core;

   generic
      with procedure Run_Reference_Batch (Iterations : Iteration_Count);
      with procedure Run_Contender_Batch (Iterations : Iteration_Count);
   procedure Compare_Core
     (Config : Configuration;
      Result : out Comparison);

   procedure Compare_Core
     (Config : Configuration;
      Result : out Comparison)
   is
      type Order_Array is array (Positive range <>) of Boolean;

      Batch_Iterations : Iteration_Count := 1;
      Reference_Iterations : Iteration_Count := 1;
      Contender_Iterations : Iteration_Count := 1;
      Target_NS        : Long_Float;
      Clock_Cost       : Long_Float;
      Calibration_Hits : Natural := 0;
      Slow_Limit_Hits  : Natural := 0;
      Perf             : Perf_Handle;
      Watch            : Interference_Watch;
      Lock             : Host_Lock.Claim;
      Warmup_State     : Interfaces.Unsigned_64 :=
        16#A076_1D64_78BD_642F# xor
        Interfaces.Unsigned_64 (Config.Random_Seed);

      function Reference_Count return Iteration_Count is
        (if Config.Comparison_Batching = Equal_Time
         then Reference_Iterations else Batch_Iterations);

      function Contender_Count return Iteration_Count is
        (if Config.Comparison_Batching = Equal_Time
         then Contender_Iterations else Batch_Iterations);

      function Time_Reference
        (Iterations : Iteration_Count) return Long_Float
      is
         Started  : Interfaces.Unsigned_64;
         Finished : Interfaces.Unsigned_64;
      begin
         Memory_Barrier;
         Started := Clock_Now;
         Run_Reference_Batch (Iterations);
         Finished := Clock_Now;
         Memory_Barrier;
         return Elapsed_Nanoseconds (Started, Finished);
      end Time_Reference;

      function Time_Contender
        (Iterations : Iteration_Count) return Long_Float
      is
         Started  : Interfaces.Unsigned_64;
         Finished : Interfaces.Unsigned_64;
      begin
         Memory_Barrier;
         Started := Clock_Now;
         Run_Contender_Batch (Iterations);
         Finished := Clock_Now;
         Memory_Barrier;
         return Elapsed_Nanoseconds (Started, Finished);
      end Time_Contender;

      procedure Time_Pair
        (Reference_First  : Boolean;
         Reference_Time   : out Long_Float;
         Contender_Time   : out Long_Float) is
      begin
         if Reference_First then
            Reference_Time := Time_Reference (Reference_Count);
            Contender_Time := Time_Contender (Contender_Count);
         else
            Contender_Time := Time_Contender (Contender_Count);
            Reference_Time := Time_Reference (Reference_Count);
         end if;
      end Time_Pair;

      procedure Increase_Individual_Batch
        (Iterations : in out Iteration_Count;
         Elapsed    : Long_Float)
      is
         Scale : Long_Float;
         Candidate : Iteration_Count;
      begin
         if Iterations = Config.Maximum_Iterations then
            return;
         elsif Elapsed <= 0.0 then
            Scale := 2.0;
         else
            Scale := Long_Float'Max (1.25, Target_NS / Elapsed);
            Scale := Long_Float'Min (Scale, 2.0);
         end if;
         if Scale >= Long_Float (Config.Maximum_Iterations)
           / Long_Float (Iterations)
         then
            Candidate := Config.Maximum_Iterations;
         else
            Candidate :=
              Iteration_Count
                (Long_Float'Floor (Long_Float (Iterations) * Scale));
            Candidate := Iteration_Count'Max (Candidate, Iterations + 1);
            Candidate :=
              Iteration_Count'Min (Candidate, Config.Maximum_Iterations);
         end if;
         Iterations := Candidate;
      end Increase_Individual_Batch;

      procedure Increase_Batch
        (Fastest : Long_Float;
         Slowest : Long_Float)
      is
         Scale     : Long_Float;
         Candidate : Iteration_Count;
      begin
         if Batch_Iterations = Config.Maximum_Iterations
           or else Slowest >= Target_NS * 8.0
         then
            return;
         elsif Fastest <= 0.0 then
            Scale := 2.0;
         else
            Scale := Long_Float'Max (2.0, Target_NS / Fastest);
            Scale := Long_Float'Min (Scale, 2.0);
         end if;

         if Scale >= Long_Float (Config.Maximum_Iterations)
           / Long_Float (Batch_Iterations)
         then
            Candidate := Config.Maximum_Iterations;
         else
            Candidate :=
              Iteration_Count
                (Long_Float'Floor
                   (Long_Float (Batch_Iterations) * Scale));
            Candidate := Iteration_Count'Max (Candidate, Batch_Iterations + 1);
            Candidate :=
              Iteration_Count'Min (Candidate, Config.Maximum_Iterations);
         end if;
         Batch_Iterations := Candidate;
      end Increase_Batch;

      procedure Adjust_Timer_Cost (Elapsed : in out Long_Float) is
      begin
         if Config.Subtract_Timer_Cost and then Elapsed > Clock_Cost then
            Elapsed := Elapsed - Clock_Cost;
         end if;
      end Adjust_Timer_Cost;

   begin
      Validate (Config);
      Result := (others => <>);
      Notify (Config, Starting);
      Prepare_Environment (Config, Watch, Lock);
      Await_CPU_Quiescence (Config);
      Result.Reference_Data.Sample_Total := Config.Samples;
      Result.Contender_Data.Sample_Total := Config.Samples;
      Result.Reference_Data.Random_Seed_Value := Config.Random_Seed;
      Result.Contender_Data.Random_Seed_Value := Config.Random_Seed;
      Initialize_Metrics (Config, Result.Reference_Data);
      Initialize_Metrics (Config, Result.Contender_Data);
      Characterize_Clock
        (Backend             => Result.Reference_Data.Clock_Backend_Id,
         Nominal_Resolution  => Result.Reference_Data.Clock_Resolution,
         Observed_Resolution => Result.Reference_Data.Observed_Resolution,
         Minimum_Cost        => Clock_Cost,
         Median_Cost         => Result.Reference_Data.Median_Timer_Cost);
      Result.Contender_Data.Clock_Backend_Id :=
        Result.Reference_Data.Clock_Backend_Id;
      Result.Contender_Data.Clock_Resolution :=
        Result.Reference_Data.Clock_Resolution;
      Result.Contender_Data.Observed_Resolution :=
        Result.Reference_Data.Observed_Resolution;
      Result.Contender_Data.Median_Timer_Cost :=
        Result.Reference_Data.Median_Timer_Cost;
      Result.Reference_Data.Timer_Cost := Clock_Cost;
      Result.Contender_Data.Timer_Cost := Clock_Cost;
      Result.Practical_Threshold := Config.Practical_Threshold_Percent;
      Result.Random_Seed_Value := Config.Random_Seed;
      Target_NS :=
        Long_Float'Max
          (Long_Float (Config.Minimum_Sample_Time) * 1_000_000_000.0,
           Long_Float (Config.Measurement_Time) * 1_000_000_000.0
             / (2.0 * Long_Float (Config.Samples)));

      if Config.Warmup_Time > 0.0 then
         declare
            Started : constant Interfaces.Unsigned_64 := Clock_Now;
            Span : constant Interfaces.Unsigned_64 :=
              Duration_Nanoseconds (Config.Warmup_Time);
            Deadline : constant Interfaces.Unsigned_64 := Started + Span;
            Reference_Time : Long_Float;
            Contender_Time : Long_Float;
            Current : Interfaces.Unsigned_64;
         begin
            Notify (Config, Warming, 0, 100);
            loop
               Time_Pair
                 (Reference_First =>
                    Next_Random (Warmup_State) mod 2 = 0,
                  Reference_Time => Reference_Time,
                  Contender_Time => Contender_Time);
               if Config.Comparison_Batching = Equal_Time then
                  if Reference_Time < Target_NS * 0.5 then
                     Increase_Individual_Batch
                       (Reference_Iterations, Reference_Time);
                  end if;
                  if Contender_Time < Target_NS * 0.5 then
                     Increase_Individual_Batch
                       (Contender_Iterations, Contender_Time);
                  end if;
               elsif Long_Float'Min (Reference_Time, Contender_Time)
                       < Target_NS * 0.5
                 and then Long_Float'Max (Reference_Time, Contender_Time)
                       < Target_NS * 8.0
                 and then Batch_Iterations < Config.Maximum_Iterations
               then
                  Increase_Batch
                    (Fastest => Long_Float'Min
                       (Reference_Time, Contender_Time),
                     Slowest => Long_Float'Max
                       (Reference_Time, Contender_Time));
               end if;
               Current := Clock_Now;
               Notify
                 (Config, Warming,
                  Natural'Min
                    (100, Natural
                       (Long_Float'Floor
                          (100.0 * Long_Float (Current - Started)
                           / Long_Float (Span)))),
                  100);
               exit when Current >= Deadline;
            end loop;
         end;
      end if;

      Notify (Config, Calibrating);
      loop
         declare
            Reference_Time : Long_Float;
            Contender_Time : Long_Float;
         begin
            Time_Pair
              (Reference_First => Next_Random (Warmup_State) mod 2 = 0,
               Reference_Time => Reference_Time,
               Contender_Time => Contender_Time);
            if Config.Comparison_Batching = Equal_Time then
               if (Reference_Time >= Target_NS * 0.9
                   or else Reference_Iterations = Config.Maximum_Iterations)
                 and then
                   (Contender_Time >= Target_NS * 0.9
                    or else Contender_Iterations = Config.Maximum_Iterations)
               then
                  Calibration_Hits := Calibration_Hits + 1;
               else
                  Calibration_Hits := 0;
               end if;
               exit when Calibration_Hits >= 3;
               if Reference_Time < Target_NS * 0.9 then
                  Increase_Individual_Batch
                    (Reference_Iterations, Reference_Time);
               end if;
               if Contender_Time < Target_NS * 0.9 then
                  Increase_Individual_Batch
                    (Contender_Iterations, Contender_Time);
               end if;
            else
               if Long_Float'Min (Reference_Time, Contender_Time)
                 >= Target_NS * 0.9
               then
                  Calibration_Hits := Calibration_Hits + 1;
               else
                  Calibration_Hits := 0;
               end if;
               if Long_Float'Max (Reference_Time, Contender_Time)
                 >= Target_NS * 8.0
               then
                  Slow_Limit_Hits := Slow_Limit_Hits + 1;
               else
                  Slow_Limit_Hits := 0;
               end if;
               exit when Calibration_Hits >= 3
                 or else Slow_Limit_Hits >= 3
                 or else Batch_Iterations = Config.Maximum_Iterations;
               Increase_Batch
                 (Fastest => Long_Float'Min
                    (Reference_Time, Contender_Time),
                  Slowest => Long_Float'Max
                    (Reference_Time, Contender_Time));
            end if;
         end;
      end loop;

      Result.Reference_Data.Iterations := Reference_Count;
      Result.Contender_Data.Iterations := Contender_Count;
      Initialize_Perf (Config, Perf);
      declare
         Count  : constant Positive := Positive (Config.Samples);
         Orders : Order_Array (1 .. Count);
         State  : Interfaces.Unsigned_64 :=
           16#E703_7ED1_A0B4_28DB# xor
           Interfaces.Unsigned_64 (Config.Random_Seed);
      begin
         for Index in Orders'Range loop
            Orders (Index) := Index <= (Count + 1) / 2;
         end loop;
         for Index in reverse 2 .. Count loop
            declare
               Other : constant Positive :=
                 Positive
                   (Natural
                      (Next_Random (State)
                       mod Interfaces.Unsigned_64 (Index)) + 1);
               Saved : constant Boolean := Orders (Index);
            begin
               Orders (Index) := Orders (Other);
               Orders (Other) := Saved;
            end;
         end loop;

         declare
            Sampling_Started : constant Interfaces.Unsigned_64 := Clock_Now;
            Completed : Natural := 0;
            Total_Samples : constant Positive := Orders'Length;
            --  One unit is a complete pair, so a window never splits the two
            --  halves that make the comparison paired.
            Group : constant Positive := Units_Per_Window
              (Config, 2.0 * Target_NS, Total_Samples);
            Window_First : Positive := 1;
            Window_Last  : Positive;
            Action : Window_Action;

            procedure Collect_Pair (Index : Positive) is
               Reference_Time : Long_Float;
               Contender_Time : Long_Float;
               Reference_Probe : Sample_Probe_State;
               Contender_Probe : Sample_Probe_State;
            begin
               if Orders (Index) then
                  Start_Sample (Config, Perf, Reference_Probe);
                  Reference_Time := Time_Reference (Reference_Count);
                  Finish_Sample
                    (Config, Perf, Reference_Probe, Result.Reference_Data,
                     Sample_Index (Index), Reference_Count, Reference_Time);
                  Start_Sample (Config, Perf, Contender_Probe);
                  Contender_Time := Time_Contender (Contender_Count);
                  Finish_Sample
                    (Config, Perf, Contender_Probe, Result.Contender_Data,
                     Sample_Index (Index), Contender_Count, Contender_Time);
               else
                  Start_Sample (Config, Perf, Contender_Probe);
                  Contender_Time := Time_Contender (Contender_Count);
                  Finish_Sample
                    (Config, Perf, Contender_Probe, Result.Contender_Data,
                     Sample_Index (Index), Contender_Count, Contender_Time);
                  Start_Sample (Config, Perf, Reference_Probe);
                  Reference_Time := Time_Reference (Reference_Count);
                  Finish_Sample
                    (Config, Perf, Reference_Probe, Result.Reference_Data,
                     Sample_Index (Index), Reference_Count, Reference_Time);
               end if;
               Adjust_Timer_Cost (Reference_Time);
               Adjust_Timer_Cost (Contender_Time);
               Result.Reference_Data.Values (Sample_Index (Index)) :=
                 Reference_Time / Long_Float (Reference_Count);
               Result.Contender_Data.Values (Sample_Index (Index)) :=
                 Contender_Time / Long_Float (Contender_Count);
               Result.Reference_First_Order (Sample_Index (Index)) :=
                 Orders (Index);
               if Orders (Index) then
                  Result.Reference_First := Result.Reference_First + 1;
               else
                  Result.Contender_First := Result.Contender_First + 1;
               end if;
            end Collect_Pair;

            procedure Rewarm is
               Deadline : Interfaces.Unsigned_64;
               Reference_Time : Long_Float;
               Contender_Time : Long_Float;
            begin
               if Config.Interference.Rewarm_Time <= 0.0 then
                  return;
               end if;
               Deadline := Clock_Now
                 + Duration_Nanoseconds (Config.Interference.Rewarm_Time);
               Notify (Config, Warming, 0, 100);
               loop
                  Time_Pair
                    (Reference_First => True,
                     Reference_Time  => Reference_Time,
                     Contender_Time  => Contender_Time);
                  Escape (Reference_Time'Address);
                  Escape (Contender_Time'Address);
                  exit when Clock_Now >= Deadline;
               end loop;
               Notify (Config, Warming, 100, 100);
            end Rewarm;
         begin
         Notify (Config, Sampling, 0, Natural (Config.Samples));
         while Window_First <= Total_Samples loop
            Window_Last :=
              Positive'Min (Window_First + Group - 1, Total_Samples);
            loop
               declare
                  Saved_Reference : constant Telemetry_Snapshot :=
                    Save_Telemetry (Result.Reference_Data);
                  Saved_Contender : constant Telemetry_Snapshot :=
                    Save_Telemetry (Result.Contender_Data);
               begin
               Open_Interference_Window (Watch);
               for Index in Window_First .. Window_Last loop
                  Collect_Pair (Index);
                  Completed := Natural'Max (Completed, Index);
                  Notify
                    (Config, Sampling, Completed, Natural (Config.Samples));
               end loop;
               Judge_Window
                 (Config, Watch, Sample_Index (Window_First),
                  Sample_Index (Window_Last), Action);
               exit when Action = Accept_Window;
               --  Undo this pass's position tally and telemetry before
               --  collecting the same pairs again.
               for Index in Window_First .. Window_Last loop
                  if Orders (Index) then
                     Result.Reference_First := Result.Reference_First - 1;
                  else
                     Result.Contender_First := Result.Contender_First - 1;
                  end if;
               end loop;
               Restore_Telemetry (Result.Reference_Data, Saved_Reference);
               Restore_Telemetry (Result.Contender_Data, Saved_Contender);
               if Action = Settle_And_Retake then
                  Await_Foreign_Settle (Config, Watch);
                  Rewarm;
               end if;
               end;
            end loop;
            exit when Sampling_Limit_Reached
              (Config, Sampling_Started, Completed, Watch.Paused_Total);
            Window_First := Window_Last + 1;
         end loop;
         Result.Reference_Data.Sample_Total := Sample_Count (Completed);
         Result.Contender_Data.Sample_Total := Sample_Count (Completed);
         end;
      end;
      Apply_Environment (Watch, Result.Reference_Data);
      Apply_Environment (Watch, Result.Contender_Data);

      Notify (Config, Analyzing);
      Analyze (Result.Reference_Data);
      Analyze (Result.Contender_Data);
      Analyze_Metrics (Result.Reference_Data);
      Analyze_Metrics (Result.Contender_Data);
      Result.Reference_Data.Median_Batch :=
        Result.Reference_Data.Median * Long_Float (Reference_Count);
      Result.Contender_Data.Median_Batch :=
        Result.Contender_Data.Median * Long_Float (Contender_Count);
      Analyze_Comparison (Result);
      Notify (Config, Finished, 1, 1);
   end Compare_Core;

   procedure Measure
     (Config : Configuration := Default_Configuration;
      Result : out Measurement)
   is
      procedure Run_Batch (Iterations : Iteration_Count) is
      begin
         for Iteration in Iteration_Count range 1 .. Iterations loop
            Operation;
         end loop;
      end Run_Batch;

      procedure Nothing is null;

      procedure Run is new Measure_Core (Run_Batch, Nothing, Nothing);
   begin
      Run (Config, Result);
   end Measure;

   procedure Measure_Batched
     (Config : Configuration := Default_Configuration;
      Result : out Measurement)
   is
      procedure Nothing is null;
      procedure Run is new Measure_Core (Batch, Nothing, Nothing);
   begin
      Run (Config, Result);
   end Measure_Batched;

   procedure Measure_With_Hooks
     (Config : Configuration := Default_Configuration;
      Result : out Measurement)
   is
      procedure Run_Batch (Iterations : Iteration_Count) is
      begin
         for Iteration in Iteration_Count range 1 .. Iterations loop
            Operation;
         end loop;
      end Run_Batch;

      procedure Run is new Measure_Core (Run_Batch, Setup, Teardown);
   begin
      Run (Config, Result);
   end Measure_With_Hooks;

   procedure Measure_Result_Batched
     (Config : Configuration := Default_Configuration;
      Result : out Measurement)
   is
      Latest : aliased Element;

      procedure Run_Batch (Iterations : Iteration_Count) is
      begin
         Batch (Iterations, Latest);
      end Run_Batch;

      procedure Nothing is null;

      procedure Observe is
      begin
         Escape (Latest'Address);
      end Observe;

      procedure Run is new Measure_Core (Run_Batch, Nothing, Observe);
   begin
      Run (Config, Result);
   end Measure_Result_Batched;

   procedure Compare
     (Config : Configuration := Default_Configuration;
      Result : out Comparison)
   is
      procedure Run_Reference_Batch (Iterations : Iteration_Count) is
      begin
         for Iteration in Iteration_Count range 1 .. Iterations loop
            Reference_Operation;
         end loop;
      end Run_Reference_Batch;

      procedure Run_Contender_Batch (Iterations : Iteration_Count) is
      begin
         for Iteration in Iteration_Count range 1 .. Iterations loop
            Contender_Operation;
         end loop;
      end Run_Contender_Batch;

      procedure Run is new Compare_Core
        (Run_Reference_Batch, Run_Contender_Batch);
   begin
      Run (Config, Result);
   end Compare;

   procedure Compare_Batched
     (Config : Configuration := Default_Configuration;
      Result : out Comparison)
   is
      procedure Run is new Compare_Core (Reference_Batch, Contender_Batch);
   begin
      Run (Config, Result);
   end Compare_Batched;

   procedure Compare_Many
     (Config : Configuration := Default_Configuration;
      Result : out Multi_Comparison)
   is
      Count : constant Positive := Case_Id'Pos (Case_Id'Last) + 1;
      type Order_Array is array (Positive range <>) of Positive;
      type Position_Array is array (Positive range <>) of Positive;
      type Schedule_Array is
        array (Comparison_Case_Index, Sample_Index) of Boolean;
      type Case_Iteration_Array is
        array (Comparison_Case_Index) of Iteration_Count;
      type Case_Time_Array is array (Comparison_Case_Index) of Long_Float;

      Watch : Interference_Watch;
      Lock  : Host_Lock.Claim;

      Batch_Iterations : Iteration_Count := 1;
      Case_Iterations : Case_Iteration_Array := (others => 1);
      Target_NS : Long_Float;
      Case_Target_NS : Long_Float;
      Minimum_Case_NS : Long_Float;
      Clock_Cost : Long_Float;
      Calibration_Hits : Natural := 0;
      State : Interfaces.Unsigned_64 :=
        16#E703_7ED1_A0B4_28DB# xor
        Interfaces.Unsigned_64 (Config.Random_Seed);
      Collected_Samples : Natural := 0;
      Reference_First_Schedule : Schedule_Array := (others => (others => False));
      Perf : Perf_Handle;

      function Iterations_For
        (Index : Comparison_Case_Index) return Iteration_Count is
        (if Config.Comparison_Batching = Equal_Time
         then Case_Iterations (Index) else Batch_Iterations);

      function Progress_Case_Name (Which : Case_Id) return String is
         Result : String :=
           Ada.Characters.Handling.To_Lower (Case_Id'Image (Which));
      begin
         for Character of Result loop
            if Character = '_' then
               Character := ' ';
            end if;
         end loop;
         return Result;
      end Progress_Case_Name;

      procedure Notify_Case
        (Which     : Case_Id;
         Phase     : Progress_Phase;
         Completed : Natural;
         Total     : Natural)
      is
         Base_Name : constant String :=
           Ada.Strings.Unbounded.To_String (Config.Progress_Name);
         Case_Name : constant String := Progress_Case_Name (Which);
      begin
         if Config.Progress /= null then
            Config.Progress.all
              ((if Base_Name'Length = 0
                then Case_Name
                else Base_Name & " / " & Case_Name),
               Phase, Completed, Total);
         end if;
      end Notify_Case;

      function Time_One
        (Which      : Case_Id;
         Iterations : Iteration_Count) return Long_Float
      is
         Started : Interfaces.Unsigned_64;
         Finished : Interfaces.Unsigned_64;
      begin
         Memory_Barrier;
         Started := Clock_Now;
         Batch (Which, Iterations);
         Finished := Clock_Now;
         Memory_Barrier;
         return Elapsed_Nanoseconds (Started, Finished);
      end Time_One;

      procedure Time_Round
        (Fastest : out Long_Float;
         Total   : out Long_Float;
         Times   : out Case_Time_Array)
      is
      begin
         Fastest := Long_Float'Last;
         Total := 0.0;
         for Index in 1 .. Count loop
            declare
               Case_Index : constant Comparison_Case_Index :=
                 Comparison_Case_Index (Index);
               Elapsed : constant Long_Float :=
                 Time_One
                   (Case_Id'Val (Index - 1), Iterations_For (Case_Index));
            begin
               Times (Case_Index) := Elapsed;
               Fastest := Long_Float'Min (Fastest, Elapsed);
               Total := Total + Elapsed;
            end;
         end loop;
      end Time_Round;

      procedure Increase_Batch
        (Fastest : Long_Float;
         Total   : Long_Float)
      is
         Scale : Long_Float;
         Candidate : Iteration_Count;
      begin
         if Batch_Iterations = Config.Maximum_Iterations then
            return;
         elsif Fastest <= 0.0 or else Total <= 0.0 then
            Scale := 2.0;
         else
            Scale := Long_Float'Max
              (1.25, Long_Float'Max
                 (Target_NS / Total, Minimum_Case_NS / Fastest));
            Scale := Long_Float'Min (Scale, 2.0);
         end if;
         if Scale >= Long_Float (Config.Maximum_Iterations)
           / Long_Float (Batch_Iterations)
         then
            Candidate := Config.Maximum_Iterations;
         else
            Candidate :=
              Iteration_Count
                (Long_Float'Floor
                   (Long_Float (Batch_Iterations) * Scale));
            Candidate := Iteration_Count'Max (Candidate, Batch_Iterations + 1);
            Candidate :=
              Iteration_Count'Min (Candidate, Config.Maximum_Iterations);
         end if;
         Batch_Iterations := Candidate;
      end Increase_Batch;

      procedure Increase_Individual_Batch
        (Index   : Comparison_Case_Index;
         Elapsed : Long_Float)
      is
         Iterations : constant Iteration_Count := Case_Iterations (Index);
         Scale : Long_Float;
         Candidate : Iteration_Count;
      begin
         if Iterations = Config.Maximum_Iterations then
            return;
         elsif Elapsed <= 0.0 then
            Scale := 2.0;
         else
            Scale := Long_Float'Max (1.25, Case_Target_NS / Elapsed);
            Scale := Long_Float'Min (Scale, 2.0);
         end if;
         if Scale >= Long_Float (Config.Maximum_Iterations)
           / Long_Float (Iterations)
         then
            Candidate := Config.Maximum_Iterations;
         else
            Candidate :=
              Iteration_Count
                (Long_Float'Floor (Long_Float (Iterations) * Scale));
            Candidate := Iteration_Count'Max (Candidate, Iterations + 1);
            Candidate :=
              Iteration_Count'Min (Candidate, Config.Maximum_Iterations);
         end if;
         Case_Iterations (Index) := Candidate;
      end Increase_Individual_Batch;

      procedure Copy_Clock_Metadata
        (Source : Measurement;
         Target : in out Measurement) is
      begin
         Target.Timer_Cost := Source.Timer_Cost;
         Target.Median_Timer_Cost := Source.Median_Timer_Cost;
         Target.Clock_Resolution := Source.Clock_Resolution;
         Target.Observed_Resolution := Source.Observed_Resolution;
         Target.Clock_Backend_Id := Source.Clock_Backend_Id;
      end Copy_Clock_Metadata;
   begin
      Validate (Config);
      if Count < Comparison_Case_Count'First
        or else Count > Comparison_Case_Count'Last
      then
         raise Constraint_Error with
           "multi-way comparison requires two to sixteen cases";
      end if;
      Result := (others => <>);
      Result.Case_Total := Comparison_Case_Count (Count);
      Result.Schedule_Policy := Config.Shootout_Scheduling;
      Result.Batch_Policy := Config.Comparison_Batching;
      Notify (Config, Starting);
      Prepare_Environment (Config, Watch, Lock);
      Await_CPU_Quiescence (Config);
      for Index in 1 .. Count loop
         Result.Data (Comparison_Case_Index (Index)).Sample_Total :=
           Config.Samples;
         Result.Data (Comparison_Case_Index (Index)).Random_Seed_Value :=
           Config.Random_Seed;
         Initialize_Metrics
           (Config, Result.Data (Comparison_Case_Index (Index)));
      end loop;
      Characterize_Clock
        (Backend             => Result.Data (1).Clock_Backend_Id,
         Nominal_Resolution  => Result.Data (1).Clock_Resolution,
         Observed_Resolution => Result.Data (1).Observed_Resolution,
         Minimum_Cost        => Clock_Cost,
         Median_Cost         => Result.Data (1).Median_Timer_Cost);
      Result.Data (1).Timer_Cost := Clock_Cost;
      for Index in 2 .. Count loop
         Copy_Clock_Metadata
           (Result.Data (1), Result.Data (Comparison_Case_Index (Index)));
      end loop;
      Minimum_Case_NS :=
        Long_Float (Config.Minimum_Sample_Time) * 1_000_000_000.0;
      Case_Target_NS := Long_Float'Max
        (Minimum_Case_NS,
         Long_Float (Config.Measurement_Time) * 1_000_000_000.0
           / (Long_Float (Config.Samples) * Long_Float (Count)));
      Target_NS := Case_Target_NS * Long_Float (Count);

      if Config.Warmup_Time > 0.0 then
         declare
            Started : constant Interfaces.Unsigned_64 := Clock_Now;
            Span : constant Interfaces.Unsigned_64 :=
              Duration_Nanoseconds (Config.Warmup_Time);
            Deadline : constant Interfaces.Unsigned_64 := Started + Span;
            Current : Interfaces.Unsigned_64;
            Fastest : Long_Float;
            Total : Long_Float;
            Times : Case_Time_Array;
         begin
            Notify (Config, Warming, 0, 100);
            loop
               Time_Round (Fastest, Total, Times);
               if Config.Comparison_Batching = Equal_Time then
                  for Index in 1 .. Count loop
                     declare
                        Case_Index : constant Comparison_Case_Index :=
                          Comparison_Case_Index (Index);
                     begin
                        if Times (Case_Index) < Case_Target_NS * 0.5 then
                           Increase_Individual_Batch
                             (Case_Index, Times (Case_Index));
                        end if;
                     end;
                  end loop;
               elsif (Fastest < Minimum_Case_NS * 0.5
                   or else Total < Target_NS * 0.5)
                 and then Batch_Iterations < Config.Maximum_Iterations
               then
                  Increase_Batch (Fastest, Total);
               end if;
               Current := Clock_Now;
               Notify
                 (Config, Warming,
                  Natural'Min
                    (100, Natural
                       (Long_Float'Floor
                          (100.0 * Long_Float (Current - Started)
                           / Long_Float (Span)))),
                  100);
               exit when Current >= Deadline;
            end loop;
         end;
      end if;

      Notify (Config, Calibrating);
      loop
         declare
            Fastest : Long_Float;
            Total : Long_Float;
            Times : Case_Time_Array;
            All_Settled : Boolean := True;
         begin
            Time_Round (Fastest, Total, Times);
            if Config.Comparison_Batching = Equal_Time then
               for Index in 1 .. Count loop
                  declare
                     Case_Index : constant Comparison_Case_Index :=
                       Comparison_Case_Index (Index);
                  begin
                     if Times (Case_Index) < Case_Target_NS * 0.9
                       and then Case_Iterations (Case_Index)
                         < Config.Maximum_Iterations
                     then
                        All_Settled := False;
                        Increase_Individual_Batch
                          (Case_Index, Times (Case_Index));
                     end if;
                  end;
               end loop;
               if All_Settled then
                  Calibration_Hits := Calibration_Hits + 1;
               else
                  Calibration_Hits := 0;
               end if;
               exit when Calibration_Hits >= 3;
            elsif Fastest >= Minimum_Case_NS * 0.9
              and then Total >= Target_NS * 0.9
            then
               Calibration_Hits := Calibration_Hits + 1;
            else
               Calibration_Hits := 0;
            end if;
            if Config.Comparison_Batching = Shared_Iterations then
               exit when Calibration_Hits >= 3
                 or else Batch_Iterations = Config.Maximum_Iterations;
               Increase_Batch (Fastest, Total);
            end if;
         end;
      end loop;

      Initialize_Perf (Config, Perf);

      declare
         Base_Order : Order_Array (1 .. Count);
         Positions : Position_Array (1 .. Count);
         Completed : Natural := 0;
         Total : constant Natural := Natural (Config.Samples) * Count;
         Sampling_Started : Interfaces.Unsigned_64;
         type Collected_Array is
           array (Comparison_Case_Index) of Natural;
         Collected_By_Case : Collected_Array := (others => 0);

         procedure Collect_One
           (Case_Number : Positive;
            Sample      : Positive;
            Position    : Positive)
         is
            Case_Index : constant Comparison_Case_Index :=
              Comparison_Case_Index (Case_Number);
            Probe : Sample_Probe_State;
            Elapsed : Long_Float;
         begin
            Start_Sample (Config, Perf, Probe);
            Elapsed := Time_One
              (Case_Id'Val (Case_Number - 1), Iterations_For (Case_Index));
            Finish_Sample
              (Config, Perf, Probe, Result.Data (Case_Index),
               Sample_Index (Sample), Iterations_For (Case_Index), Elapsed);
            if Config.Subtract_Timer_Cost and then Elapsed > Clock_Cost then
               Elapsed := Elapsed - Clock_Cost;
            end if;
            Result.Data (Case_Index).Values (Sample_Index (Sample)) :=
              Elapsed / Long_Float (Iterations_For (Case_Index));
            Positions (Case_Number) := Position;
            Collected_By_Case (Case_Index) := Sample;
            Completed := Completed + 1;
            Notify_Case
              (Case_Id'Val (Case_Number - 1), Sampling, Completed, Total);
         end Collect_One;

         function Sequential_Limit_Reached
           (Started   : Interfaces.Unsigned_64;
            Completed : Natural;
            Excluded  : Interfaces.Unsigned_64 := 0) return Boolean
         is
            Elapsed : constant Interfaces.Unsigned_64 := Clock_Now - Started;
         begin
            return Config.Maximum_Sampling_Time > 0.0
              and then Completed >= Natural (Sample_Count'First)
              and then Elapsed >= Excluded
              and then Elapsed - Excluded
                >= Duration_Nanoseconds
                    (Config.Maximum_Sampling_Time / Count);
         end Sequential_Limit_Reached;
      begin
         for Index in Base_Order'Range loop
            Base_Order (Index) := Index;
         end loop;
         if Config.Shootout_Scheduling = Balanced_Rounds then
            for Index in reverse 2 .. Count loop
               declare
                  Other : constant Positive :=
                    Natural
                      (Next_Random (State)
                       mod Interfaces.Unsigned_64 (Index)) + 1;
                  Saved : constant Positive := Base_Order (Index);
               begin
                  Base_Order (Index) := Base_Order (Other);
                  Base_Order (Other) := Saved;
               end;
            end loop;

            Sampling_Started := Clock_Now;
            declare
               Total_Rounds : constant Positive := Natural (Config.Samples);
               --  One unit is a complete balanced round. Interference that
               --  arrives mid-round would otherwise be spread unevenly across
               --  the cases the round is meant to compare fairly.
               Group : constant Positive :=
                 Units_Per_Window (Config, Target_NS, Total_Rounds);
               Window_First : Positive := 1;
               Window_Last  : Positive;
               Action : Window_Action;

               procedure Collect_Round (Sample : Positive) is
               begin
                  for Position in 1 .. Count loop
                     declare
                        Base_Position : constant Positive :=
                          ((Position - 1 + Sample - 1) mod Count) + 1;
                        Case_Number : constant Positive :=
                          Base_Order (Base_Position);
                     begin
                        Collect_One (Case_Number, Sample, Position);
                     end;
                  end loop;
                  for Case_Number in 2 .. Count loop
                     Reference_First_Schedule
                       (Comparison_Case_Index (Case_Number),
                        Sample_Index (Sample)) :=
                          Positions (1) < Positions (Case_Number);
                  end loop;
               end Collect_Round;

               procedure Rewarm is
                  Deadline : Interfaces.Unsigned_64;
                  Fastest  : Long_Float;
                  Spent    : Long_Float;
                  Times    : Case_Time_Array;
               begin
                  if Config.Interference.Rewarm_Time <= 0.0 then
                     return;
                  end if;
                  Deadline := Clock_Now
                    + Duration_Nanoseconds (Config.Interference.Rewarm_Time);
                  Notify (Config, Warming, 0, 100);
                  loop
                     Time_Round (Fastest, Spent, Times);
                     Escape (Fastest'Address);
                     Escape (Spent'Address);
                     Escape (Times'Address);
                     exit when Clock_Now >= Deadline;
                  end loop;
                  Notify (Config, Warming, 100, 100);
               end Rewarm;
            begin
               while Window_First <= Total_Rounds loop
                  Window_Last :=
                    Positive'Min (Window_First + Group - 1, Total_Rounds);
                  loop
                     declare
                        type Snapshot_Array is
                          array (Comparison_Case_Index) of Telemetry_Snapshot;
                        Saved : Snapshot_Array;
                     begin
                     for Index in 1 .. Count loop
                        Saved (Comparison_Case_Index (Index)) := Save_Telemetry
                          (Result.Data (Comparison_Case_Index (Index)));
                     end loop;
                     Open_Interference_Window (Watch);
                     for Sample in Window_First .. Window_Last loop
                        Collect_Round (Sample);
                        Collected_Samples :=
                          Natural'Max (Collected_Samples, Sample);
                     end loop;
                     Judge_Window
                       (Config, Watch, Sample_Index (Window_First),
                        Sample_Index (Window_Last), Action);
                     exit when Action = Accept_Window;
                     --  Progress counts collected case batches, so a
                     --  discarded window must give its units back, and so
                     --  must every case's telemetry totals.
                     Completed := Completed
                       - Count * (Window_Last - Window_First + 1);
                     for Index in 1 .. Count loop
                        Restore_Telemetry
                          (Result.Data (Comparison_Case_Index (Index)),
                           Saved (Comparison_Case_Index (Index)));
                     end loop;
                     if Action = Settle_And_Retake then
                        Await_Foreign_Settle (Config, Watch);
                        Rewarm;
                     end if;
                     end;
                  end loop;
                  exit when Sampling_Limit_Reached
                    (Config, Sampling_Started, Collected_Samples,
                     Watch.Paused_Total);
                  Window_First := Window_Last + 1;
               end loop;
            end;
         else
            for Case_Number in 1 .. Count loop
               declare
                  Case_Started : constant Interfaces.Unsigned_64 := Clock_Now;
                  Case_Index : constant Comparison_Case_Index :=
                    Comparison_Case_Index (Case_Number);
                  Total_Samples : constant Positive :=
                    Natural (Config.Samples);
                  Group : constant Positive := Units_Per_Window
                    (Config, Case_Target_NS, Total_Samples);
                  Window_First : Positive := 1;
                  Window_Last  : Positive;
                  Action : Window_Action;
                  Paused_At_Case_Start : constant Interfaces.Unsigned_64 :=
                    Watch.Paused_Total;
                  Reached : Boolean := False;

                  procedure Rewarm is
                     Deadline : Interfaces.Unsigned_64;
                     Elapsed  : Long_Float;
                  begin
                     if Config.Interference.Rewarm_Time <= 0.0 then
                        return;
                     end if;
                     Deadline := Clock_Now + Duration_Nanoseconds
                       (Config.Interference.Rewarm_Time);
                     Notify (Config, Warming, 0, 100);
                     loop
                        Elapsed := Time_One
                          (Case_Id'Val (Case_Number - 1),
                           Iterations_For (Case_Index));
                        Escape (Elapsed'Address);
                        exit when Clock_Now >= Deadline;
                     end loop;
                     Notify (Config, Warming, 100, 100);
                  end Rewarm;
               begin
                  while Window_First <= Total_Samples and then not Reached loop
                     Window_Last := Positive'Min
                       (Window_First + Group - 1, Total_Samples);
                     loop
                        declare
                           Saved : constant Telemetry_Snapshot :=
                             Save_Telemetry (Result.Data (Case_Index));
                        begin
                        Open_Interference_Window (Watch);
                        for Sample in Window_First .. Window_Last loop
                           Collect_One (Case_Number, Sample, Case_Number);
                        end loop;
                        Judge_Window
                          (Config, Watch, Sample_Index (Window_First),
                           Sample_Index (Window_Last), Action);
                        exit when Action = Accept_Window;
                        Completed := Completed
                          - (Window_Last - Window_First + 1);
                        Restore_Telemetry (Result.Data (Case_Index), Saved);
                        if Action = Settle_And_Retake then
                           Await_Foreign_Settle (Config, Watch);
                           Rewarm;
                        end if;
                        end;
                     end loop;
                     Reached := Sequential_Limit_Reached
                       (Case_Started, Window_Last,
                        Watch.Paused_Total - Paused_At_Case_Start);
                     Window_First := Window_Last + 1;
                  end loop;
                  --  This case's windows are its own, so it keeps its own
                  --  per-sample values rather than the last case's.
                  Result.Data (Case_Index).Foreign_CPU := Watch.Foreign;
                  Watch.Foreign := (others => 0.0);
               end;
            end loop;
            Collected_Samples := Natural (Config.Samples);
            for Index in 1 .. Count loop
               Collected_Samples := Natural'Min
                 (Collected_Samples,
                  Collected_By_Case (Comparison_Case_Index (Index)));
            end loop;
            for Case_Number in 2 .. Count loop
               for Sample in 1 .. Collected_Samples loop
                  Reference_First_Schedule
                    (Comparison_Case_Index (Case_Number), Sample_Index (Sample)) :=
                      True;
               end loop;
            end loop;
         end if;
      end;

      Notify (Config, Analyzing);
      for Index in 1 .. Count loop
         declare
            Case_Index : constant Comparison_Case_Index :=
              Comparison_Case_Index (Index);
         begin
            Result.Data (Case_Index).Sample_Total :=
              Sample_Count (Collected_Samples);
            Result.Data (Case_Index).Iterations := Iterations_For (Case_Index);
            Apply_Environment
              (Watch, Result.Data (Case_Index),
               Include_Samples =>
                 Config.Shootout_Scheduling = Balanced_Rounds);
            Analyze (Result.Data (Case_Index));
            Analyze_Metrics (Result.Data (Case_Index));
            Result.Data (Case_Index).Median_Batch :=
              Result.Data (Case_Index).Median
                * Long_Float (Iterations_For (Case_Index));
         end;
      end loop;
      for Index in 2 .. Count loop
         declare
            Case_Index : constant Comparison_Case_Index :=
              Comparison_Case_Index (Index);
            Pair : Comparison := (others => <>);
         begin
            Pair.Reference_Data := Result.Data (1);
            Pair.Contender_Data := Result.Data (Case_Index);
            Pair.Practical_Threshold := Config.Practical_Threshold_Percent;
            Pair.Random_Seed_Value := Config.Random_Seed + Long_Long_Integer (Index);
            for Sample in 1 .. Collected_Samples loop
               Pair.Reference_First_Order (Sample_Index (Sample)) :=
                 Reference_First_Schedule
                   (Case_Index, Sample_Index (Sample));
               if Pair.Reference_First_Order (Sample_Index (Sample)) then
                  Pair.Reference_First := Pair.Reference_First + 1;
               else
                  Pair.Contender_First := Pair.Contender_First + 1;
               end if;
            end loop;
            Analyze_Comparison (Pair);
            Result.Against_Reference (Case_Index) := Pair;
         end;
      end loop;
      Notify (Config, Finished, 1, 1);
   end Compare_Many;

   function Iterations_Per_Sample
     (Result : Measurement) return Iteration_Count is (Result.Iterations);

   function Samples (Result : Measurement) return Sample_Count is
     (Result.Sample_Total);

   function Timer_Cost_Nanoseconds (Result : Measurement) return Long_Float is
     (Result.Timer_Cost);

   function Clock_Backend (Result : Measurement) return String is
   begin
      case Result.Clock_Backend_Id is
         when 1 => return "mach_absolute_time";
         when 2 => return "clock_gettime(CLOCK_MONOTONIC_RAW)";
         when others => return "unknown";
      end case;
   end Clock_Backend;

   function Clock_Resolution_Nanoseconds
     (Result : Measurement) return Long_Float is (Result.Clock_Resolution);

   function Observed_Clock_Resolution_Nanoseconds
     (Result : Measurement) return Long_Float is (Result.Observed_Resolution);

   function Median_Timer_Cost_Nanoseconds
     (Result : Measurement) return Long_Float is (Result.Median_Timer_Cost);

   function Median_Batch_Nanoseconds
     (Result : Measurement) return Long_Float is (Result.Median_Batch);

   function Quantization_Floor_Nanoseconds
     (Result : Measurement) return Long_Float is
     (Result.Clock_Resolution / Long_Float (Result.Iterations));

   function Minimum_Nanoseconds (Result : Measurement) return Long_Float is
     (Result.Minimum);

   function Maximum_Nanoseconds (Result : Measurement) return Long_Float is
     (Result.Maximum);

   function Mean_Nanoseconds (Result : Measurement) return Long_Float is
     (Result.Mean);

   function Median_Nanoseconds (Result : Measurement) return Long_Float is
     (Result.Median);

   function Standard_Deviation_Nanoseconds
     (Result : Measurement) return Long_Float is (Result.Standard_Deviation);

   function Median_Absolute_Deviation_Nanoseconds
     (Result : Measurement) return Long_Float is (Result.MAD);

   function P95_Nanoseconds (Result : Measurement) return Long_Float is
     (Result.P95);

   function P99_Nanoseconds (Result : Measurement) return Long_Float is
     (Result.P99);

   function Mean_Confidence_Low_Nanoseconds
     (Result : Measurement) return Long_Float is (Result.Confidence_Low);

   function Mean_Confidence_High_Nanoseconds
     (Result : Measurement) return Long_Float is (Result.Confidence_High);

   function Coefficient_Of_Variation_Percent
     (Result : Measurement) return Long_Float is (Result.CV_Percent);

   function Sample_Lag_One_Correlation
     (Result : Measurement) return Long_Float is (Result.Lag_One);

   function Environment (Result : Measurement) return Environment_Report is
     (Result.Environment_Data);

   function Sample_Foreign_CPU_Percent
     (Result : Measurement;
      Index  : Sample_Index) return Long_Float is
   begin
      if Index > Sample_Index (Result.Sample_Total) then
         raise Constraint_Error with
           "sample index exceeds the collected sample count";
      end if;
      return Result.Foreign_CPU (Index);
   end Sample_Foreign_CPU_Percent;

   function Outliers (Result : Measurement) return Outlier_Counts is
     (Result.Outlier_Total);

   function Sample_Nanoseconds
     (Result : Measurement;
      Index  : Sample_Index) return Long_Float
   is
   begin
      if Index > Result.Sample_Total then
         raise Constraint_Error with "sample index exceeds collected samples";
      end if;
      return Result.Values (Index);
   end Sample_Nanoseconds;

   function Metric_Name (Axis : Metric_Axis) return String is
   begin
      case Axis is
         when Wall_Time => return "wall time";
         when Process_CPU_Time => return "process CPU time";
         when Thread_CPU_Time => return "thread CPU time";
         when Process_RSS => return "process RSS";
         when Process_RSS_Change => return "process RSS change";
         when Minor_Page_Faults => return "minor page faults";
         when Major_Page_Faults => return "major page faults";
         when Voluntary_Context_Switches =>
            return "voluntary context switches";
         when Involuntary_Context_Switches =>
            return "involuntary context switches";
         when Disk_Read_Bytes => return "disk read bytes";
         when Disk_Written_Bytes => return "disk written bytes";
         when Filesystem_Input_Operations => return "filesystem input ops";
         when Filesystem_Output_Operations => return "filesystem output ops";
         when CPU_Cycles => return "CPU cycles";
         when Instructions => return "instructions";
         when Instructions_Per_Cycle => return "IPC";
         when Cache_Misses => return "cache misses";
         when Branches => return "branches";
         when Branch_Misses => return "branch misses";
         when Flyology_Dispatches => return "Flyology dispatches";
         when Flyology_Poll_Batches => return "Flyology poll batches";
         when Flyology_Poll_Events => return "Flyology poll events";
         when Flyology_Wakeups => return "Flyology wakeups";
         when Flyology_Migrations => return "Flyology migrations";
      end case;
   end Metric_Name;

   function Metric_Unit (Axis : Metric_Axis) return String is
   begin
      case Axis is
         when Wall_Time | Process_CPU_Time | Thread_CPU_Time =>
            return "ns/op";
         when Process_RSS =>
            return "bytes";
         when Process_RSS_Change | Disk_Read_Bytes | Disk_Written_Bytes =>
            return "bytes/op";
         when Minor_Page_Faults | Major_Page_Faults =>
            return "faults/op";
         when Voluntary_Context_Switches |
              Involuntary_Context_Switches =>
            return "switches/op";
         when Filesystem_Input_Operations |
              Filesystem_Output_Operations =>
            return "I/O ops/op";
         when CPU_Cycles =>
            return "cycles/op";
         when Instructions =>
            return "instructions/op";
         when Instructions_Per_Cycle =>
            return "instructions/cycle";
         when Cache_Misses =>
            return "misses/op";
         when Branches =>
            return "branches/op";
         when Branch_Misses =>
            return "misses/op";
         when Flyology_Dispatches | Flyology_Poll_Batches |
              Flyology_Poll_Events | Flyology_Wakeups |
              Flyology_Migrations =>
            return "events/op";
      end case;
   end Metric_Unit;

   function Scope (Axis : Metric_Axis) return Metric_Scope is
   begin
      case Axis is
         when Wall_Time =>
            return Batch_Wall_Clock;
         when Thread_CPU_Time | CPU_Cycles | Instructions |
              Instructions_Per_Cycle | Cache_Misses | Branches |
              Branch_Misses =>
            if Axis = Thread_CPU_Time then
               return Current_Native_Thread;
            end if;
            return Native_Task_Tree;
         when Flyology_Dispatches | Flyology_Poll_Batches |
              Flyology_Poll_Events | Flyology_Wakeups |
              Flyology_Migrations =>
            return Flyology_Runtime;
         when others =>
            return Benchmark_Process;
      end case;
   end Scope;

   function Direction (Axis : Metric_Axis) return Metric_Direction is
   begin
      case Axis is
         when Instructions_Per_Cycle =>
            return Higher_Is_Better;
         when Process_RSS | Instructions | Branches | Flyology_Dispatches |
              Flyology_Poll_Batches | Flyology_Poll_Events |
              Flyology_Wakeups | Flyology_Migrations =>
            return Diagnostic;
         when others =>
            return Lower_Is_Better;
      end case;
   end Direction;

   function Metric_Available
     (Result : Measurement;
      Axis   : Metric_Axis) return Boolean is
     (Result.Metric_Data.Data /= null
      and then Result.Metric_Data.Data.Requested (Axis)
      and then Result.Metric_Data.Data.Available (Axis)
      and then Result.Metric_Data.Data.Summaries (Axis).Available);

   function Metric_Status
     (Result : Measurement;
      Axis   : Metric_Axis) return Metric_Availability is
     (if Result.Metric_Data.Data = null
      then Metric_Not_Requested
      else Result.Metric_Data.Data.Status (Axis));

   function Metric_Requested
     (Result : Measurement;
      Axis   : Metric_Axis) return Boolean is
     (Result.Metric_Data.Data /= null
      and then Result.Metric_Data.Data.Requested (Axis));

   function Metric_Sample
     (Result : Measurement;
      Axis   : Metric_Axis;
      Index  : Sample_Index) return Long_Float
   is
   begin
      if not Metric_Available (Result, Axis) then
         raise Constraint_Error with "metric axis is unavailable";
      elsif Index > Result.Sample_Total then
         raise Constraint_Error with
           "metric sample index exceeds collected samples";
      end if;
      return Result.Metric_Data.Data.Values (Axis, Index);
   end Metric_Sample;

   function Metric_Statistics
     (Result : Measurement;
      Axis   : Metric_Axis) return Metric_Summary is
   begin
      if not Metric_Available (Result, Axis) then
         return (others => <>);
      end if;
      return Result.Metric_Data.Data.Summaries (Axis);
   end Metric_Statistics;

   function Reference_Measurement (Result : Comparison) return Measurement is
     (Result.Reference_Data);

   function Contender_Measurement (Result : Comparison) return Measurement is
     (Result.Contender_Data);

   function Geometric_Mean_Speedup (Result : Comparison) return Long_Float is
     (Result.Geometric_Speedup);

   function Median_Speedup (Result : Comparison) return Long_Float is
     (Result.Median_Speedup_Value);

   function Speedup_Confidence_Low
     (Result : Comparison) return Long_Float is (Result.Speedup_CI_Low);

   function Speedup_Confidence_High
     (Result : Comparison) return Long_Float is (Result.Speedup_CI_High);

   function Relative_Time_Change_Percent
     (Result : Comparison) return Long_Float is
     (100.0 * (1.0 / Result.Geometric_Speedup - 1.0));

   function Relative_Time_Change_Confidence_Low
     (Result : Comparison) return Long_Float is
     (100.0 * (1.0 / Result.Speedup_CI_High - 1.0));

   function Relative_Time_Change_Confidence_High
     (Result : Comparison) return Long_Float is
     (100.0 * (1.0 / Result.Speedup_CI_Low - 1.0));

   function Verdict (Result : Comparison) return Comparison_Verdict is
     (Result.Verdict_Value);

   function Practical_Threshold_Percent
     (Result : Comparison) return Long_Float is (Result.Practical_Threshold);

   function Order_Effect_Percent (Result : Comparison) return Long_Float is
     (Result.Order_Effect);

   function Lag_One_Correlation (Result : Comparison) return Long_Float is
     (Result.Lag_One);

   function Mean_Time_Difference_Nanoseconds
     (Result : Comparison) return Long_Float is (Result.Mean_Time_Difference);

   function Contender_Wins (Result : Comparison) return Natural is
     (Result.Contender_Win_Total);

   function Reference_Wins (Result : Comparison) return Natural is
     (Result.Reference_Win_Total);

   function Ties (Result : Comparison) return Natural is (Result.Tie_Total);

   function Compare_Metric
     (Result : Comparison;
      Axis   : Metric_Axis) return Metric_Comparison_Result is
     (Result.Metric_Comparisons (Axis));

   function Reference_First_Samples (Result : Comparison) return Natural is
     (Result.Reference_First);

   function Contender_First_Samples (Result : Comparison) return Natural is
     (Result.Contender_First);

   function Sample_Speedup
     (Result : Comparison;
      Index  : Sample_Index) return Long_Float
   is
   begin
      if Index > Result.Reference_Data.Sample_Total then
         raise Constraint_Error with
           "sample index exceeds collected comparison samples";
      end if;
      return Result.Speedup_Values (Index);
   end Sample_Speedup;

   function Cases (Result : Multi_Comparison) return Comparison_Case_Count is
     (Result.Case_Total);

   function Shootout_Schedule
     (Result : Multi_Comparison) return Shootout_Schedule_Policy is
     (Result.Schedule_Policy);

   function Shootout_Batching
     (Result : Multi_Comparison) return Comparison_Batch_Policy is
     (Result.Batch_Policy);

   function Case_Measurement
     (Result : Multi_Comparison;
      Index  : Comparison_Case_Index) return Measurement
   is
   begin
      if Index > Comparison_Case_Index (Result.Case_Total) then
         raise Constraint_Error with
           "case index exceeds multi-way comparison cases";
      end if;
      return Result.Data (Index);
   end Case_Measurement;

   function Versus_Reference
     (Result : Multi_Comparison;
      Index  : Comparison_Case_Index) return Comparison
   is
   begin
      if Index = 1 or else Index > Comparison_Case_Index (Result.Case_Total) then
         raise Constraint_Error with
           "contender index must select a measured non-reference case";
      end if;
      return Result.Against_Reference (Index);
   end Versus_Reference;

   procedure Do_Not_Optimize (Value : in out Element) is
   begin
      Escape (Value'Address);
   end Do_Not_Optimize;

   procedure Clobber_Memory is
   begin
      Memory_Barrier;
   end Clobber_Memory;
end Flyology_Bench;
