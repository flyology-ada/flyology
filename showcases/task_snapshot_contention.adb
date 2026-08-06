with Ada.Command_Line;
with Ada.Containers.Generic_Array_Sort;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.Observability;
with Showcase_Support;
with System.Multiprocessors;

procedure Task_Snapshot_Contention is
   use Ada.Real_Time;
   use Ada.Text_IO;
   use type Flyology.Observability.Counter;
   use type Flyology.Observability.Task_Instance_Id;

   package Observation renames Flyology.Observability;

   Requested_Stack_Size : constant := 16 * 1_024;
   Max_Latency_Samples  : constant := 200_000;

   type Duration_Array is array (Positive range <>) of Duration;
   procedure Sort_Durations is new Ada.Containers.Generic_Array_Sort
     (Positive, Duration, Duration_Array);

   type Instance_Array is
     array (Positive range <>) of Observation.Task_Instance_Id;
   procedure Sort_Instances is new Ada.Containers.Generic_Array_Sort
     (Positive, Observation.Task_Instance_Id, Instance_Array);

   function Image (Value : Long_Long_Integer) return String is
     (Ada.Strings.Fixed.Trim
        (Long_Long_Integer'Image (Value), Ada.Strings.Both));

   function Fixed (Value : Long_Float; Decimals : Natural) return String is
     (Showcase_Support.Fixed_Image (Value, Decimals));

   function Percentile
     (Values : Duration_Array;
      Numerator : Positive) return Duration
   is
      Position : constant Positive :=
        Positive'Min
          (Values'Length,
           Positive'Max (1, (Values'Length * Numerator + 99) / 100));
   begin
      return Values (Values'First + Position - 1);
   end Percentile;

   function Microseconds (Value : Duration) return String is
     (Fixed (Long_Float (Value) * 1_000_000.0, 3));

   Operation : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1)
      else "tasks");
   Member_Count : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Positive'Value (Ada.Command_Line.Argument (2))
      else 1_000);
   Capacity : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 3
      then Positive'Value (Ada.Command_Line.Argument (3))
      else 32);
   Window : constant Duration :=
     (if Ada.Command_Line.Argument_Count >= 4
      then Duration'Value (Ada.Command_Line.Argument (4))
      else 0.200);
   Run : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 5
      then Positive'Value (Ada.Command_Line.Argument (5))
      else 1);
   Interval : constant Duration :=
     (if Ada.Command_Line.Argument_Count >= 6
      then Duration'Value (Ada.Command_Line.Argument (6))
      else 0.0);

   protected Control is
      procedure Started;
      entry Wait_All_Started;
      entry Park;
      procedure Release_Parked;
      entry Start_Spinning;
      procedure Release_Spinner;
      procedure Advance (Continue : out Boolean);
      procedure Stop_Spinner;
      function Ticks return Observation.Counter;
   private
      Started_Count : Natural := 0;
      Park_Open     : Boolean := False;
      Spin_Open     : Boolean := False;
      Stop          : Boolean := False;
      Tick_Count    : Observation.Counter := 0;
   end Control;

   protected body Control is
      procedure Started is
      begin
         Started_Count := Started_Count + 1;
         if Started_Count > Member_Count then
            raise Program_Error with "task started more than once";
         end if;
      end Started;

      entry Wait_All_Started when Started_Count = Member_Count is
      begin
         null;
      end Wait_All_Started;

      entry Park when Park_Open is
      begin
         null;
      end Park;

      procedure Release_Parked is
      begin
         Park_Open := True;
      end Release_Parked;

      entry Start_Spinning when Spin_Open is
      begin
         null;
      end Start_Spinning;

      procedure Release_Spinner is
      begin
         Spin_Open := True;
      end Release_Spinner;

      procedure Advance (Continue : out Boolean) is
      begin
         Continue := not Stop;
         if Continue then
            Tick_Count := Tick_Count + 1;
         end if;
      end Advance;

      procedure Stop_Spinner is
      begin
         Stop := True;
      end Stop_Spinner;

      function Ticks return Observation.Counter is (Tick_Count);
   end Control;

   subtype CPU_Range is System.Multiprocessors.CPU_Range;
   Group_CPU : constant CPU_Range :=
     System.Multiprocessors.Not_A_Specific_CPU;

   task type Parked_Task (Slot : Positive; CPU : CPU_Range)
     with CPU => CPU
   is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (Requested_Stack_Size);
   end Parked_Task;

   task body Parked_Task is
      pragma Unreferenced (Slot);
   begin
      Control.Started;
      Control.Park;
   end Parked_Task;

   task type Spinner_Task (CPU : CPU_Range) with CPU => CPU is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Storage_Size (Requested_Stack_Size);
   end Spinner_Task;

   task body Spinner_Task is
      Continue : Boolean;
   begin
      Control.Started;
      Control.Start_Spinning;
      loop
         Control.Advance (Continue);
         exit when not Continue;
         delay 0.0;
      end loop;
   end Spinner_Task;

   type Parked_Access is access Parked_Task;
   type Spinner_Access is access Spinner_Task;
   type Parked_Access_Array is array (Positive range <>) of Parked_Access;
   procedure Free_Parked is new Ada.Unchecked_Deallocation
     (Parked_Task, Parked_Access);
   procedure Free_Spinner is new Ada.Unchecked_Deallocation
     (Spinner_Task, Spinner_Access);

