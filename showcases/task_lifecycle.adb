with Ada.Command_Line;
with Ada.Containers.Generic_Array_Sort;
with Ada.Real_Time;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.Observability;
with Flyology.Process_Lifecycle;
with Interfaces.C;
with Showcase_Support;
with System.Multiprocessors;

procedure Task_Lifecycle is
   use Ada.Real_Time;
   use Ada.Text_IO;
   use type Flyology.Execution_Model;
   use type Flyology.Observability.Counter;

   package C renames Interfaces.C;
   package Groups renames Flyology.Execution_Groups;
   package Observation renames Flyology.Observability;

   Requested_Stack_Size : constant := 16 * 1_024;
   Default_Warm_Window  : constant := 32;

   function Current_RSS return C.long_long;
   pragma Import (C, Current_RSS, "flyology_current_rss_bytes");

   function Peak_RSS return C.long_long;
   pragma Import (C, Peak_RSS, "flyology_peak_rss_bytes");

   function Virtual_Bytes return C.long_long;
   pragma Import (C, Virtual_Bytes, "flyology_virtual_bytes");

   function Thread_Count return C.int;
   pragma Import (C, Thread_Count, "flyology_thread_count");

   type Duration_Array is array (Positive range <>) of Duration;
   type Boolean_Array is array (Positive range <>) of Boolean;
   procedure Sort is new Ada.Containers.Generic_Array_Sort
     (Positive, Duration, Duration_Array);

   function Seconds (Value : Duration) return String is
     (Showcase_Support.Fixed_Image (Long_Float (Value), 9));

   function Microseconds (Value : Duration) return String is
     (Showcase_Support.Fixed_Image (Long_Float (Value) * 1_000_000.0, 3));

   function Per_Second (Count : Positive; Elapsed : Duration) return String is
     (if Elapsed <= 0.0
      then "0.000"
      else Showcase_Support.Fixed_Image
        (Long_Float (Count) / Long_Float (Elapsed), 3));

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

   function Maximum (Left, Right : C.long_long) return C.long_long is
     (C.long_long'Max (Left, Right));

   function Maximum (Left, Right : C.int) return C.int is
     (C.int'Max (Left, Right));

   type Phase_Measurements (Count : Positive) is record
      Start_Latencies    : Duration_Array (1 .. Count) := (others => 0.0);
      Complete_Latencies : Duration_Array (1 .. Count) := (others => 0.0);
      Free_Latencies     : Duration_Array (1 .. Count) := (others => 0.0);
      Creation_Wall      : Duration := 0.0;
      Completion_Wall    : Duration := 0.0;
      Finalization_Wall  : Duration := 0.0;
      Reap_Wall          : Duration := 0.0;
   end record;

   type Resource_Sample is record
      RSS     : C.long_long := 0;
      Virtual : C.long_long := 0;
      Threads : C.int := 0;
      Pool    : Observation.Stack_Pool_Snapshot;
   end record;

   function Sample return Resource_Sample is
     (RSS     => Current_RSS,
      Virtual => Virtual_Bytes,
      Threads => Thread_Count,
      Pool    => Observation.Stack_Pool);

   procedure Wait_For_Pool
     (Expected : Observation.Stack_Pool_Snapshot;
      Elapsed  : out Duration)
   is
      Started : constant Time := Clock;
      Current : Observation.Stack_Pool_Snapshot := Observation.Stack_Pool;
   begin
      for Attempt in 1 .. 10_000 loop
         exit when Current.Live_Stacks = Expected.Live_Stacks
           and then Current.Active_Arenas = Expected.Active_Arenas
           and then Current.Live_Usable_Bytes = Expected.Live_Usable_Bytes
           and then Current.Reserved_Bytes = Expected.Reserved_Bytes;
         delay 0.000_1;
         Current := Observation.Stack_Pool;
      end loop;
      Elapsed := To_Duration (Clock - Started);
      if Current.Live_Stacks /= Expected.Live_Stacks
        or else Current.Active_Arenas /= Expected.Active_Arenas
        or else Current.Live_Usable_Bytes /= Expected.Live_Usable_Bytes
        or else Current.Reserved_Bytes /= Expected.Reserved_Bytes
      then
         raise Program_Error with
           "fiber stack pool did not return to baseline";
      end if;
   end Wait_For_Pool;

   procedure Execute
     (Model          : Flyology.Execution_Model;
      Placement      : String;
      Mode           : String;
      Count          : Positive;
      Explicit_Groups : Positive;
      Creators       : Positive;
      Metrics        : in out Phase_Measurements;
      Before         : out Resource_Sample;
      Peak           : out Resource_Sample;
      After          : out Resource_Sample;
      Observed_Groups : out Natural;
      Window         : out Positive)
   is
      subtype CPU_Range is System.Multiprocessors.CPU_Range;

      function Target_CPU (Sample_Index : Positive) return CPU_Range is
        (if Model = Flyology.Native_Task or else Placement = "automatic"
         then System.Multiprocessors.Not_A_Specific_CPU
         else CPU_Range (1 + (Sample_Index - 1) mod Explicit_Groups));

      protected type Batch_Control (Target : Positive) is
         procedure Started (Slot : Positive);
         procedure Completed (Slot : Positive);
         procedure Release (At_Time : Time);
         entry Wait_Started;
         entry Wait_Completed;
         entry Start_Gate (Released_At : out Time);
      private
         Start_Count    : Natural := 0;
         Complete_Count : Natural := 0;
         Open           : Boolean := False;
         Release_Time   : Time := Time_First;
         Start_Seen     : Boolean_Array (1 .. Target) := (others => False);
         Complete_Seen  : Boolean_Array (1 .. Target) := (others => False);
      end Batch_Control;

      protected body Batch_Control is
         procedure Started (Slot : Positive) is
         begin
            if Slot not in Start_Seen'Range or else Start_Seen (Slot) then
               raise Program_Error with "task did not start exactly once";
            end if;
            Start_Seen (Slot) := True;
            Start_Count := Start_Count + 1;
         end Started;

         procedure Completed (Slot : Positive) is
         begin
            if Slot not in Complete_Seen'Range
              or else Complete_Seen (Slot)
            then
               raise Program_Error with "task did not complete exactly once";
            end if;
            Complete_Seen (Slot) := True;
            Complete_Count := Complete_Count + 1;
         end Completed;

         procedure Release (At_Time : Time) is
         begin
            if Open then
               raise Program_Error with "task lifecycle gate opened twice";
            end if;
            Release_Time := At_Time;
            Open := True;
         end Release;

         entry Wait_Started when Start_Count = Target is
         begin
            null;
         end Wait_Started;

         entry Wait_Completed when Complete_Count = Target is
         begin
            null;
         end Wait_Completed;

         entry Start_Gate (Released_At : out Time) when Open is
         begin
            Released_At := Release_Time;
         end Start_Gate;
      end Batch_Control;

      protected Anchor_Control is
         procedure Started;
         procedure Release;
         entry Wait_Started;
         entry Gate;
      private
         Has_Started : Boolean := False;
         Open        : Boolean := False;
      end Anchor_Control;

      protected body Anchor_Control is
         procedure Started is
         begin
            if Has_Started then
               raise Program_Error with "warm anchor started twice";
            end if;
            Has_Started := True;
         end Started;

         procedure Release is
         begin
            Open := True;
         end Release;

         entry Wait_Started when Has_Started is
         begin
            null;
         end Wait_Started;

         entry Gate when Open is
         begin
            null;
         end Gate;
      end Anchor_Control;

      task type Anchor (CPU : CPU_Range) with CPU => CPU is
         pragma Task_Info (Model);
         pragma Storage_Size (Requested_Stack_Size);
      end Anchor;

      task body Anchor is
      begin
         Anchor_Control.Started;
         Anchor_Control.Gate;
      end Anchor;

      type Anchor_Access is access Anchor;
      procedure Free_Anchor is new Ada.Unchecked_Deallocation
        (Anchor, Anchor_Access);

      Sample_Index : Positive := 1;
      Baseline     : Observation.Stack_Pool_Snapshot;
      Warm_Baseline : Observation.Stack_Pool_Snapshot;
      Anchor_Item  : Anchor_Access := null;
      Reap_Elapsed : Duration;
      Total_Started : Natural := 0;
      Total_Completed : Natural := 0;
      Max_RSS       : C.long_long;
      Max_Virtual   : C.long_long;
      Max_Threads   : C.int;

      procedure Run_Batch (Batch_Count : Positive) is
         Control : Batch_Control (Batch_Count);
         First_Sample : constant Positive := Sample_Index;
         Effective_Creators : constant Positive :=
           Positive'Min (Creators, Batch_Count);
         Creation_Starts : array (1 .. Batch_Count) of Time;

         task type Worker
           (Slot : Positive;
            Sample : Positive;
            CPU : CPU_Range)
           with CPU => CPU
         is
            pragma Task_Info (Model);
            pragma Storage_Size (Requested_Stack_Size);
         end Worker;

         task body Worker is
            Released_At : Time;
         begin
            Metrics.Start_Latencies (Sample) :=
              To_Duration (Clock - Creation_Starts (Slot));
            Control.Started (Slot);
            Control.Start_Gate (Released_At);
            Metrics.Complete_Latencies (Sample) :=
              To_Duration (Clock - Released_At);
            Control.Completed (Slot);
         end Worker;

         type Worker_Access is access Worker;
         type Worker_Array is array (Positive range <>) of Worker_Access;
         procedure Free_Worker is new Ada.Unchecked_Deallocation
           (Worker, Worker_Access);
         Workers : Worker_Array (1 .. Batch_Count) := (others => null);

         protected Harness_Control is
            procedure Ready;
            entry Wait_Ready;
            procedure Release_Creation;
            entry Creation_Gate;
            procedure Created;
            entry Wait_Created;
            procedure Release_Finalization;
            entry Finalization_Gate;
            procedure Finalized;
            entry Wait_Finalized;
         private
            Ready_Count     : Natural := 0;
            Created_Count   : Natural := 0;
            Finalized_Count : Natural := 0;
            Create_Open     : Boolean := False;
            Finalize_Open   : Boolean := False;
         end Harness_Control;

         protected body Harness_Control is
            procedure Ready is
            begin
               Ready_Count := Ready_Count + 1;
            end Ready;

            entry Wait_Ready when Ready_Count = Effective_Creators is
            begin
               null;
            end Wait_Ready;

            procedure Release_Creation is
            begin
               Create_Open := True;
            end Release_Creation;

            entry Creation_Gate when Create_Open is
            begin
               null;
            end Creation_Gate;

            procedure Created is
            begin
               Created_Count := Created_Count + 1;
            end Created;

            entry Wait_Created when Created_Count = Effective_Creators is
            begin
               null;
            end Wait_Created;

            procedure Release_Finalization is
            begin
               Finalize_Open := True;
            end Release_Finalization;

            entry Finalization_Gate when Finalize_Open is
            begin
               null;
            end Finalization_Gate;

            procedure Finalized is
            begin
               Finalized_Count := Finalized_Count + 1;
            end Finalized;

            entry Wait_Finalized
              when Finalized_Count = Effective_Creators
            is
            begin
               null;
            end Wait_Finalized;
         end Harness_Control;

         task type Creator (Id : Positive) is
            pragma Task_Info (Flyology.Native_Task);
         end Creator;

         task body Creator is
            Slot : Positive := Id;
            One_Free_At : Time;
         begin
            Harness_Control.Ready;
            Harness_Control.Creation_Gate;
            while Slot <= Batch_Count loop
               Creation_Starts (Slot) := Clock;
               Workers (Slot) :=
                 new Worker
                   (Slot,
                    First_Sample + Slot - 1,
                    Target_CPU (First_Sample + Slot - 1));
               Slot := Slot + Effective_Creators;
            end loop;
            Harness_Control.Created;
            Harness_Control.Finalization_Gate;
            Slot := Id;
            while Slot <= Batch_Count loop
               One_Free_At := Clock;
               Free_Worker (Workers (Slot));
               Metrics.Free_Latencies (First_Sample + Slot - 1) :=
                 To_Duration (Clock - One_Free_At);
               Slot := Slot + Effective_Creators;
            end loop;
            Harness_Control.Finalized;
         end Creator;

         type Creator_Access is access Creator;
         type Creator_Array is array (Positive range <>) of Creator_Access;
         procedure Free_Creator is new Ada.Unchecked_Deallocation
           (Creator, Creator_Access);
         Creator_Tasks : Creator_Array (1 .. Effective_Creators) :=
           (others => null);
         Started_At : Time;
         Finished_At : Time;
         Release_At : Time;
         One_Free_At : Time;
         During : Resource_Sample;
      begin
         if Creators = 1 then
            Started_At := Clock;
            for Slot in Workers'Range loop
               Creation_Starts (Slot) := Clock;
               Workers (Slot) :=
                 new Worker
                   (Slot,
                    First_Sample + Slot - 1,
                    Target_CPU (First_Sample + Slot - 1));
            end loop;
         else
            for Id in Creator_Tasks'Range loop
               Creator_Tasks (Id) := new Creator (Id);
            end loop;
            Harness_Control.Wait_Ready;
            Started_At := Clock;
            Harness_Control.Release_Creation;
            Harness_Control.Wait_Created;
         end if;
         Control.Wait_Started;
         Finished_At := Clock;
         Metrics.Creation_Wall := Metrics.Creation_Wall
           + To_Duration (Finished_At - Started_At);
         Total_Started := Total_Started + Batch_Count;

         During := Sample;
         Max_RSS := Maximum (Max_RSS, During.RSS);
         Max_Virtual := Maximum (Max_Virtual, During.Virtual);
         Max_Threads := Maximum (Max_Threads, During.Threads);
         if During.Pool.Live_Stacks > Peak.Pool.Live_Stacks then
            Peak.Pool := During.Pool;
         end if;

         Release_At := Clock;
         Control.Release (Release_At);
         Control.Wait_Completed;
         Finished_At := Clock;
         Metrics.Completion_Wall := Metrics.Completion_Wall
           + To_Duration (Finished_At - Release_At);
         Total_Completed := Total_Completed + Batch_Count;

         Started_At := Clock;
         if Creators = 1 then
            for Slot in Workers'Range loop
               One_Free_At := Clock;
               Free_Worker (Workers (Slot));
               Metrics.Free_Latencies (First_Sample + Slot - 1) :=
                 To_Duration (Clock - One_Free_At);
            end loop;
         else
            Harness_Control.Release_Finalization;
            Harness_Control.Wait_Finalized;
         end if;
         Metrics.Finalization_Wall := Metrics.Finalization_Wall
           + To_Duration (Clock - Started_At);

         if Creators > 1 then
            for Id in Creator_Tasks'Range loop
               while not Creator_Tasks (Id).all'Terminated loop
                  delay 0.000_1;
               end loop;
               Free_Creator (Creator_Tasks (Id));
            end loop;
         end if;

         Wait_For_Pool
           ((if Anchor_Item = null then Baseline else Warm_Baseline),
            Reap_Elapsed);
         Metrics.Reap_Wall := Metrics.Reap_Wall + Reap_Elapsed;
         Sample_Index := Sample_Index + Batch_Count;
      end Run_Batch;

   begin
      Before := Sample;
      Peak := Before;
      Baseline := Before.Pool;
      Max_RSS := Before.RSS;
      Max_Virtual := Before.Virtual;
      Max_Threads := Before.Threads;

      if Mode = "warm" then
         Window := Positive'Min (Default_Warm_Window, Count);
         Anchor_Item := new Anchor (Target_CPU (1));
         Anchor_Control.Wait_Started;
         Warm_Baseline := Observation.Stack_Pool;
         if Model = Flyology.Lightweight_Task
           and then Warm_Baseline.Live_Stacks /= Baseline.Live_Stacks + 1
         then
            raise Program_Error with "warm anchor did not retain one stack";
         end if;
      else
         Window := Count;
         Warm_Baseline := Baseline;
      end if;

      while Sample_Index <= Count loop
         Run_Batch
           (Positive'Min (Window, Count - Sample_Index + 1));
      end loop;

      if Anchor_Item /= null then
         Anchor_Control.Release;
         while not Anchor_Item.all'Terminated loop
            delay 0.000_1;
         end loop;
         Free_Anchor (Anchor_Item);
         Wait_For_Pool (Baseline, Reap_Elapsed);
         Metrics.Reap_Wall := Metrics.Reap_Wall + Reap_Elapsed;
      end if;

      if Total_Started /= Count or else Total_Completed /= Count then
         raise Program_Error with "not every task ran exactly once";
      end if;
      After := Sample;
      Peak.RSS := Max_RSS;
      Peak.Virtual := Max_Virtual;
      Peak.Threads := Max_Threads;
      Observed_Groups :=
        Natural (Flyology.Process_Lifecycle.Created_Groups);
   end Execute;

   procedure Usage is
   begin
      Put_Line
        (Standard_Error,
         "usage: task_lifecycle lightweight|native automatic|explicit "
         & "cold|warm COUNT EXPLICIT_GROUPS CREATORS RUN");
   end Usage;

   procedure Put_CSV_Field (Value : String) is
   begin
      Put ('"');
      for Character of Value loop
         if Character = '"' then
            Put ("""""");
         else
            Put (Character);
         end if;
      end loop;
      Put ('"');
   end Put_CSV_Field;

begin
   if Ada.Command_Line.Argument_Count /= 7 then
      Usage;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   declare
      Model_Name : constant String := Ada.Command_Line.Argument (1);
      Placement : constant String := Ada.Command_Line.Argument (2);
      Mode : constant String := Ada.Command_Line.Argument (3);
      Count : constant Positive :=
        Positive'Value (Ada.Command_Line.Argument (4));
      Explicit_Groups : constant Positive :=
        Positive'Value (Ada.Command_Line.Argument (5));
      Creators : constant Positive :=
        Positive'Value (Ada.Command_Line.Argument (6));
      Run : constant Positive :=
        Positive'Value (Ada.Command_Line.Argument (7));
      Model : constant Flyology.Execution_Model :=
        (if Model_Name = "lightweight"
         then Flyology.Lightweight_Task
         else Flyology.Native_Task);
      Metrics : Phase_Measurements (Count);
      Before, Peak, After : Resource_Sample;
      Observed_Groups : Natural;
      Window : Positive;
      Start_Ordered : Duration_Array (1 .. Count) := (others => 0.0);
      Complete_Ordered : Duration_Array (1 .. Count) := (others => 0.0);
      Free_Ordered : Duration_Array (1 .. Count) := (others => 0.0);
      Total_Wall : Duration;
   begin
      if (Model_Name /= "lightweight" and then Model_Name /= "native")
        or else (Placement /= "automatic" and then Placement /= "explicit")
        or else (Mode /= "cold" and then Mode /= "warm")
        or else Explicit_Groups > 127
      then
         raise Constraint_Error;
      end if;
      if Model_Name = "native" and then Placement /= "automatic" then
         raise Constraint_Error;
      elsif Model_Name = "native" and then Creators > 1 then
         raise Constraint_Error;
      end if;

      Execute
        (Model,
         Placement,
         Mode,
         Count,
         Explicit_Groups,
         Creators,
         Metrics,
         Before,
         Peak,
         After,
         Observed_Groups,
         Window);
      Start_Ordered := Metrics.Start_Latencies;
      Complete_Ordered := Metrics.Complete_Latencies;
      Free_Ordered := Metrics.Free_Latencies;
      Sort (Start_Ordered);
      Sort (Complete_Ordered);
      Sort (Free_Ordered);
      Total_Wall := Metrics.Creation_Wall + Metrics.Completion_Wall
        + Metrics.Finalization_Wall + Metrics.Reap_Wall;

      Put_Line
        (Standard_Error,
         Model_Name & " " & Placement & " " & Mode
         & " count=" & Count'Image
         & " configured_groups=" & Groups.Configured_Pool_Size'Image
         & " observed_groups=" & Observed_Groups'Image
         & " creators=" & Creators'Image
         & " window=" & Window'Image);
      Put_Line
        (Standard_Error,
         "  create/start: wall=" & Seconds (Metrics.Creation_Wall)
         & " s throughput=" & Per_Second (Count, Metrics.Creation_Wall)
         & "/s p50/p95/p99="
         & Microseconds (Percentile (Start_Ordered, 50)) & "/"
         & Microseconds (Percentile (Start_Ordered, 95)) & "/"
         & Microseconds (Percentile (Start_Ordered, 99)) & " us");
      Put_Line
        (Standard_Error,
         "  body completion: wall=" & Seconds (Metrics.Completion_Wall)
         & " s throughput=" & Per_Second (Count, Metrics.Completion_Wall)
         & "/s p50/p95/p99="
         & Microseconds (Percentile (Complete_Ordered, 50)) & "/"
         & Microseconds (Percentile (Complete_Ordered, 95)) & "/"
         & Microseconds (Percentile (Complete_Ordered, 99)) & " us");
      Put_Line
        (Standard_Error,
         "  task-object finalization: wall="
         & Seconds (Metrics.Finalization_Wall)
         & " s throughput=" & Per_Second (Count, Metrics.Finalization_Wall)
         & "/s p50/p95/p99="
         & Microseconds (Percentile (Free_Ordered, 50)) & "/"
         & Microseconds (Percentile (Free_Ordered, 95)) & "/"
         & Microseconds (Percentile (Free_Ordered, 99)) & " us");
      Put_Line
        (Standard_Error,
         "  observable fiber/stack reap: wall=" & Seconds (Metrics.Reap_Wall)
         & " s maps/unmaps/reuse="
         & Observation.Counter'Image
             (After.Pool.Arena_Mappings - Before.Pool.Arena_Mappings) & "/"
         & Observation.Counter'Image
             (After.Pool.Arena_Unmappings - Before.Pool.Arena_Unmappings) & "/"
         & Observation.Counter'Image
             (After.Pool.Shared_Stacks - Before.Pool.Shared_Stacks));
      Put_Line
        (Standard_Error,
         "  resources: rss_peak=" & Peak.RSS'Image
         & " virtual_peak=" & Peak.Virtual'Image
         & " threads_peak=" & Peak.Threads'Image
         & " live_stack_peak=" & Peak.Pool.Live_Stacks'Image
         & " arenas_peak=" & Peak.Pool.Active_Arenas'Image
         & " usable_peak=" & Peak.Pool.Live_Usable_Bytes'Image
         & " reserved_peak=" & Peak.Pool.Reserved_Bytes'Image);

      Put_CSV_Field ("1"); Put (',');
      Put_CSV_Field (Run'Image); Put (',');
      Put_CSV_Field (Model_Name); Put (',');
      Put_CSV_Field (Placement); Put (',');
      Put_CSV_Field (Mode); Put (',');
      Put_CSV_Field (Count'Image); Put (',');
      Put_CSV_Field (Groups.Configured_Pool_Size'Image); Put (',');
      Put_CSV_Field (Observed_Groups'Image); Put (',');
      Put_CSV_Field (Requested_Stack_Size'Image); Put (',');
      Put_CSV_Field (Creators'Image); Put (',');
      Put_CSV_Field (Window'Image); Put (',');
      Put_CSV_Field (Seconds (Metrics.Creation_Wall)); Put (',');
      Put_CSV_Field (Per_Second (Count, Metrics.Creation_Wall)); Put (',');
      Put_CSV_Field
        (Microseconds (Percentile (Start_Ordered, 50))); Put (',');
      Put_CSV_Field
        (Microseconds (Percentile (Start_Ordered, 95))); Put (',');
      Put_CSV_Field
        (Microseconds (Percentile (Start_Ordered, 99))); Put (',');
      Put_CSV_Field (Seconds (Metrics.Completion_Wall)); Put (',');
      Put_CSV_Field (Per_Second (Count, Metrics.Completion_Wall)); Put (',');
      Put_CSV_Field
        (Microseconds (Percentile (Complete_Ordered, 50))); Put (',');
      Put_CSV_Field
        (Microseconds (Percentile (Complete_Ordered, 95))); Put (',');
      Put_CSV_Field
        (Microseconds (Percentile (Complete_Ordered, 99))); Put (',');
      Put_CSV_Field (Seconds (Metrics.Finalization_Wall)); Put (',');
      Put_CSV_Field (Per_Second (Count, Metrics.Finalization_Wall)); Put (',');
      Put_CSV_Field
        (Microseconds (Percentile (Free_Ordered, 50))); Put (',');
      Put_CSV_Field
        (Microseconds (Percentile (Free_Ordered, 95))); Put (',');
      Put_CSV_Field
        (Microseconds (Percentile (Free_Ordered, 99))); Put (',');
      Put_CSV_Field (Seconds (Metrics.Reap_Wall)); Put (',');
      Put_CSV_Field (Seconds (Total_Wall)); Put (',');
      Put_CSV_Field (Before.RSS'Image); Put (',');
      Put_CSV_Field (Peak.RSS'Image); Put (',');
      Put_CSV_Field (Peak_RSS'Image); Put (',');
      Put_CSV_Field (Before.Virtual'Image); Put (',');
      Put_CSV_Field (Peak.Virtual'Image); Put (',');
      Put_CSV_Field (Before.Threads'Image); Put (',');
      Put_CSV_Field (Peak.Threads'Image); Put (',');
      Put_CSV_Field (Before.Pool.Live_Stacks'Image); Put (',');
      Put_CSV_Field (Peak.Pool.Live_Stacks'Image); Put (',');
      Put_CSV_Field (After.Pool.Live_Stacks'Image); Put (',');
      Put_CSV_Field (Peak.Pool.Active_Arenas'Image); Put (',');
      Put_CSV_Field (Peak.Pool.Live_Usable_Bytes'Image); Put (',');
      Put_CSV_Field (Peak.Pool.Reserved_Bytes'Image); Put (',');
      Put_CSV_Field
        (Observation.Counter'Image
           (After.Pool.Arena_Mappings - Before.Pool.Arena_Mappings));
      Put (',');
      Put_CSV_Field
        (Observation.Counter'Image
           (After.Pool.Arena_Unmappings - Before.Pool.Arena_Unmappings));
      Put (',');
      Put_CSV_Field
        (Observation.Counter'Image
           (After.Pool.Shared_Stacks - Before.Pool.Shared_Stacks));
      Put (',');
      Put_CSV_Field
        (Observation.Counter'Image
           (After.Pool.Discarded_Stacks - Before.Pool.Discarded_Stacks));
      Put (',');
      Put_CSV_Field ("true");
      New_Line;
   end;
exception
   when Constraint_Error =>
      Usage;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Task_Lifecycle;
