--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Characters.Latin_1;
with Ada.Containers.Generic_Array_Sort;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology_Bench_Internal_Probes;

package body Flyology_Bench.Recording is
   use Flyology_Bench_Internal_Probes;
   use type Interfaces.Unsigned_64;
   use type Interfaces.C.int;

   Bootstrap_Resamples : constant := 2_000;

   function To_Fixed (Value : String) return Fixed_Name is
      Result : Fixed_Name;
      Count  : constant Natural := Natural'Min
        (Value'Length, Maximum_Name_Length);
   begin
      Result.Length := Count;
      if Count > 0 then
         for Index in 1 .. Count loop
            Result.Data (Index) := Value (Value'First + Index - 1);
         end loop;
      end if;
      return Result;
   end To_Fixed;

   function To_String (Value : Fixed_Name) return String is
     (if Value.Length = 0 then ""
      else String (Value.Data (1 .. Value.Length)));

   procedure Read_Resources
     (Values : out Resource_Values;
      Mask   : out Interfaces.Unsigned_64;
      OK     : out Boolean)
   is
      Native : Native_Resource_Values := [others => 0];
   begin
      Read_Resource_Snapshot (Native, Mask, OK);
      for Index in Values'Range loop
         Values (Index) := Native (Index);
      end loop;
   end Read_Resources;

   function Resource_Metrics_Requested (Set : Metric_Set) return Boolean is
   begin
      for Axis in Process_CPU_Time .. Filesystem_Output_Operations loop
         if Set (Axis) then
            return True;
         end if;
      end loop;
      return False;
   end Resource_Metrics_Requested;

   function Scheduler_Metrics_Requested (Set : Metric_Set) return Boolean is
   begin
      for Axis in Flyology_Dispatches .. Flyology_Migrations loop
         if Set (Axis) then
            return True;
         end if;
      end loop;
      return False;
   end Scheduler_Metrics_Requested;

   function Hardware_Mask (Set : Metric_Set) return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      for Axis in CPU_Cycles .. Branch_Misses loop
         if Set (Axis) and then Axis /= Instructions_Per_Cycle then
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
               Result := Result or Interfaces.Shift_Left
                 (Interfaces.Unsigned_64'(1), Index);
            end;
         end if;
      end loop;
      if Set (Instructions_Per_Cycle) then
         Result := Result or 3;
      end if;
      return Result;
   end Hardware_Mask;

   subtype Raw_Sample is Recorded_Sample;
   subtype Raw_Sample_Array is Recorded_Sample_Array;

   type Live_Data is record
      Observed  : Natural := 0;
      Retained  : Natural := 0;
      In_Flight : Natural := 0;
      Failures  : Natural := 0;
      Abandoned : Natural := 0;
      Median_NS : Long_Float := 0.0;
      P95_NS    : Long_Float := 0.0;
      Mean_CPU  : Long_Float := 0.0;
      RSS_Bytes : Long_Float := 0.0;
   end record;

   protected type Sample_Store (Capacity : Retained_Capacity) is
      procedure Begin_Span;
      procedure Finish_Span
        (Value   : Raw_Sample;
         Outcome : Sample_Outcome;
         Policy  : Retention_Policy;
         Seed    : Long_Long_Integer);
      procedure Abandon_Span;
      procedure Copy_To
        (Target     : in out Recorded_Measurement;
         Requested  : Metric_Set;
         Elapsed_NS : Interfaces.Unsigned_64);
      procedure Current (Data : out Live_Data);
   private
      Data             : Raw_Sample_Array (1 .. Capacity);
      Observed_Total   : Natural := 0;
      Retained_Total   : Natural := 0;
      In_Flight_Total  : Natural := 0;
      Abandoned_Total  : Natural := 0;
      Outcome_Totals   : Outcome_Array := [others => 0];
      Reservoir_State  : Interfaces.Unsigned_64 := 0;
      Reservoir_Ready  : Boolean := False;
   end Sample_Store;

   function Next_Random
     (State : in out Interfaces.Unsigned_64) return Interfaces.Unsigned_64 is
   begin
      State := State xor Interfaces.Shift_Left (State, 13);
      State := State xor Interfaces.Shift_Right (State, 7);
      State := State xor Interfaces.Shift_Left (State, 17);
      return State;
   end Next_Random;

   type Float_Array is array (Positive range <>) of Long_Float;

   procedure Sort is new Ada.Containers.Generic_Array_Sort
     (Index_Type   => Positive,
      Element_Type => Long_Float,
      Array_Type   => Float_Array);

   function Percentile
     (Ordered : Float_Array;
      P       : Long_Float) return Long_Float
   is
      Position : constant Long_Float :=
        Long_Float (Ordered'First) + P * Long_Float (Ordered'Length - 1);
      Lower    : constant Positive := Positive (Long_Float'Floor (Position));
      Upper    : constant Positive := Positive (Long_Float'Ceiling (Position));
      Fraction : constant Long_Float := Position - Long_Float (Lower);
   begin
      return Ordered (Lower)
        + Fraction * (Ordered (Upper) - Ordered (Lower));
   end Percentile;

   protected body Sample_Store is
      procedure Begin_Span is
      begin
         In_Flight_Total := In_Flight_Total + 1;
      end Begin_Span;

      procedure Finish_Span
        (Value   : Raw_Sample;
         Outcome : Sample_Outcome;
         Policy  : Retention_Policy;
         Seed    : Long_Long_Integer)
      is
         Slot   : Natural := 0;
         Stored : Raw_Sample := Value;
      begin
         if In_Flight_Total > 0 then
            In_Flight_Total := In_Flight_Total - 1;
         end if;
         Observed_Total := Observed_Total + 1;
         Outcome_Totals (Outcome) := Outcome_Totals (Outcome) + 1;
         Stored.Observation := Observed_Total;
         Stored.Outcome := Outcome;

         if Retained_Total < Natural (Capacity) then
            Retained_Total := Retained_Total + 1;
            Slot := Retained_Total;
         else
            case Policy is
               when First_N =>
                  Slot := 0;
               when Latest_N =>
                  Slot := ((Observed_Total - 1) mod Natural (Capacity)) + 1;
               when Reservoir =>
                  if not Reservoir_Ready then
                     Reservoir_State := Interfaces.Unsigned_64 (Seed)
                       xor 16#9E37_79B9_7F4A_7C15#;
                     if Reservoir_State = 0 then
                        Reservoir_State := 16#D1B5_4A32_D192_ED03#;
                     end if;
                     Reservoir_Ready := True;
                  end if;
                  Slot := Natural
                    (Next_Random (Reservoir_State)
                     mod Interfaces.Unsigned_64 (Observed_Total)) + 1;
                  if Slot > Natural (Capacity) then
                     Slot := 0;
                  end if;
            end case;
         end if;
         if Slot /= 0 then
            Data (Slot) := Stored;
         end if;
      end Finish_Span;

      procedure Abandon_Span is
      begin
         if In_Flight_Total > 0 then
            In_Flight_Total := In_Flight_Total - 1;
         end if;
         Abandoned_Total := Abandoned_Total + 1;
      end Abandon_Span;

      procedure Copy_To
        (Target     : in out Recorded_Measurement;
         Requested  : Metric_Set;
         Elapsed_NS : Interfaces.Unsigned_64)
      is
      begin
         Target.Observed_Total := Observed_Total;
         Target.Retained_Total := Retained_Total;
         Target.Dropped_Total := Observed_Total - Retained_Total;
         Target.In_Flight_Total := In_Flight_Total;
         Target.Abandoned_Total := Abandoned_Total;
         Target.Outcome_Totals := Outcome_Totals;
         Target.Elapsed_NS := Elapsed_NS;
         Target.Requested := Requested;
         for Index in 1 .. Retained_Total loop
            Target.Samples (Index) := Data (Index);
         end loop;

         for Axis in Metric_Axis loop
            Target.Valid_Counts (Axis) := 0;
            Target.Invalid_Counts (Axis) := 0;
            Target.Scope_Changed (Axis) := 0;
            if not Requested (Axis) then
               Target.Statuses (Axis) := Metric_Not_Requested;
            else
               Target.Statuses (Axis) := Probe_Failed;
               for Index in 1 .. Retained_Total loop
                  if Data (Index).Scope_Changed (Axis) then
                     Target.Scope_Changed (Axis) :=
                       Target.Scope_Changed (Axis) + 1;
                  end if;
                  if Data (Index).Valid (Axis) then
                     Target.Valid_Counts (Axis) :=
                       Target.Valid_Counts (Axis) + 1;
                     Target.Values (Axis)
                       (Target.Valid_Counts (Axis)) := Data (Index).Values (Axis);
                  else
                     Target.Invalid_Counts (Axis) :=
                       Target.Invalid_Counts (Axis) + 1;
                     if Target.Valid_Counts (Axis) = 0
                       and then Data (Index).Status (Axis)
                         /= Metric_Not_Requested
                     then
                        Target.Statuses (Axis) := Data (Index).Status (Axis);
                     end if;
                  end if;
               end loop;
               if Target.Valid_Counts (Axis) = Retained_Total
                 and then Retained_Total > 0
               then
                  Target.Statuses (Axis) := Metric_Collected;
               elsif Target.Valid_Counts (Axis) > 0 then
                  Target.Statuses (Axis) := Metric_Partially_Collected;
               end if;
            end if;
         end loop;
      end Copy_To;

      procedure Current (Data : out Live_Data) is
         Wall_Count : Natural := 0;
         CPU_Count  : Natural := 0;
         Window     : constant Natural := Natural'Min (Retained_Total, 128);
         First      : constant Natural := Retained_Total - Window + 1;
         Wall       : Float_Array (1 .. Natural'Max (1, Window));
         CPU_Sum    : Long_Float := 0.0;
      begin
         Data := (others => <>);
         Data.Observed := Observed_Total;
         Data.Retained := Retained_Total;
         Data.In_Flight := In_Flight_Total;
         Data.Failures := Outcome_Totals (Failure) + Outcome_Totals (Timeout)
           + Outcome_Totals (Cancelled);
         Data.Abandoned := Abandoned_Total;
         for Index in First .. Retained_Total loop
            if Sample_Store.Data (Index).Valid (Wall_Time) then
               Wall_Count := Wall_Count + 1;
               Wall (Wall_Count) := Sample_Store.Data (Index).Values (Wall_Time);
            end if;
            if Sample_Store.Data (Index).Valid (Process_CPU_Time)
              and then Sample_Store.Data (Index).Valid (Wall_Time)
              and then Sample_Store.Data (Index).Values (Wall_Time) > 0.0
            then
               CPU_Count := CPU_Count + 1;
               CPU_Sum := CPU_Sum
                 + 100.0 * Sample_Store.Data (Index).Values (Process_CPU_Time)
                   / Sample_Store.Data (Index).Values (Wall_Time);
            end if;
            if Sample_Store.Data (Index).Valid (Process_RSS) then
               Data.RSS_Bytes := Sample_Store.Data (Index).Values (Process_RSS);
            end if;
         end loop;
         if Wall_Count > 0 then
            declare
               Ordered : Float_Array (1 .. Wall_Count);
            begin
               Ordered := Wall (1 .. Wall_Count);
               Sort (Ordered);
               Data.Median_NS := Percentile (Ordered, 0.5);
               Data.P95_NS := Percentile (Ordered, 0.95);
            end;
         end if;
         if CPU_Count > 0 then
            Data.Mean_CPU := CPU_Sum / Long_Float (CPU_Count);
         end if;
      end Current;
   end Sample_Store;

   type Sample_Store_Access is access Sample_Store;
   type Store_Array is
     array (Benchmark_Capacity range <>) of Sample_Store_Access;
   type Name_Array is array (Benchmark_Capacity range <>) of Fixed_Name;

   protected type Session_Control is
      procedure Register (Allowed : out Boolean);
      procedure Reserve_Start (Allowed : out Boolean);
      procedure Commit_Start (Timestamp : Interfaces.Unsigned_64);
      procedure Cancel_Start;
      procedure Stop (Timestamp : Interfaces.Unsigned_64);
      procedure Begin_Span
        (Allowed    : out Boolean;
         Overlapped : out Boolean);
      procedure End_Span;
      procedure Claim_Perf_Close (Claimed : out Boolean);
      function Running return Boolean;
      procedure Times
        (Started : out Interfaces.Unsigned_64;
         Ended   : out Interfaces.Unsigned_64;
         Active  : out Boolean);
   private
      Is_Running       : Boolean := False;
      Is_Starting      : Boolean := False;
      Ever_Started     : Boolean := False;
      Active_Total     : Natural := 0;
      Started_At       : Interfaces.Unsigned_64 := 0;
      Ended_At         : Interfaces.Unsigned_64 := 0;
      Perf_Close_Claimed : Boolean := False;
   end Session_Control;

   protected body Session_Control is
      procedure Register (Allowed : out Boolean) is
      begin
         Allowed := not Is_Running
           and then not Is_Starting
           and then not Ever_Started;
      end Register;

      procedure Reserve_Start (Allowed : out Boolean) is
      begin
         Allowed := not Is_Running
           and then not Is_Starting
           and then not Ever_Started;
         if Allowed then
            Is_Starting := True;
         end if;
      end Reserve_Start;

      procedure Commit_Start (Timestamp : Interfaces.Unsigned_64) is
      begin
         if not Is_Starting then
            raise Program_Error with "recording start was not reserved";
         end if;
         Is_Starting := False;
         Is_Running := True;
         Ever_Started := True;
         Started_At := Timestamp;
         Ended_At := 0;
      end Commit_Start;

      procedure Cancel_Start is
      begin
         Is_Starting := False;
      end Cancel_Start;

      procedure Stop (Timestamp : Interfaces.Unsigned_64) is
      begin
         if Is_Running then
            Is_Running := False;
            Ended_At := Timestamp;
         end if;
      end Stop;

      procedure Begin_Span
        (Allowed    : out Boolean;
         Overlapped : out Boolean) is
      begin
         Allowed := Is_Running;
         Overlapped := Active_Total > 0;
         if Allowed then
            Active_Total := Active_Total + 1;
         end if;
      end Begin_Span;

      procedure End_Span is
      begin
         if Active_Total > 0 then
            Active_Total := Active_Total - 1;
         end if;
      end End_Span;

      procedure Claim_Perf_Close (Claimed : out Boolean) is
      begin
         Claimed := Ever_Started
           and then not Is_Running
           and then Active_Total = 0
           and then not Perf_Close_Claimed;
         if Claimed then
            Perf_Close_Claimed := True;
         end if;
      end Claim_Perf_Close;

      function Running return Boolean is (Is_Running);

      procedure Times
        (Started : out Interfaces.Unsigned_64;
         Ended   : out Interfaces.Unsigned_64;
         Active  : out Boolean) is
      begin
         Started := Started_At;
         Ended := Ended_At;
         Active := Is_Running;
      end Times;
   end Session_Control;

   type Concrete_Backend
     (Maximum : Benchmark_Capacity;
      Capacity : Retained_Capacity) is limited new Recorder_Backend with record
      Control : Session_Control;
      Count   : Natural := 0;
      Stores  : Store_Array (1 .. Maximum) := [others => null];
      Names   : Name_Array (1 .. Maximum);
      Config  : Configuration := Default_Configuration;
      Perf_Session : aliased Interfaces.Unsigned_64 := 0;
   end record;
   type Concrete_Backend_Access is access all Concrete_Backend;

   function Backend (Object : Recorder) return Concrete_Backend_Access is
     (Concrete_Backend_Access (Object.Guard.Backend));

   procedure Close_Perf_When_Quiescent (Data : Concrete_Backend_Access) is
      Claimed : Boolean;
   begin
      Data.Control.Claim_Perf_Close (Claimed);
      if Claimed and then Data.Perf_Session /= 0 then
         Native_Recording_Perf_Stop (Data.Perf_Session);
         Data.Perf_Session := 0;
      end if;
   end Close_Perf_When_Quiescent;

   procedure Free_Backend is new Ada.Unchecked_Deallocation
     (Concrete_Backend, Concrete_Backend_Access);
   procedure Free_Store is new Ada.Unchecked_Deallocation
     (Sample_Store, Sample_Store_Access);
   procedure Free_Values is new Ada.Unchecked_Deallocation
     (Metric_Value_Array, Metric_Value_Array_Access);
   procedure Free_Samples is new Ada.Unchecked_Deallocation
     (Recorded_Sample_Array, Recorded_Sample_Array_Access);

   procedure Analyze (Result : in out Recorded_Measurement) is
   begin
      for Axis in Metric_Axis loop
         if Result.Valid_Counts (Axis) > 0 then
            declare
               Count   : constant Positive := Result.Valid_Counts (Axis);
               Ordered : Float_Array (1 .. Count);
               Means   : Float_Array (1 .. Bootstrap_Resamples);
               Sum     : Long_Float := 0.0;
               Random  : Interfaces.Unsigned_64 :=
                 16#243F_6A88_85A3_08D3#
                 xor Interfaces.Unsigned_64 (Metric_Axis'Pos (Axis) + 1);
               Summary : Metric_Summary;
            begin
               for Index in Ordered'Range loop
                  Ordered (Index) := Result.Values (Axis) (Index);
                  Sum := Sum + Ordered (Index);
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
                  for Draw in 1 .. Count loop
                     Sum := Sum + Result.Values (Axis)
                       (Natural
                         (Next_Random (Random)
                          mod Interfaces.Unsigned_64 (Count)) + 1);
                  end loop;
                  Means (Resample) := Sum / Long_Float (Count);
               end loop;
               Sort (Means);
               Summary.Confidence_Low := Percentile (Means, 0.025);
               Summary.Confidence_High := Percentile (Means, 0.975);
               Result.Summaries (Axis) := Summary;
            end;
         end if;
      end loop;
   end Analyze;

   procedure Stop_Dashboard (Object : in out Dashboard_Backend_Access);

   overriding procedure Initialize (Object : in out Recorder_Guard) is
   begin
      Object.Backend := new Concrete_Backend
        (Object.Maximum_Benchmarks, Object.Retained_Samples);
   end Initialize;

   overriding procedure Finalize (Object : in out Recorder_Guard) is
      Data : Concrete_Backend_Access;
   begin
      if Object.Dashboard /= null then
         Stop_Dashboard (Object.Dashboard);
      end if;
      if Object.Backend = null then
         return;
      end if;
      Data := Concrete_Backend_Access (Object.Backend);
      Data.Control.Stop (Clock_Now);
      Close_Perf_When_Quiescent (Data);
      if Data.Perf_Session /= 0 then
         Native_Recording_Perf_Stop (Data.Perf_Session);
         Data.Perf_Session := 0;
      end if;
      for Index in 1 .. Data.Count loop
         Free_Store (Data.Stores (Benchmark_Capacity (Index)));
      end loop;
      Object.Backend := null;
      Free_Backend (Data);
   end Finalize;

   procedure Register
     (Object : in out Recorder;
      Name   : String;
      Item   : out Benchmark)
   is
      Data    : constant Concrete_Backend_Access := Backend (Object);
      Allowed : Boolean;
   begin
      if Data.Count = Natural (Data.Maximum) then
         raise Too_Many_Benchmarks;
      end if;
      Data.Control.Register (Allowed);
      if not Allowed then
         raise Registration_Closed;
      end if;
      Data.Count := Data.Count + 1;
      Data.Names (Benchmark_Capacity (Data.Count)) := To_Fixed (Name);
      Data.Stores (Benchmark_Capacity (Data.Count)) :=
        new Sample_Store (Data.Capacity);
      Item :=
         (Owner      => Object.Guard.Backend,
         Identifier => Data.Count,
         Label      => Data.Names (Benchmark_Capacity (Data.Count)));
   end Register;

   procedure Start
     (Object : in out Recorder;
      Config : Configuration := Default_Configuration)
   is
      Data    : constant Concrete_Backend_Access := Backend (Object);
      Allowed : Boolean;
   begin
      if Data.Count = 0 then
         raise Invalid_Benchmark with "register at least one benchmark";
      end if;
      Data.Control.Reserve_Start (Allowed);
      if not Allowed then
         raise Recording_Already_Started;
      end if;
      begin
         Data.Config := Config;
         Data.Perf_Session := 0;
         declare
            Requested : constant Interfaces.Unsigned_64 :=
              Hardware_Mask (Config.Metrics);
         begin
            if Requested /= 0
              and then Native_Recording_Perf_Start
                (Requested, Data.Perf_Session'Access) /= 0
            then
               Data.Perf_Session := 0;
            end if;
         end;
         Data.Control.Commit_Start (Clock_Now);
      exception
         when others =>
            if Data.Perf_Session /= 0 then
               Native_Recording_Perf_Stop (Data.Perf_Session);
               Data.Perf_Session := 0;
            end if;
            Data.Control.Cancel_Start;
            raise;
      end;
   end Start;

   procedure Stop (Object : in out Recorder) is
      Data : constant Concrete_Backend_Access := Backend (Object);
   begin
      Data.Control.Stop (Clock_Now);
      Close_Perf_When_Quiescent (Data);
   end Stop;

   procedure Begin_Sample
     (Object : in out Recorder;
      Item   : Benchmark;
      Value  : in out Span)
   is
      Data       : constant Concrete_Backend_Access := Backend (Object);
      Allowed    : Boolean := False;
      Overlapped : Boolean;
      Resource_OK : Boolean;
      Perf_Status : Perf_Status_Values := [others => 0];
      Perf_Mask   : aliased Interfaces.Unsigned_64 := 0;
   begin
      if Value.Active then
         raise Span_Already_Active;
      end if;
      if Item.Owner = null
        or else Item.Owner /= Object.Guard.Backend
        or else Item.Identifier not in 1 .. Data.Count
      then
         raise Invalid_Benchmark;
      end if;
      Data.Control.Begin_Span (Allowed, Overlapped);
      if not Allowed then
         raise Recording_Not_Started;
      end if;
      Data.Stores (Benchmark_Capacity (Item.Identifier)).Begin_Span;
      Value.Owner := Object.Guard.Backend;
      Value.Identifier := Item.Identifier;
      Value.Overlapped := Overlapped;
      Value.Native_Thread := Native_Thread_Id;
      if Resource_Metrics_Requested (Data.Config.Metrics) then
         Read_Resources
           (Value.Resource_Before, Value.Resource_Before_Mask, Resource_OK);
         if not Resource_OK then
            Value.Resource_Before_Mask := 0;
         end if;
      end if;
      if Scheduler_Metrics_Requested (Data.Config.Metrics)
        and then Data.Config.Scheduler_Probe /= null
      then
         Data.Config.Scheduler_Probe.all (Value.Scheduler_Before);
      end if;
      if Data.Perf_Session /= 0 then
         if Native_Recording_Perf_Snapshot
           (Data.Perf_Session,
            Value.Perf_Before (Value.Perf_Before'First)'Address,
            Value.Perf_Enabled_Before
              (Value.Perf_Enabled_Before'First)'Address,
            Value.Perf_Running_Before
              (Value.Perf_Running_Before'First)'Address,
            Perf_Status (Perf_Status'First)'Address,
            Interfaces.C.size_t (Perf_Value_Count), Perf_Mask'Access) = 0
         then
            Value.Perf_Before_Mask := Perf_Mask;
         else
            Value.Perf_Before_Mask := 0;
         end if;
      end if;
      Value.Started_At := Clock_Now;
      Value.Active := True;
   exception
      when others =>
         if Allowed then
            Data.Control.End_Span;
            Data.Stores (Benchmark_Capacity (Item.Identifier)).Abandon_Span;
            Close_Perf_When_Quiescent (Data);
         end if;
         raise;
   end Begin_Sample;

   procedure Finish
     (Value   : in out Span;
      Outcome : Sample_Outcome := Success)
   is
      Finished_At   : Interfaces.Unsigned_64;
      Finished_Thread : Interfaces.Unsigned_64;
      After         : Resource_Values := [others => 0];
      After_Mask    : Interfaces.Unsigned_64 := 0;
      Resource_OK   : Boolean := False;
      Scheduler_After : Flyology_Scheduler_Snapshot;
      Perf_After       : Perf_Values := [others => 0];
      Perf_Enabled_After : Perf_Values := [others => 0];
      Perf_Running_After : Perf_Values := [others => 0];
      Perf_Status      : Perf_Status_Values := [others => 0];
      Perf_Mask        : aliased Interfaces.Unsigned_64 := 0;
      Perf_OK          : Boolean := False;
      Data          : Concrete_Backend_Access;
      Sample        : Raw_Sample;

      procedure Set_Delta
        (Axis  : Metric_Axis;
         Index : Natural) is
      begin
         Sample.Status (Axis) := Probe_Failed;
         if Mask_Has (Value.Resource_Before_Mask, Index)
           and then Mask_Has (After_Mask, Index)
           and then After (Index) >= Value.Resource_Before (Index)
         then
            Sample.Valid (Axis) := True;
            Sample.Status (Axis) := Metric_Collected;
            Sample.Values (Axis) := Long_Float
              (After (Index) - Value.Resource_Before (Index));
         end if;
      end Set_Delta;

      procedure Set_Scheduler
        (Axis   : Metric_Axis;
         Before : Interfaces.Unsigned_64;
         After_Value : Interfaces.Unsigned_64) is
      begin
         Sample.Status (Axis) := Probe_Failed;
         if Value.Scheduler_Before.Available
           and then Scheduler_After.Available
           and then After_Value >= Before
         then
            Sample.Valid (Axis) := True;
            Sample.Status (Axis) := Metric_Collected;
            Sample.Values (Axis) := Long_Float (After_Value - Before);
         end if;
      end Set_Scheduler;

      function Status_At (Index : Natural) return Metric_Availability is
         Code : constant Interfaces.C.int := Perf_Status (Index);
      begin
         if Code < 0
           or else Code > Interfaces.C.int
             (Metric_Availability'Pos (Metric_Availability'Last))
         then
            return Probe_Failed;
         end if;
         return Metric_Availability'Val (Natural (Code));
      end Status_At;

      procedure Set_Perf (Axis : Metric_Axis; Index : Natural) is
         Counted_Delta : Interfaces.Unsigned_64;
         Enabled_Delta : Interfaces.Unsigned_64;
         Running_Delta : Interfaces.Unsigned_64;
      begin
         Sample.Status (Axis) := Status_At (Index);
         if not Perf_OK
           or else not Mask_Has (Value.Perf_Before_Mask, Index)
           or else not Mask_Has (Perf_Mask, Index)
         then
            return;
         end if;
         if Perf_After (Index) < Value.Perf_Before (Index)
           or else Perf_Enabled_After (Index)
             < Value.Perf_Enabled_Before (Index)
           or else Perf_Running_After (Index)
             < Value.Perf_Running_Before (Index)
         then
            Sample.Status (Axis) := Probe_Failed;
            return;
         end if;
         Counted_Delta := Perf_After (Index) - Value.Perf_Before (Index);
         Enabled_Delta := Perf_Enabled_After (Index)
           - Value.Perf_Enabled_Before (Index);
         Running_Delta := Perf_Running_After (Index)
           - Value.Perf_Running_Before (Index);
         if Running_Delta = 0 then
            Sample.Status (Axis) := Counter_Resources_Unavailable;
            return;
         end if;
         Sample.Valid (Axis) := True;
         Sample.Status (Axis) := Metric_Collected;
         Sample.Values (Axis) := Long_Float (Counted_Delta)
           * Long_Float (Enabled_Delta) / Long_Float (Running_Delta);
      end Set_Perf;
   begin
      if not Value.Active then
         raise Span_Already_Finished;
      end if;

      --  The ending wall timestamp is deliberately the first finishing probe.
      Finished_At := Clock_Now;
      Finished_Thread := Native_Thread_Id;
      Data := Concrete_Backend_Access (Value.Owner);
      if Data.Perf_Session /= 0 then
         Perf_OK := Native_Recording_Perf_Snapshot
           (Data.Perf_Session,
            Perf_After (Perf_After'First)'Address,
            Perf_Enabled_After (Perf_Enabled_After'First)'Address,
            Perf_Running_After (Perf_Running_After'First)'Address,
            Perf_Status (Perf_Status'First)'Address,
            Interfaces.C.size_t (Perf_Value_Count), Perf_Mask'Access) = 0;
      end if;
      if Resource_Metrics_Requested (Data.Config.Metrics) then
         Read_Resources (After, After_Mask, Resource_OK);
         if not Resource_OK then
            After_Mask := 0;
         end if;
      end if;
      if Scheduler_Metrics_Requested (Data.Config.Metrics)
        and then Data.Config.Scheduler_Probe /= null
      then
         Data.Config.Scheduler_Probe.all (Scheduler_After);
      end if;

      Sample.Overlapped := Value.Overlapped;
      for Axis in Metric_Axis loop
         if Data.Config.Metrics (Axis) then
            Sample.Status (Axis) := Probe_Failed;
         end if;
      end loop;
      if Data.Config.Metrics (Wall_Time) then
         if Finished_At < Value.Started_At then
            raise Program_Error with "platform monotonic clock moved backwards";
         end if;
         Sample.Valid (Wall_Time) := True;
         Sample.Status (Wall_Time) := Metric_Collected;
         Sample.Values (Wall_Time) :=
           Long_Float (Finished_At - Value.Started_At);
      end if;

      if Data.Config.Metrics (Process_CPU_Time) then
         Set_Delta (Process_CPU_Time, 0);
      end if;
      if Data.Config.Metrics (Thread_CPU_Time) then
         if Finished_Thread /= 0
           and then Finished_Thread = Value.Native_Thread
         then
            Set_Delta (Thread_CPU_Time, 1);
         else
            Sample.Scope_Changed (Thread_CPU_Time) := True;
         end if;
      end if;
      if Data.Config.Metrics (Process_RSS) then
         if Mask_Has (After_Mask, 2) then
            Sample.Valid (Process_RSS) := True;
            Sample.Status (Process_RSS) := Metric_Collected;
            Sample.Values (Process_RSS) := Long_Float (After (2));
         end if;
      end if;
      if Data.Config.Metrics (Process_RSS_Change) then
         if Mask_Has (Value.Resource_Before_Mask, 2)
           and then Mask_Has (After_Mask, 2)
         then
            Sample.Valid (Process_RSS_Change) := True;
            Sample.Status (Process_RSS_Change) := Metric_Collected;
            Sample.Values (Process_RSS_Change) :=
              Long_Float (After (2)) - Long_Float (Value.Resource_Before (2));
         end if;
      end if;
      if Data.Config.Metrics (Minor_Page_Faults) then
         Set_Delta (Minor_Page_Faults, 3);
      end if;
      if Data.Config.Metrics (Major_Page_Faults) then
         Set_Delta (Major_Page_Faults, 4);
      end if;
      if Data.Config.Metrics (Voluntary_Context_Switches) then
         Set_Delta (Voluntary_Context_Switches, 5);
      end if;
      if Data.Config.Metrics (Involuntary_Context_Switches) then
         Set_Delta (Involuntary_Context_Switches, 6);
      end if;
      if Data.Config.Metrics (Disk_Read_Bytes) then
         Set_Delta (Disk_Read_Bytes, 7);
      end if;
      if Data.Config.Metrics (Disk_Written_Bytes) then
         Set_Delta (Disk_Written_Bytes, 8);
      end if;
      if Data.Config.Metrics (Filesystem_Input_Operations) then
         Set_Delta (Filesystem_Input_Operations, 9);
      end if;
      if Data.Config.Metrics (Filesystem_Output_Operations) then
         Set_Delta (Filesystem_Output_Operations, 10);
      end if;

      if Hardware_Mask (Data.Config.Metrics) /= 0 then
         if Finished_Thread = 0
           or else Finished_Thread /= Value.Native_Thread
         then
            for Axis in CPU_Cycles .. Branch_Misses loop
               if Data.Config.Metrics (Axis) then
                  Sample.Scope_Changed (Axis) := True;
               end if;
            end loop;
         elsif Data.Perf_Session = 0 then
            for Axis in CPU_Cycles .. Branch_Misses loop
               if Data.Config.Metrics (Axis) then
                  Sample.Status (Axis) := Probe_Failed;
               end if;
            end loop;
         else
            if Data.Config.Metrics (CPU_Cycles)
              or else Data.Config.Metrics (Instructions_Per_Cycle)
            then
               Set_Perf (CPU_Cycles, 0);
            end if;
            if Data.Config.Metrics (Instructions)
              or else Data.Config.Metrics (Instructions_Per_Cycle)
            then
               Set_Perf (Instructions, 1);
            end if;
            if Data.Config.Metrics (Cache_Misses) then
               Set_Perf (Cache_Misses, 2);
            end if;
            if Data.Config.Metrics (Branches) then
               Set_Perf (Branches, 3);
            end if;
            if Data.Config.Metrics (Branch_Misses) then
               Set_Perf (Branch_Misses, 4);
            end if;
            if Data.Config.Metrics (Instructions_Per_Cycle) then
               Sample.Status (Instructions_Per_Cycle) :=
                 Sample.Status (CPU_Cycles);
               if Sample.Valid (CPU_Cycles)
                 and then Sample.Valid (Instructions)
                 and then Sample.Values (CPU_Cycles) > 0.0
               then
                  Sample.Valid (Instructions_Per_Cycle) := True;
                  Sample.Status (Instructions_Per_Cycle) := Metric_Collected;
                  Sample.Values (Instructions_Per_Cycle) :=
                    Sample.Values (Instructions) / Sample.Values (CPU_Cycles);
               elsif Sample.Status (Instructions) /= Metric_Collected then
                  Sample.Status (Instructions_Per_Cycle) :=
                    Sample.Status (Instructions);
               end if;
            end if;
         end if;
      end if;

      if Scheduler_Metrics_Requested (Data.Config.Metrics) then
         Set_Scheduler
           (Flyology_Dispatches, Value.Scheduler_Before.Dispatches,
            Scheduler_After.Dispatches);
         Set_Scheduler
           (Flyology_Poll_Batches, Value.Scheduler_Before.Poll_Batches,
            Scheduler_After.Poll_Batches);
         Set_Scheduler
           (Flyology_Poll_Events, Value.Scheduler_Before.Poll_Events,
            Scheduler_After.Poll_Events);
         Set_Scheduler
           (Flyology_Wakeups, Value.Scheduler_Before.Wakeups,
            Scheduler_After.Wakeups);
         Set_Scheduler
           (Flyology_Migrations,
            Value.Scheduler_Before.Migrations_In
              + Value.Scheduler_Before.Migrations_Out,
            Scheduler_After.Migrations_In + Scheduler_After.Migrations_Out);
      end if;

      Data.Stores (Benchmark_Capacity (Value.Identifier)).Finish_Span
        (Sample, Outcome, Data.Config.Retention, Data.Config.Random_Seed);
      Data.Control.End_Span;
      Close_Perf_When_Quiescent (Data);
      Value.Active := False;
      Value.Owner := null;
   exception
      when others =>
         if Value.Active and then Value.Owner /= null then
            Data := Concrete_Backend_Access (Value.Owner);
            Data.Stores (Benchmark_Capacity (Value.Identifier)).Abandon_Span;
            Data.Control.End_Span;
            Close_Perf_When_Quiescent (Data);
            Value.Active := False;
            Value.Owner := null;
         end if;
         raise;
   end Finish;

   overriding procedure Finalize (Object : in out Span) is
      Data : Concrete_Backend_Access;
   begin
      if Object.Active and then Object.Owner /= null then
         Data := Concrete_Backend_Access (Object.Owner);
         Data.Stores (Benchmark_Capacity (Object.Identifier)).Abandon_Span;
         Data.Control.End_Span;
         Close_Perf_When_Quiescent (Data);
         Object.Active := False;
         Object.Owner := null;
      end if;
   end Finalize;

   function Name (Item : Benchmark) return String is
     (To_String (Item.Label));

   procedure Snapshot
     (Object : Recorder;
      Item   : Benchmark;
      Result : out Recorded_Measurement)
   is
      Data       : constant Concrete_Backend_Access := Backend (Object);
      Started_At : Interfaces.Unsigned_64;
      Ended_At   : Interfaces.Unsigned_64;
      Active     : Boolean;
      Elapsed    : Interfaces.Unsigned_64 := 0;
   begin
      if Item.Owner = null
        or else Item.Owner /= Object.Guard.Backend
        or else Item.Identifier not in 1 .. Data.Count
      then
         raise Invalid_Benchmark;
      end if;
      Result.Label := Item.Label;
      Result.Samples := new Recorded_Sample_Array
        (1 .. Natural (Data.Capacity));
      for Axis in Metric_Axis loop
         if Data.Config.Metrics (Axis) then
            Result.Values (Axis) :=
              new Metric_Value_Array (1 .. Natural (Data.Capacity));
         end if;
      end loop;
      Data.Control.Times (Started_At, Ended_At, Active);
      if Started_At > 0 then
         if Active then
            Ended_At := Clock_Now;
         end if;
         if Ended_At >= Started_At then
            Elapsed := Ended_At - Started_At;
         end if;
      end if;
      Data.Stores (Benchmark_Capacity (Item.Identifier)).Copy_To
        (Result, Data.Config.Metrics, Elapsed);

      for Axis in Metric_Axis loop
         if Data.Config.Metrics (Axis) then
            Result.Attributions (Axis) :=
              (case Axis is
                 when Wall_Time => Exact_Window,
                 when Thread_CPU_Time => Same_Native_Thread_Window,
                 when CPU_Cycles .. Branch_Misses =>
                   Native_Task_Tree_Window,
                 when Process_CPU_Time | Process_RSS ..
                   Filesystem_Output_Operations =>
                   Shared_Process_Window,
                 when Flyology_Dispatches .. Flyology_Migrations =>
                   Shared_Runtime_Window);
         end if;
      end loop;
      Analyze (Result);
   end Snapshot;

   overriding procedure Adjust (Object : in out Recorded_Measurement) is
   begin
      if Object.Samples /= null then
         Object.Samples := new Recorded_Sample_Array'(Object.Samples.all);
      end if;
      for Axis in Metric_Axis loop
         if Object.Values (Axis) /= null then
            Object.Values (Axis) :=
              new Metric_Value_Array'(Object.Values (Axis).all);
         end if;
      end loop;
   end Adjust;

   overriding procedure Finalize (Object : in out Recorded_Measurement) is
   begin
      Free_Samples (Object.Samples);
      for Axis in Metric_Axis loop
         Free_Values (Object.Values (Axis));
      end loop;
   end Finalize;

   function Benchmarks (Object : Recorder) return Natural is
     (Backend (Object).Count);
   function Observed (Result : Recorded_Measurement) return Natural is
     (Result.Observed_Total);
   function Retained (Result : Recorded_Measurement) return Natural is
     (Result.Retained_Total);
   function Dropped (Result : Recorded_Measurement) return Natural is
     (Result.Dropped_Total);
   function In_Flight (Result : Recorded_Measurement) return Natural is
     (Result.In_Flight_Total);
   function Abandoned (Result : Recorded_Measurement) return Natural is
     (Result.Abandoned_Total);
   function Outcomes
     (Result : Recorded_Measurement; Outcome : Sample_Outcome) return Natural is
     (Result.Outcome_Totals (Outcome));
   function Session_Elapsed (Result : Recorded_Measurement) return Duration is
     (Duration (Long_Float (Result.Elapsed_NS) / 1_000_000_000.0));
   function Name (Result : Recorded_Measurement) return String is
     (To_String (Result.Label));
   function Metric_Statistics
     (Result : Recorded_Measurement; Axis : Metric_Axis) return Metric_Summary is
     (Result.Summaries (Axis));
   function Metric_Status
     (Result : Recorded_Measurement; Axis : Metric_Axis)
      return Metric_Availability is (Result.Statuses (Axis));
   function Attribution
     (Result : Recorded_Measurement; Axis : Metric_Axis)
      return Metric_Attribution is (Result.Attributions (Axis));
   function Metric_Samples
     (Result : Recorded_Measurement; Axis : Metric_Axis) return Natural is
     (Result.Valid_Counts (Axis));
   function Scope_Changed_Samples
     (Result : Recorded_Measurement; Axis : Metric_Axis) return Natural is
     (Result.Scope_Changed (Axis));
   function Unavailable_Metric_Samples
     (Result : Recorded_Measurement; Axis : Metric_Axis) return Natural is
     (Result.Invalid_Counts (Axis));
   function Metric_Sample
     (Result : Recorded_Measurement;
      Axis   : Metric_Axis;
      Index  : Positive) return Long_Float is
   begin
      if Result.Values (Axis) = null
        or else Index > Result.Valid_Counts (Axis)
      then
         raise Constraint_Error with "recorded metric sample out of range";
      end if;
      return Result.Values (Axis) (Index);
   end Metric_Sample;

   procedure Check_Sample_Index
     (Result : Recorded_Measurement;
      Index  : Positive) is
   begin
      if Result.Samples = null or else Index > Result.Retained_Total then
         raise Constraint_Error with "recorded sample index out of range";
      end if;
   end Check_Sample_Index;

   function Observation_Id
     (Result : Recorded_Measurement;
      Index  : Positive) return Natural is
   begin
      Check_Sample_Index (Result, Index);
      return Result.Samples (Index).Observation;
   end Observation_Id;

   function Outcome_At
     (Result : Recorded_Measurement;
      Index  : Positive) return Sample_Outcome is
   begin
      Check_Sample_Index (Result, Index);
      return Result.Samples (Index).Outcome;
   end Outcome_At;

   function Sample_Metric_Status
     (Result : Recorded_Measurement;
      Index  : Positive;
      Axis   : Metric_Axis) return Metric_Availability is
   begin
      Check_Sample_Index (Result, Index);
      return Result.Samples (Index).Status (Axis);
   end Sample_Metric_Status;

   function Sample_Metric_Value
     (Result : Recorded_Measurement;
      Index  : Positive;
      Axis   : Metric_Axis) return Long_Float is
   begin
      Check_Sample_Index (Result, Index);
      if not Result.Samples (Index).Valid (Axis) then
         raise Constraint_Error with "recorded sample metric is unavailable";
      end if;
      return Result.Samples (Index).Values (Axis);
   end Sample_Metric_Value;

   procedure Analyze_Independent_Metric
     (Reference : Recorded_Measurement;
      Contender : Recorded_Measurement;
      Axis      : Metric_Axis;
      Seed      : Long_Long_Integer;
      Threshold : Long_Float;
      Item      : out Metric_Comparison_Result)
   is
      Reference_Count : constant Natural := Reference.Valid_Counts (Axis);
      Contender_Count : constant Natural := Contender.Valid_Counts (Axis);
   begin
      Item := (others => <>);
      if Reference.Statuses (Axis) /= Metric_Collected
        or else Contender.Statuses (Axis) /= Metric_Collected
        or else Reference_Count = 0
        or else Contender_Count = 0
      then
         return;
      end if;
      declare
         Bootstrap : Float_Array (1 .. Bootstrap_Resamples);
         Random    : Interfaces.Unsigned_64 :=
           16#D1B5_4A32_D192_ED03# xor Interfaces.Unsigned_64 (Seed)
           xor Interfaces.Unsigned_64 (Metric_Axis'Pos (Axis) + 1);
         Relative : Boolean := True;
         Reference_Draw : Float_Array (1 .. Reference_Count);
         Contender_Draw : Float_Array (1 .. Contender_Count);
      begin
         Item.Available := True;
         Item.Reference_Median := Reference.Summaries (Axis).Median;
         Item.Contender_Median := Contender.Summaries (Axis).Median;
         Relative := Item.Reference_Median > 0.0
           and then Item.Contender_Median > 0.0;
         for Index in 1 .. Reference_Count loop
            Relative := Relative
              and then Reference.Values (Axis) (Index) >= 0.0;
         end loop;
         for Index in 1 .. Contender_Count loop
            Relative := Relative
              and then Contender.Values (Axis) (Index) >= 0.0;
         end loop;

         if Relative then
            Item.Method := Relative_Ratio;
            Item.Change := 100.0
              * (Item.Contender_Median / Item.Reference_Median - 1.0);
         else
            Item.Method := Absolute_Difference;
            Item.Change := Item.Contender_Median - Item.Reference_Median;
         end if;

         for Draw in Bootstrap'Range loop
            declare
               Attempts         : Natural := 0;
               Reference_Median : Long_Float;
               Contender_Median : Long_Float;
            begin
               --  A ratio bootstrap cannot use a zero reference median.
               --  When the original median is positive, redraw the rare
               --  degenerate resample instead of mixing absolute and
               --  percentage units in one confidence interval.
               loop
                  for Index in Reference_Draw'Range loop
                     Reference_Draw (Index) := Reference.Values (Axis)
                       (Natural
                         (Next_Random (Random)
                          mod Interfaces.Unsigned_64 (Reference_Count)) + 1);
                  end loop;
                  Sort (Reference_Draw);
                  Reference_Median := Percentile (Reference_Draw, 0.5);
                  exit when not Relative
                    or else Reference_Median > 0.0
                    or else Attempts = 31;
                  Attempts := Attempts + 1;
               end loop;
            for Index in Contender_Draw'Range loop
               Contender_Draw (Index) := Contender.Values (Axis)
                 (Natural
                   (Next_Random (Random)
                    mod Interfaces.Unsigned_64 (Contender_Count)) + 1);
            end loop;
            Sort (Contender_Draw);
               Contender_Median := Percentile (Contender_Draw, 0.5);
            if Relative and then Reference_Median > 0.0 then
               Bootstrap (Draw) := 100.0
                    * (Contender_Median / Reference_Median - 1.0);
               elsif Relative then
                  --  Thirty-two zero-median redraws are possible only for a
                  --  highly discrete distribution. Preserve percentage units
                  --  with the observed estimate rather than corrupting the
                  --  interval with an absolute difference.
                  Bootstrap (Draw) := Item.Change;
            else
                  Bootstrap (Draw) := Contender_Median - Reference_Median;
            end if;
            end;
         end loop;
         Sort (Bootstrap);
         Item.Confidence_Low := Percentile (Bootstrap, 0.025);
         Item.Confidence_High := Percentile (Bootstrap, 0.975);
         if Direction (Axis) = Diagnostic then
            Item.Verdict := Metric_Diagnostic;
         elsif Relative
           and then Item.Confidence_Low >= -Threshold
           and then Item.Confidence_High <= Threshold
         then
            Item.Verdict := Metric_Practically_Equivalent;
         elsif Item.Confidence_High < 0.0 then
            Item.Verdict :=
              (if Direction (Axis) = Lower_Is_Better
               then Contender_Better else Reference_Better);
         elsif Item.Confidence_Low > 0.0 then
            Item.Verdict :=
              (if Direction (Axis) = Lower_Is_Better
               then Reference_Better else Contender_Better);
         end if;
      end;
   end Analyze_Independent_Metric;

   procedure Compare_Independent
     (Reference : Recorded_Measurement;
      Contender : Recorded_Measurement;
      Result    : out Recorded_Comparison;
      Practical_Threshold_Percent : Long_Float := 1.0;
      Random_Seed : Long_Long_Integer := 1) is
      Wall : Metric_Comparison_Result;
   begin
      if Practical_Threshold_Percent < 0.0 then
         raise Constraint_Error with
           "practical comparison threshold must not be negative";
      end if;
      Result := (others => <>);
      Result.Reference_Label := Reference.Label;
      Result.Contender_Label := Contender.Label;
      for Axis in Metric_Axis loop
         Result.Reference_Statuses (Axis) := Reference.Statuses (Axis);
         Result.Contender_Statuses (Axis) := Contender.Statuses (Axis);
         Analyze_Independent_Metric
           (Reference, Contender, Axis, Random_Seed,
            Practical_Threshold_Percent, Result.Metrics (Axis));
      end loop;
      Wall := Result.Metrics (Wall_Time);
      if Wall.Available and then Wall.Reference_Median > 0.0
        and then Wall.Contender_Median > 0.0
      then
         Result.Wall_Available := True;
         Result.Speedup_Value :=
           Wall.Reference_Median / Wall.Contender_Median;
         Result.Change_Value := Wall.Change;
         Result.Change_Low := Wall.Confidence_Low;
         Result.Change_High := Wall.Confidence_High;
         Result.Speedup_Low :=
           (if Result.Change_High <= -100.0 then Long_Float'Last
            else 1.0 / (1.0 + Result.Change_High / 100.0));
         Result.Speedup_High :=
           (if Result.Change_Low <= -100.0 then Long_Float'Last
            else 1.0 / (1.0 + Result.Change_Low / 100.0));
         if Result.Change_Low >= -Practical_Threshold_Percent
           and then Result.Change_High <= Practical_Threshold_Percent
         then
            Result.Verdict_Value := Practically_Equivalent;
         elsif Result.Change_High < -Practical_Threshold_Percent then
            Result.Verdict_Value := Contender_Faster;
         elsif Result.Change_Low > Practical_Threshold_Percent then
            Result.Verdict_Value := Reference_Faster;
         end if;
      end if;
   end Compare_Independent;

   function Reference_Name (Result : Recorded_Comparison) return String is
     (To_String (Result.Reference_Label));
   function Contender_Name (Result : Recorded_Comparison) return String is
     (To_String (Result.Contender_Label));
   procedure Require_Wall_Comparison (Result : Recorded_Comparison) is
   begin
      if not Result.Wall_Available then
         raise Constraint_Error with "wall-time comparison is unavailable";
      end if;
   end Require_Wall_Comparison;

   function Speedup (Result : Recorded_Comparison) return Long_Float is
   begin
      Require_Wall_Comparison (Result);
      return Result.Speedup_Value;
   end Speedup;
   function Speedup_Confidence_Low
     (Result : Recorded_Comparison) return Long_Float is
   begin
      Require_Wall_Comparison (Result);
      return Result.Speedup_Low;
   end Speedup_Confidence_Low;
   function Speedup_Confidence_High
     (Result : Recorded_Comparison) return Long_Float is
   begin
      Require_Wall_Comparison (Result);
      return Result.Speedup_High;
   end Speedup_Confidence_High;
   function Relative_Change_Percent
     (Result : Recorded_Comparison) return Long_Float is
   begin
      Require_Wall_Comparison (Result);
      return Result.Change_Value;
   end Relative_Change_Percent;
   function Relative_Change_Confidence_Low
     (Result : Recorded_Comparison) return Long_Float is
   begin
      Require_Wall_Comparison (Result);
      return Result.Change_Low;
   end Relative_Change_Confidence_Low;
   function Relative_Change_Confidence_High
     (Result : Recorded_Comparison) return Long_Float is
   begin
      Require_Wall_Comparison (Result);
      return Result.Change_High;
   end Relative_Change_Confidence_High;
   function Verdict
     (Result : Recorded_Comparison) return Comparison_Verdict is
     (Result.Verdict_Value);
   function Wall_Comparison_Available
     (Result : Recorded_Comparison) return Boolean is
     (Result.Wall_Available);
   function Reference_Metric_Status
     (Result : Recorded_Comparison;
      Axis   : Metric_Axis) return Metric_Availability is
     (Result.Reference_Statuses (Axis));
   function Contender_Metric_Status
     (Result : Recorded_Comparison;
      Axis   : Metric_Axis) return Metric_Availability is
     (Result.Contender_Statuses (Axis));
   function Compare_Metric
     (Result : Recorded_Comparison; Axis : Metric_Axis)
      return Metric_Comparison_Result is (Result.Metrics (Axis));

   function Format_Time (Nanoseconds : Long_Float) return String is
      use Ada.Strings;
      use Ada.Strings.Fixed;
      package Local_Float_IO is new Ada.Text_IO.Float_IO (Long_Float);
      function Fixed (Value : Long_Float; Aft : Natural) return String is
         Buffer : String (1 .. 32);
      begin
         Local_Float_IO.Put (Buffer, Value, Aft => Aft, Exp => 0);
         return Trim (Buffer, Both);
      end Fixed;
   begin
      if Nanoseconds < 1_000.0 then
         return Fixed (Nanoseconds, 1) & " ns";
      elsif Nanoseconds < 1_000_000.0 then
         return Fixed (Nanoseconds / 1_000.0, 2) & " us";
      elsif Nanoseconds < 1_000_000_000.0 then
         return Fixed (Nanoseconds / 1_000_000.0, 2) & " ms";
      else
         return Fixed (Nanoseconds / 1_000_000_000.0, 2) & " s";
      end if;
   end Format_Time;

   function Format_Memory (Bytes : Long_Float) return String is
      package Local_Float_IO is new Ada.Text_IO.Float_IO (Long_Float);
      Buffer : String (1 .. 32);
      Value  : Long_Float;
      Unit   : String (1 .. 3);
   begin
      if Bytes >= 1_073_741_824.0 then
         Value := Bytes / 1_073_741_824.0;
         Unit := "GiB";
      elsif Bytes >= 1_048_576.0 then
         Value := Bytes / 1_048_576.0;
         Unit := "MiB";
      else
         Value := Bytes / 1_024.0;
         Unit := "KiB";
      end if;
      Local_Float_IO.Put (Buffer, Value, Aft => 1, Exp => 0);
      return Ada.Strings.Fixed.Trim (Buffer, Ada.Strings.Both) & " " & Unit;
   end Format_Memory;

   function Format_Number
     (Value : Long_Float;
      Aft   : Natural := 1) return String
   is
      package Local_Float_IO is new Ada.Text_IO.Float_IO (Long_Float);
      Buffer : String (1 .. 32);
   begin
      Local_Float_IO.Put (Buffer, Value, Aft => Aft, Exp => 0);
      return Ada.Strings.Fixed.Trim (Buffer, Ada.Strings.Both);
   end Format_Number;

   function Pad (Value : String; Width : Positive) return String is
      Count : constant Natural := Natural'Min (Value'Length, Width);
      Result : String (1 .. Width) := (others => ' ');
   begin
      Result (1 .. Count) := Value (Value'First .. Value'First + Count - 1);
      return Result;
   end Pad;

   function Left_Pad (Value : String; Width : Positive) return String is
      Count : constant Natural := Natural'Min (Value'Length, Width);
      Result : String (1 .. Width) := (others => ' ');
   begin
      if Count > 0 then
         Result (Width - Count + 1 .. Width) :=
           Value (Value'Last - Count + 1 .. Value'Last);
      end if;
      return Result;
   end Left_Pad;

   function Number (Value : Natural; Width : Positive) return String is
      use Ada.Strings;
      use Ada.Strings.Fixed;
      Image : constant String := Trim (Natural'Image (Value), Both);
      Result : String (1 .. Width) := (others => ' ');
      Count : constant Natural := Natural'Min (Image'Length, Width);
   begin
      Result (Width - Count + 1 .. Width) :=
        Image (Image'Last - Count + 1 .. Image'Last);
      return Result;
   end Number;

   procedure Render_Dashboard
     (Data      : Concrete_Backend_Access;
      Use_ANSI  : Boolean;
      Previous  : in out Natural;
      Previous_Wall : in out Interfaces.Unsigned_64;
      Previous_CPU  : in out Interfaces.Unsigned_64)
   is
      Escape : constant Character := Ada.Characters.Latin_1.ESC;
      Lines  : constant Natural := Data.Count + 2;
      Live   : Live_Data;
      Started, Ended : Interfaces.Unsigned_64;
      Active : Boolean;
      Elapsed : Long_Float := 0.0;
      Resources : Resource_Values := [others => 0];
      Resource_Mask : Interfaces.Unsigned_64 := 0;
      Resource_OK : Boolean := False;
      Current_Wall : constant Interfaces.Unsigned_64 := Clock_Now;
      Current_CPU  : Interfaces.Unsigned_64 := 0;
      CPU_Percent  : Long_Float := 0.0;
      RSS          : Long_Float := 0.0;
   begin
      Data.Control.Times (Started, Ended, Active);
      if Started > 0 then
         if Active then
            Ended := Clock_Now;
         end if;
         Elapsed := Long_Float (Ended - Started) / 1_000_000_000.0;
      end if;
      if Use_ANSI and then Previous > 0 then
         Ada.Text_IO.Put
           (Escape & "[" & Ada.Strings.Fixed.Trim
              (Natural'Image (Previous), Ada.Strings.Both) & "A");
      end if;
      Read_Resources (Resources, Resource_Mask, Resource_OK);
      if Resource_OK and then Mask_Has (Resource_Mask, 0) then
         Current_CPU := Resources (0);
         if Previous_Wall > 0 and then Current_Wall > Previous_Wall
           and then Current_CPU >= Previous_CPU
         then
            CPU_Percent := 100.0 * Long_Float (Current_CPU - Previous_CPU)
              / Long_Float (Current_Wall - Previous_Wall);
         end if;
         Previous_CPU := Current_CPU;
         Previous_Wall := Current_Wall;
      end if;
      if Resource_OK and then Mask_Has (Resource_Mask, 2) then
         RSS := Long_Float (Resources (2));
      end if;
      if Use_ANSI then
         Ada.Text_IO.Put (Escape & "[2K" & Escape & "[1;36m");
      end if;
      Ada.Text_IO.Put_Line
        ("fly recorder  elapsed "
         & Pad (Format_Time (Elapsed * 1_000_000_000.0), 10)
         & "   cpu " & Left_Pad (Format_Number (CPU_Percent), 6) & "% / "
         & Left_Pad (Format_Number (CPU_Percent / 100.0), 5) & " cores"
         & "   rss " & Left_Pad (Format_Memory (RSS), 10));
      if Use_ANSI then
         Ada.Text_IO.Put (Escape & "[0m" & Escape & "[2K");
      end if;
      Ada.Text_IO.Put_Line
        (Pad ("benchmark", 24) & "     done  live  errors   median      p95");
      for Index in 1 .. Data.Count loop
         Data.Stores (Benchmark_Capacity (Index)).Current (Live);
         if Use_ANSI then
            Ada.Text_IO.Put (Escape & "[2K");
         end if;
         Ada.Text_IO.Put_Line
           (Pad (To_String (Data.Names (Benchmark_Capacity (Index))), 24)
            & "  " & Number (Live.Observed, 8)
            & "  " & Number (Live.In_Flight, 4)
            & "  " & Number (Live.Failures + Live.Abandoned, 6)
            & "  " & Pad (Format_Time (Live.Median_NS), 10)
            & "  " & Pad (Format_Time (Live.P95_NS), 10));
      end loop;
      Ada.Text_IO.Flush;
      Previous := Lines;
   end Render_Dashboard;

   task type Dashboard_Task
     (Owner        : not null Concrete_Backend_Access;
      Milliseconds : Positive;
      Use_ANSI     : Boolean) is
      entry Stop;
   end Dashboard_Task;
   type Dashboard_Task_Access is access Dashboard_Task;

   task body Dashboard_Task is
      Previous : Natural := 0;
      Previous_Wall : Interfaces.Unsigned_64 := 0;
      Previous_CPU  : Interfaces.Unsigned_64 := 0;
   begin
      loop
         select
            accept Stop;
            exit;
         or
            delay Duration (Milliseconds) / 1_000.0;
            Render_Dashboard
              (Owner, Use_ANSI, Previous, Previous_Wall, Previous_CPU);
         end select;
      end loop;
      Render_Dashboard
        (Owner, Use_ANSI, Previous, Previous_Wall, Previous_CPU);
      Ada.Text_IO.New_Line;
   end Dashboard_Task;

   type Concrete_Dashboard is limited new Dashboard_Backend with record
      Worker : Dashboard_Task_Access := null;
   end record;
   type Concrete_Dashboard_Access is access all Concrete_Dashboard;
   procedure Free_Dashboard is new Ada.Unchecked_Deallocation
     (Concrete_Dashboard, Concrete_Dashboard_Access);
   procedure Free_Task is new Ada.Unchecked_Deallocation
     (Dashboard_Task, Dashboard_Task_Access);

   procedure Start_Live_Terminal
     (Object           : in out Recorder;
      Refresh_Interval : Duration := 0.250;
      ANSI             : Boolean := True)
   is
      Milliseconds : Positive := 1;
      Handle : Concrete_Dashboard_Access;
   begin
      if Object.Guard.Dashboard /= null then
         raise Recording_Already_Started with "live terminal already running";
      end if;
      if Refresh_Interval <= 0.0 then
         raise Constraint_Error with "refresh interval must be positive";
      end if;
      Milliseconds := Positive'Max
        (1, Positive (Long_Float'Rounding
          (Long_Float (Refresh_Interval) * 1_000.0)));
      Handle := new Concrete_Dashboard;
      Handle.Worker := new Dashboard_Task
        (Backend (Object), Milliseconds, ANSI);
      Object.Guard.Dashboard := Dashboard_Backend_Access (Handle);
   end Start_Live_Terminal;

   procedure Stop_Dashboard (Object : in out Dashboard_Backend_Access) is
      Handle : Concrete_Dashboard_Access;
   begin
      if Object = null then
         return;
      end if;
      Handle := Concrete_Dashboard_Access (Object);
      Handle.Worker.Stop;
      Free_Task (Handle.Worker);
      Object := null;
      Free_Dashboard (Handle);
   end Stop_Dashboard;

   procedure Stop_Live_Terminal (Object : in out Recorder) is
   begin
      Stop_Dashboard (Object.Guard.Dashboard);
   end Stop_Live_Terminal;
end Flyology_Bench.Recording;