begin
   if Operation /= "tasks" and then Operation /= "group" then
      raise Constraint_Error with "operation must be tasks or group";
   elsif Member_Count < 2 then
      raise Constraint_Error with "member count must be at least two";
   elsif Window <= 0.0 then
      raise Constraint_Error with "measurement window must be positive";
   elsif Interval < 0.0 then
      raise Constraint_Error with "observation interval must not be negative";
   end if;

   declare
      Parked : Parked_Access_Array (1 .. Member_Count - 1);
      Spinner : Spinner_Access;
      Items : Observation.Task_Snapshot_Array (1 .. Capacity);
      Instances : Instance_Array (1 .. Capacity);
      Latencies : Duration_Array (1 .. Max_Latency_Samples);
      Sample_Count : Natural := 0;
      Calls : Natural := 0;
      Written : Natural;
      Total : Observation.Counter;
      Group_Sample : Observation.Group_Snapshot;
      Before_Ticks, Observe_Ticks, After_Ticks, Final_Ticks :
        Observation.Counter;
      Before_Start, Before_End, Observe_Start, Observe_End : Time;
      After_Start, After_End : Time;
      Next_Observation : Time;
      Started, Finished : Time;
      Baseline_Seconds, Observe_Seconds : Duration;
      Baseline_Rate, Observe_Rate, Rate_Percent : Long_Float;
      Call_Throughput : Long_Float;
      Maximum : Duration;

      procedure Validate_Task_Snapshot is
      begin
         if Total /= Observation.Counter (Member_Count)
           or else Written /= Natural'Min (Capacity, Member_Count)
         then
            raise Program_Error with "task snapshot membership mismatch";
         end if;
         for Index in 1 .. Written loop
            if Items (Index).Instance = Observation.No_Task_Instance then
               raise Program_Error with "task snapshot returned zero identity";
            end if;
            Instances (Index) := Items (Index).Instance;
         end loop;
         if Written > 1 then
            Sort_Instances (Instances (1 .. Written));
            for Index in 2 .. Written loop
               if Instances (Index) = Instances (Index - 1) then
                  raise Program_Error with
                    "task snapshot returned duplicate identity";
               end if;
            end loop;
         end if;
      end Validate_Task_Snapshot;

      procedure Observe_Once is
         Available : Boolean;
      begin
         if Operation = "tasks" then
            Available := Observation.Snapshot_Tasks
              (0, Items, Written, Total);
            if not Available
              or else Total /= Observation.Counter (Member_Count)
              or else Written /= Natural'Min (Capacity, Member_Count)
            then
               raise Program_Error with "task snapshot changed membership";
            end if;
         else
            Available := Observation.Snapshot (0, Group_Sample);
            if not Available
              or else Group_Sample.Members /=
                Observation.Counter (Member_Count)
            then
               raise Program_Error with "group snapshot changed membership";
            end if;
         end if;
      end Observe_Once;
   begin
      for Index in Parked'Range loop
         Parked (Index) := new Parked_Task (Index, Group_CPU);
      end loop;
      Spinner := new Spinner_Task (Group_CPU);
      Control.Wait_All_Started;

      if not Observation.Snapshot_Tasks (0, Items, Written, Total) then
         raise Program_Error with "group zero was absent";
      end if;
      Validate_Task_Snapshot;

      Control.Release_Spinner;
      Before_Ticks := Control.Ticks;
      Before_Start := Clock;
      delay Window;
      Before_End := Clock;
      Observe_Ticks := Control.Ticks;

      Observe_Start := Clock;
      Observe_End := Observe_Start + To_Time_Span (Window);
      Next_Observation := Observe_Start;
      while Clock < Observe_End loop
         Started := Clock;
         Observe_Once;
         Finished := Clock;
         Calls := Calls + 1;
         if Sample_Count < Max_Latency_Samples then
            Sample_Count := Sample_Count + 1;
            Latencies (Sample_Count) := To_Duration (Finished - Started);
         end if;
         if Interval > 0.0 then
            Next_Observation :=
              Next_Observation + To_Time_Span (Interval);
            exit when Next_Observation >= Observe_End;
            delay until Next_Observation;
         end if;
      end loop;
      Observe_End := Clock;
      After_Ticks := Control.Ticks;

      After_Start := Clock;
      delay Window;
      After_End := Clock;
      Final_Ticks := Control.Ticks;

      Control.Stop_Spinner;
      Control.Release_Parked;
      while not Spinner.all'Terminated loop
         delay 0.000_1;
      end loop;
      Free_Spinner (Spinner);
      for Index in Parked'Range loop
         while not Parked (Index).all'Terminated loop
            delay 0.000_1;
         end loop;
         Free_Parked (Parked (Index));
      end loop;

      if Calls = 0 or else Sample_Count = 0 then
         raise Program_Error with "observation phase made no calls";
      end if;
      Sort_Durations (Latencies (1 .. Sample_Count));
      Maximum := Latencies (Sample_Count);
      Baseline_Seconds :=
        To_Duration (Before_End - Before_Start)
        + To_Duration (After_End - After_Start);
      Observe_Seconds := To_Duration (Observe_End - Observe_Start);
      Baseline_Rate :=
        Long_Float
          ((Observe_Ticks - Before_Ticks) + (Final_Ticks - After_Ticks))
        / Long_Float (Baseline_Seconds);
      Observe_Rate := Long_Float (After_Ticks - Observe_Ticks)
        / Long_Float (Observe_Seconds);
      Rate_Percent :=
        (if Baseline_Rate = 0.0
         then 0.0
         else 100.0 * Observe_Rate / Baseline_Rate);
      Call_Throughput := Long_Float (Calls) / Long_Float (Observe_Seconds);

      Put_Line
        (Standard_Error,
         Operation & " snapshot contention: members="
         & Image (Long_Long_Integer (Member_Count))
         & " capacity=" & Image (Long_Long_Integer (Capacity))
         & " interval_s=" & Fixed (Long_Float (Interval), 6)
         & " calls/s=" & Fixed (Call_Throughput, 1)
         & " p99_us="
         & Microseconds (Percentile (Latencies (1 .. Sample_Count), 99))
         & " runnable_rate=" & Fixed (Rate_Percent, 1)
         & "% of adjacent baseline");

      Put_Line
        ("1," & Image (Long_Long_Integer (Run))
         & "," & Operation
         & "," & Image (Long_Long_Integer (Member_Count))
         & "," & Image (Long_Long_Integer (Capacity))
         & "," & Fixed (Long_Float (Interval), 6)
         & "," & Fixed (Long_Float (Observe_Seconds), 6)
         & "," & Image (Long_Long_Integer (Calls))
         & "," & Fixed (Call_Throughput, 3)
         & "," & Microseconds (Percentile (Latencies (1 .. Sample_Count), 50))
         & "," & Microseconds (Percentile (Latencies (1 .. Sample_Count), 95))
         & "," & Microseconds (Percentile (Latencies (1 .. Sample_Count), 99))
         & "," & Microseconds (Maximum)
         & "," & Fixed (Baseline_Rate, 3)
         & "," & Fixed (Observe_Rate, 3)
         & "," & Fixed (Rate_Percent, 3));
   exception
      when Failure : others =>
         Control.Stop_Spinner;
         Control.Release_Spinner;
         Control.Release_Parked;
         Put_Line
           (Standard_Error,
            "task snapshot benchmark failed: "
            & Ada.Exceptions.Exception_Information (Failure));
         raise;
   end;
end Task_Snapshot_Contention;
