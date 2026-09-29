with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Flyology.Dormancy;
with Flyology.Observability;
with Interfaces;
with Interfaces.C;
with Showcase_Support;

procedure Dormant_Stack_Pressure is
   use Ada.Real_Time;
   use Ada.Text_IO;

   package C renames Interfaces.C;
   package Dormancy renames Flyology.Dormancy;
   package Observation renames Flyology.Observability;

   use type C.int;
   use type C.long_long;
   use type Dormancy.Policy;
   use type Interfaces.Unsigned_64;

   Payload_Bytes     : constant := 256 * 1_024;
   Worker_Stack_Size : constant := 384 * 1_024;
   Page_Bytes        : constant := 4 * 1_024;
   Wake_Lead_Time    : constant Duration := 3.0;

   function Current_RSS return C.long_long;
   pragma Import (C, Current_RSS, "flyology_current_rss_bytes");

   function Apply_Memory_Pressure (Bytes : C.long_long) return C.int;
   pragma Import (C, Apply_Memory_Pressure, "flyology_apply_memory_pressure");

   function MiB (Bytes : C.long_long) return Long_Float
   is (Long_Float (Bytes) / (1_024.0 * 1_024.0));

   procedure Usage is
   begin
      Put_Line ("usage: dormant_stack_pressure prompt|reclaimable|pageout" & " TASKS PRESSURE_MIB");
   end Usage;

   procedure Run
     (Selected_Policy : Dormancy.Policy; Policy_Name : String; Task_Count : Positive; Pressure_MiB : Positive)
   is
      protected Progress is
         procedure Ready;
         entry Wait_Until_Ready;
         entry Await_Wake_Time (Target : out Time);
         procedure Start_Timer_Waits (Target : Time);
         procedure Parked;
         entry Wait_Until_Parked;
         procedure Finished (Lateness : Duration; Checksum : Interfaces.Unsigned_64);
         entry Wait_Until_Finished;
         function Maximum_Lateness return Duration;
         function Combined_Checksum return Interfaces.Unsigned_64;
      private
         Ready_Count    : Natural := 0;
         Parked_Count   : Natural := 0;
         Finished_Count : Natural := 0;
         Timers_Started : Boolean := False;
         Wake_Time      : Time := Time_First;
         Maximum_Delay  : Duration := 0.0;
         Total_Checksum : Interfaces.Unsigned_64 := 0;
      end Progress;

      protected body Progress is
         procedure Ready is
         begin
            Ready_Count := Ready_Count + 1;
         end Ready;

         entry Wait_Until_Ready when Ready_Count = Task_Count is
         begin
            null;
         end Wait_Until_Ready;

         entry Await_Wake_Time (Target : out Time) when Timers_Started is
         begin
            Target := Wake_Time;
         end Await_Wake_Time;

         procedure Start_Timer_Waits (Target : Time) is
         begin
            Wake_Time := Target;
            Timers_Started := True;
         end Start_Timer_Waits;

         procedure Parked is
         begin
            Parked_Count := Parked_Count + 1;
         end Parked;

         entry Wait_Until_Parked when Parked_Count = Task_Count is
         begin
            null;
         end Wait_Until_Parked;

         procedure Finished (Lateness : Duration; Checksum : Interfaces.Unsigned_64) is
         begin
            Finished_Count := Finished_Count + 1;
            Maximum_Delay := Duration'Max (Maximum_Delay, Lateness);
            Total_Checksum := Total_Checksum + Checksum;
         end Finished;

         entry Wait_Until_Finished when Finished_Count = Task_Count is
         begin
            null;
         end Wait_Until_Finished;

         function Maximum_Lateness return Duration
         is (Maximum_Delay);

         function Combined_Checksum return Interfaces.Unsigned_64
         is (Total_Checksum);
      end Progress;

      task type Worker (Index : Positive) with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
         pragma Storage_Size (Worker_Stack_Size);
      end Worker;

      task body Worker is
         type Payload_Array is array (Positive range 1 .. Payload_Bytes) of Interfaces.Unsigned_8;
         Payload  : Payload_Array
         with Volatile;
         Target   : Time;
         Checksum : Interfaces.Unsigned_64 := 0;
      begin
         for Offset in 1 .. (Payload_Bytes + Page_Bytes - 1) / Page_Bytes loop
            Payload ((Offset - 1) * Page_Bytes + 1) := Interfaces.Unsigned_8 ((Index + Offset) mod 251 + 1);
         end loop;
         Progress.Ready;
         Progress.Await_Wake_Time (Target);
         Dormancy.Set_Policy (Selected_Policy, Minimum_Wait => 0.0);
         Progress.Parked;
         delay until Target;
         for Offset in 1 .. (Payload_Bytes + Page_Bytes - 1) / Page_Bytes loop
            Checksum := Checksum + Interfaces.Unsigned_64 (Payload ((Offset - 1) * Page_Bytes + 1));
         end loop;
         Progress.Finished (Lateness => To_Duration (Clock - Target), Checksum => Checksum);
      end Worker;

      type Worker_Access is access Worker;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Task_Count);

      Before_RSS       : C.long_long;
      After_RSS        : C.long_long;
      Sample           : Observation.Group_Snapshot;
      Observed_Waiters : Boolean := False;
      Pressure_Bytes   : constant C.long_long := C.long_long (Pressure_MiB) * 1_024 * 1_024;
   begin
      for Index in Workers'Range loop
         Workers (Index) := new Worker (Index);
      end loop;
      Progress.Wait_Until_Ready;
      Progress.Start_Timer_Waits (Clock + To_Time_Span (Wake_Lead_Time));
      Progress.Wait_Until_Parked;

      for Attempt in 1 .. 2_000 loop
         Observed_Waiters :=
           Observation.Snapshot (1, Sample)
           and then Sample.Dormancy_Candidates = Observation.Counter (Task_Count)
           and then (Selected_Policy = Dormancy.Prompt
                     or else (Selected_Policy = Dormancy.Reclaimable
                              and then (not Dormancy.Cold_Advice_Supported
                                        or else Sample.Cold_Stacks = Observation.Counter (Task_Count)))
                     or else (Selected_Policy = Dormancy.Page_Out
                              and then (not Dormancy.Pageout_Advice_Supported
                                        or else Sample.Cold_Stacks = Observation.Counter (Task_Count))));
         exit when Observed_Waiters;
         delay 0.001;
      end loop;
      if not Observed_Waiters then
         raise Program_Error with "timer wait sample did not stabilize";
      end if;

      Before_RSS := Current_RSS;
      if Apply_Memory_Pressure (Pressure_Bytes) /= 0 then
         raise Program_Error with "memory-pressure mapping failed";
      end if;
      After_RSS := Current_RSS;
      Progress.Wait_Until_Finished;
      if Progress.Combined_Checksum = 0 then
         raise Program_Error with "stack payload was not retained";
      end if;

      Put_Line
        ("policy="
         & Policy_Name
         & " cold_supported="
         & Boolean'Image (Dormancy.Cold_Advice_Supported)
         & " pageout_supported="
         & Boolean'Image (Dormancy.Pageout_Advice_Supported)
         & " tasks="
         & Task_Count'Image
         & " payload="
         & Natural'Image (Payload_Bytes / 1_024)
         & " KiB"
         & " pressure="
         & Pressure_MiB'Image
         & " MiB");
      Put_Line
        ("  timer_wait: candidates="
         & Sample.Dormancy_Candidates'Image
         & " cold="
         & Sample.Cold_Stacks'Image
         & " cold_accepted="
         & Sample.Cold_Advice_Accepted'Image
         & " pageout_accepted="
         & Sample.Pageout_Advice_Accepted'Image);
      Put_Line
        ("  rss: before_pressure="
         & Showcase_Support.Fixed_Image (MiB (Before_RSS))
         & " MiB after_pressure="
         & Showcase_Support.Fixed_Image (MiB (After_RSS))
         & " MiB delta="
         & Showcase_Support.Fixed_Image (MiB (After_RSS - Before_RSS))
         & " MiB");
      Put_Line
        ("  wake: maximum_lateness="
         & Showcase_Support.Fixed_Image (Long_Float (Progress.Maximum_Lateness) * 1_000.0, 3)
         & " ms checksum="
         & Progress.Combined_Checksum'Image);
   end Run;

begin
   if Ada.Command_Line.Argument_Count /= 3 then
      Usage;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   declare
      Policy_Name  : constant String := Ada.Command_Line.Argument (1);
      Task_Count   : constant Positive := Positive'Value (Ada.Command_Line.Argument (2));
      Pressure_MiB : constant Positive := Positive'Value (Ada.Command_Line.Argument (3));
   begin
      if Policy_Name = "prompt" then
         Run (Dormancy.Prompt, Policy_Name, Task_Count, Pressure_MiB);
      elsif Policy_Name = "reclaimable" then
         Run (Dormancy.Reclaimable, Policy_Name, Task_Count, Pressure_MiB);
      elsif Policy_Name = "pageout" then
         Run (Dormancy.Page_Out, Policy_Name, Task_Count, Pressure_MiB);
      else
         Usage;
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end;
exception
   when Constraint_Error =>
      Usage;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Dormant_Stack_Pressure;
