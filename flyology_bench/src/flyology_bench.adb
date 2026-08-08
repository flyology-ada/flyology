--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Numerics.Long_Elementary_Functions;
with Ada.Characters.Handling;
with Interfaces;
with Interfaces.C;
with System;

package body Flyology_Bench is
   package Math renames Ada.Numerics.Long_Elementary_Functions;

   use type Interfaces.Unsigned_64;
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;

   Bootstrap_Resamples : constant := 2_000;

   procedure Escape (Value : System.Address);
   pragma Import (C, Escape, "flyology_bench_escape");

   procedure Memory_Barrier;
   pragma Import (C, Memory_Barrier, "flyology_bench_clobber_memory");

   function Native_Clock_Now
     (Value : access Interfaces.Unsigned_64) return Interfaces.C.int;
   pragma Import (C, Native_Clock_Now, "flyology_bench_clock_now");

   function Native_Clock_Resolution
     (Value : access Interfaces.Unsigned_64) return Interfaces.C.int;
   pragma Import
     (C, Native_Clock_Resolution, "flyology_bench_clock_resolution");

   function Native_Clock_Backend return Interfaces.C.int;
   pragma Import (C, Native_Clock_Backend, "flyology_bench_clock_backend");

   function Native_Process_Usage
     (CPU_Nanoseconds : access Interfaces.Unsigned_64;
      Resident_Bytes  : access Interfaces.Unsigned_64) return Interfaces.C.int;
   pragma Import (C, Native_Process_Usage, "flyology_bench_process_usage");

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

   function Clock_Now return Interfaces.Unsigned_64 is
      Value : aliased Interfaces.Unsigned_64;
   begin
      if Native_Clock_Now (Value'Access) /= 0 then
         raise Program_Error with "platform monotonic clock read failed";
      end if;
      return Value;
   end Clock_Now;

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
      Completed : Natural) return Boolean is
   begin
      return Config.Maximum_Sampling_Time > 0.0
        and then Completed >= Natural (Sample_Count'First)
        and then Clock_Now - Started
          >= Duration_Nanoseconds (Config.Maximum_Sampling_Time);
   end Sampling_Limit_Reached;

   procedure Read_Process_Usage
     (CPU       : out Interfaces.Unsigned_64;
      RSS       : out Interfaces.Unsigned_64;
      Available : out Boolean)
   is
      CPU_Value : aliased Interfaces.Unsigned_64 := 0;
      RSS_Value : aliased Interfaces.Unsigned_64 := 0;
   begin
      Available := Native_Process_Usage
        (CPU_Value'Access, RSS_Value'Access) = 0;
      CPU := CPU_Value;
      RSS := RSS_Value;
   end Read_Process_Usage;

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
      Notify (Config, Starting);
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
      declare
         Sampling_Started : constant Interfaces.Unsigned_64 := Clock_Now;
         Completed : Natural := 0;
      begin
         Notify (Config, Sampling, 0, Natural (Config.Samples));
         for Index in Sample_Index range 1 .. Sample_Index (Config.Samples) loop
            declare
               CPU_Before : Interfaces.Unsigned_64 := 0;
               CPU_After : Interfaces.Unsigned_64 := 0;
               RSS_Before : Interfaces.Unsigned_64 := 0;
               RSS_After : Interfaces.Unsigned_64 := 0;
               Before_Available : Boolean := False;
               After_Available : Boolean := False;
               Elapsed : Long_Float;
               Raw_Elapsed : Long_Float;
            begin
               if Config.Collect_Process_Telemetry then
                  Read_Process_Usage
                    (CPU_Before, RSS_Before, Before_Available);
               end if;
               Elapsed := Time_Batch (Batch_Iterations);
               Raw_Elapsed := Elapsed;
               if Config.Collect_Process_Telemetry then
                  Read_Process_Usage (CPU_After, RSS_After, After_Available);
                  Record_Process_Telemetry
                    (Result, Index, Raw_Elapsed,
                     CPU_Before, CPU_After, RSS_Before, RSS_After,
                     Before_Available and After_Available);
               end if;
               if Config.Subtract_Timer_Cost and then Elapsed > Clock_Cost then
                  Elapsed := Elapsed - Clock_Cost;
               end if;
               Result.Values (Index) :=
                 Elapsed / Long_Float (Batch_Iterations);
            end;
            Completed := Natural (Index);
            Notify
              (Config, Sampling, Completed, Natural (Config.Samples));
            exit when Sampling_Limit_Reached
              (Config, Sampling_Started, Completed);
         end loop;
         Result.Sample_Total := Sample_Count (Completed);
      end;
      Notify (Config, Analyzing);
      Analyze (Result);
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
      Await_CPU_Quiescence (Config);
      Result.Reference_Data.Sample_Total := Config.Samples;
      Result.Contender_Data.Sample_Total := Config.Samples;
      Result.Reference_Data.Random_Seed_Value := Config.Random_Seed;
      Result.Contender_Data.Random_Seed_Value := Config.Random_Seed;
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
         begin
         Notify (Config, Sampling, 0, Natural (Config.Samples));
         for Index in Orders'Range loop
            declare
               Reference_Time : Long_Float;
               Contender_Time : Long_Float;
            begin
               Time_Pair
                 (Reference_First => Orders (Index),
                  Reference_Time => Reference_Time,
                  Contender_Time => Contender_Time);
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
            end;
            Completed := Index;
            Notify
              (Config, Sampling, Completed, Natural (Config.Samples));
            exit when Sampling_Limit_Reached
              (Config, Sampling_Started, Completed);
         end loop;
         Result.Reference_Data.Sample_Total := Sample_Count (Completed);
         Result.Contender_Data.Sample_Total := Sample_Count (Completed);
         end;
      end;

      Notify (Config, Analyzing);
      Analyze (Result.Reference_Data);
      Analyze (Result.Contender_Data);
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
      Await_CPU_Quiescence (Config);
      for Index in 1 .. Count loop
         Result.Data (Comparison_Case_Index (Index)).Sample_Total :=
           Config.Samples;
         Result.Data (Comparison_Case_Index (Index)).Random_Seed_Value :=
           Config.Random_Seed;
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
            CPU_Before : Interfaces.Unsigned_64 := 0;
            CPU_After : Interfaces.Unsigned_64 := 0;
            RSS_Before : Interfaces.Unsigned_64 := 0;
            RSS_After : Interfaces.Unsigned_64 := 0;
            Before_Available : Boolean := False;
            After_Available : Boolean := False;
            Elapsed : Long_Float;
            Raw_Elapsed : Long_Float;
         begin
            if Config.Collect_Process_Telemetry then
               Read_Process_Usage
                 (CPU_Before, RSS_Before, Before_Available);
            end if;
            Elapsed := Time_One
              (Case_Id'Val (Case_Number - 1), Iterations_For (Case_Index));
            Raw_Elapsed := Elapsed;
            if Config.Collect_Process_Telemetry then
               Read_Process_Usage (CPU_After, RSS_After, After_Available);
               Record_Process_Telemetry
                 (Result.Data (Case_Index), Sample_Index (Sample),
                  Raw_Elapsed, CPU_Before, CPU_After,
                  RSS_Before, RSS_After,
                  Before_Available and After_Available);
            end if;
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
            Completed : Natural) return Boolean is
         begin
            return Config.Maximum_Sampling_Time > 0.0
              and then Completed >= Natural (Sample_Count'First)
              and then Clock_Now - Started
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
            for Sample in 1 .. Natural (Config.Samples) loop
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
                    (Comparison_Case_Index (Case_Number), Sample_Index (Sample)) :=
                      Positions (1) < Positions (Case_Number);
               end loop;
               Collected_Samples := Sample;
               exit when Sampling_Limit_Reached
                 (Config, Sampling_Started, Collected_Samples);
            end loop;
         else
            for Case_Number in 1 .. Count loop
               declare
                  Case_Started : constant Interfaces.Unsigned_64 := Clock_Now;
               begin
                  for Sample in 1 .. Natural (Config.Samples) loop
                     Collect_One (Case_Number, Sample, Case_Number);
                     exit when Sequential_Limit_Reached
                       (Case_Started, Sample);
                  end loop;
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
            Analyze (Result.Data (Case_Index));
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
