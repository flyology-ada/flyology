with Ada.Text_IO;
with Flyology;
with Flyology.Observability;

procedure Runtime_Observability is
   package Observation renames Flyology.Observability;
   package TIO renames Ada.Text_IO;

   Task_Count : constant := 128;

   protected Load is
      procedure Started;
      procedure Open;
      entry Wait_Until_Started;
      entry Wait_Until_Finished;
      entry Gate;
      procedure Finished;
   private
      Started_Count  : Natural := 0;
      Finished_Count : Natural := 0;
      Is_Open        : Boolean := False;
   end Load;

   protected body Load is
      procedure Started is
      begin
         Started_Count := Started_Count + 1;
      end Started;

      procedure Open is
      begin
         Is_Open := True;
      end Open;

      entry Wait_Until_Started when Started_Count = Task_Count is
      begin
         null;
      end Wait_Until_Started;

      entry Wait_Until_Finished when Finished_Count = Task_Count is
      begin
         null;
      end Wait_Until_Finished;

      entry Gate when Is_Open is
      begin
         null;
      end Gate;

      procedure Finished is
      begin
         Finished_Count := Finished_Count + 1;
      end Finished;
   end Load;

   procedure Print (Label : String; Item : Observation.Group_Snapshot) is
   begin
      TIO.Put_Line
        (Label
         & " group="
         & Item.Group'Image
         & " members="
         & Item.Members'Image
         & " pinned="
         & Item.Pinned_Members'Image
         & " ready="
         & Item.Ready'Image
         & " waiting="
         & Item.Waiting'Image
         & " running="
         & Item.Running'Image);
      TIO.Put_Line
        ("  timers="
         & Item.Timer_Waits'Image
         & " descriptors="
         & Item.Descriptor_Waits'Image
         & " files="
         & Item.File_Waits'Image
         & " queued-files="
         & Item.Pending_File_Submissions'Image);
      TIO.Put_Line
        ("  dispatches="
         & Item.Dispatches'Image
         & " poll-batches="
         & Item.Poll_Batches'Image
         & " poll-events="
         & Item.Poll_Events'Image
         & " wakeups="
         & Item.Wakeups'Image);
   end Print;

   First, Idle, Released : Observation.Group_Snapshot;
begin
   declare
      task type Worker is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Worker;

      task body Worker is
      begin
         Load.Started;
         Load.Gate;
         Load.Finished;
      end Worker;

      Workers : array (1 .. Task_Count) of Worker;
   begin
      Load.Wait_Until_Started;
      delay 0.010;
      if not Observation.Snapshot (0, First) then
         raise Program_Error with "group 0 was not created";
      end if;
      delay 0.050;
      if not Observation.Snapshot (0, Idle) then
         raise Program_Error with "group 0 disappeared";
      end if;
      Print ("parked", Idle);
      TIO.Put_Line
        ("  progress over idle sample: " & Boolean'Image (Observation.Made_Progress (First, Idle)));

      Load.Open;
      Load.Wait_Until_Finished;
   end;

   delay 0.010;
   if not Observation.Snapshot (0, Released) then
      raise Program_Error with "group 0 disappeared";
   end if;
   Print ("released", Released);
   TIO.Put_Line ("  progress after release: " & Boolean'Image (Observation.Made_Progress (Idle, Released)));
end Runtime_Observability;
