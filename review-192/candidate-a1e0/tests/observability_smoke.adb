with Flyology;
with Flyology.Debug_Producer_Selection;
with Flyology.Execution_Groups;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Observability;
with Interfaces;

procedure Observability_Smoke is
   package Observation renames Flyology.Observability;
   package Groups renames Flyology.Execution_Groups;

   use type Interfaces.Unsigned_64;
   use type Observation.Event_Thread_State;
   use type Observation.Task_Instance_Id;
   use type Observation.Task_State;

   Reader_Socket : Flyology.IO.Sockets.Socket_Type;
   Writer_Socket : Flyology.IO.Sockets.Socket_Type;

   type Instance_Array is array (Positive range <>) of Observation.Task_Instance_Id;

   protected Control is
      procedure Started (Slot : Positive; Instance : Observation.Task_Instance_Id);
      procedure Finished;
      procedure Open;
      entry Wait_Until_Started;
      entry Wait_Until_Finished;
      entry Gate;
      function Instance (Slot : Positive) return Observation.Task_Instance_Id;
   private
      Started_Count  : Natural := 0;
      Finished_Count : Natural := 0;
      Is_Open        : Boolean := False;
      Instances      : Instance_Array (1 .. 3) := (others => Observation.No_Task_Instance);
   end Control;

   protected body Control is
      procedure Started (Slot : Positive; Instance : Observation.Task_Instance_Id) is
      begin
         if Slot not in Instances'Range
           or else Instance = Observation.No_Task_Instance
           or else Instances (Slot) /= Observation.No_Task_Instance
         then
            raise Program_Error with "current task instance identity is inconsistent";
         end if;
         Instances (Slot) := Instance;
         Started_Count := Started_Count + 1;
      end Started;

      procedure Finished is
      begin
         Finished_Count := Finished_Count + 1;
      end Finished;

      procedure Open is
      begin
         Is_Open := True;
      end Open;

      entry Wait_Until_Started when Started_Count = 3 is
      begin
         null;
      end Wait_Until_Started;

      entry Wait_Until_Finished when Finished_Count = 3 is
      begin
         null;
      end Wait_Until_Finished;

      entry Gate when Is_Open is
      begin
         null;
      end Gate;

      function Instance (Slot : Positive) return Observation.Task_Instance_Id
      is (Instances (Slot));
   end Control;

   Before_Release      : Observation.Group_Snapshot;
   After_Release       : Observation.Group_Snapshot;
   Task_Items          : Observation.Task_Snapshot_Array (1 .. 4) :=
     (others =>
        (Instance           => Observation.Task_Instance_Id (42),
         State              => Observation.Task_Ready,
         Base_Priority      => 0,
         Flags              => 0,
         Stack_Usable_Bytes => 0));
   Later_Task_Items    : Observation.Task_Snapshot_Array (1 .. 3);
   Small_Task_Items    : Observation.Task_Snapshot_Array (1 .. 2);
   Task_Count          : Natural;
   Later_Task_Count    : Natural;
   Small_Task_Count    : Natural;
   Task_Total          : Observation.Counter;
   Later_Task_Total    : Observation.Counter;
   Small_Task_Total    : Observation.Counter;
   Parked_Observed     : Boolean := False;
   Completion_Observed : Boolean := False;

   function Contains
     (Items : Observation.Task_Snapshot_Array; Count : Natural; Instance : Observation.Task_Instance_Id)
      return Boolean is
   begin
      for Index in Items'First .. Items'First + Count - 1 loop
         if Items (Index).Instance = Instance then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   function Parked (Sample : Observation.Group_Snapshot) return Boolean
   is (Sample.Thread_State = Observation.Running
       and then Sample.Members = 3
       and then Sample.Pinned_Members = 1
       and then Sample.Waiting = 3
       and then Sample.Ready = 0
       and then Sample.Running = 0
       and then Sample.Timer_Waits = 2
       and then Sample.Descriptor_Waits = 1
       and then Sample.Interrupt_Waits = 0
       and then Sample.File_Waits = 0
       and then Sample.Pending_File_Submissions = 0
       and then Sample.Dormancy_Candidates = 1
       and then Sample.Dormancy_Candidate_Bytes > 0
       and then Sample.Dispatches >= 3);

   function Completed (Sample : Observation.Group_Snapshot) return Boolean
   is (Sample.Members = 0
       and then Sample.Dispatches > Before_Release.Dispatches
       and then Sample.Poll_Batches > Before_Release.Poll_Batches
       and then Sample.Poll_Events > Before_Release.Poll_Events
       and then Sample.Wakeups > Before_Release.Wakeups
       and then Observation.Made_Progress (Before_Release, Sample));
begin
   Flyology.IO.Sockets.Create_Socket_Pair (Reader_Socket, Writer_Socket);

   declare
      task Timed
        with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Timed;

      task Descriptor
        with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Descriptor;

      task Rendezvous
        with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Rendezvous;

      Released : Boolean := False;

      procedure Release_All is
      begin
         if not Released then
            Released := True;
            Control.Open;
            Flyology.IO.Sockets.Send_All (Writer_Socket, [1 => 42], Timeout => 1.0);
         end if;
      end Release_All;

      task body Timed is
      begin
         if Flyology.Debug_Producer_Selection.Choose (4) /= 2 then
            raise Program_Error with "lightweight debug producer did not follow execution group";
         end if;
         Control.Started (1, Observation.Current_Task_Instance);
         delay 0.100;
         Control.Finished;
      end Timed;

      task body Descriptor is
      begin
         if Flyology.Debug_Producer_Selection.Choose (4) /= 2 then
            raise Program_Error with "lightweight debug producer did not follow execution group";
         end if;
         Control.Started (2, Observation.Current_Task_Instance);
         if not Flyology.IO.Wait
                  (Flyology.IO.Sockets.Native_Descriptor (Reader_Socket),
                   Flyology.IO.For_Read,
                   Timeout => 1.0)
         then
            raise Program_Error with "descriptor wait timed out";
         end if;
         Control.Finished;
      end Descriptor;

      task body Rendezvous is
      begin
         declare
            Pin : Groups.Thread_Pin := Groups.Pin_To_Current_Thread;
            pragma Unreferenced (Pin);
         begin
            if Flyology.Debug_Producer_Selection.Choose (4) /= 2 then
               raise Program_Error with "lightweight debug producer did not follow execution group";
            end if;
            Control.Started (3, Observation.Current_Task_Instance);
            Control.Gate;
            Control.Finished;
         end;
      end Rendezvous;
   begin
      begin
         select
            Control.Wait_Until_Started;
         or
            delay 2.0;
            raise Program_Error with "observation tasks did not start";
         end select;
         for Attempt in 1 .. 2_000 loop
            Parked_Observed := Observation.Snapshot (1, Before_Release) and then Parked (Before_Release);
            exit when Parked_Observed;
            delay 0.001;
         end loop;
         if not Parked_Observed then
            raise Program_Error with "parked group snapshot is inconsistent";
         end if;

         if not Observation.Snapshot_Tasks (1, Task_Items, Task_Count, Task_Total)
           or else Task_Count /= 3
           or else Task_Total /= 3
           or else Task_Items (4).Instance /= Observation.Task_Instance_Id (42)
         then
            raise Program_Error with "task snapshot count is inconsistent";
         end if;
         declare
            Pinned      : Natural := 0;
            Timer_Waits : Natural := 0;
            Descriptors : Natural := 0;
         begin
            for Index in 1 .. Task_Count loop
               if Task_Items (Index).Instance = Observation.No_Task_Instance
                 or else Task_Items (Index).State /= Observation.Task_Waiting
                 or else Task_Items (Index).Stack_Usable_Bytes = 0
                 or else Observation.Has_Flag (Task_Items (Index), Observation.Task_File_Wait_Flag)
                 or else Observation.Has_Flag (Task_Items (Index), Observation.Task_Destroy_Requested_Flag)
               then
                  raise Program_Error with "task snapshot entry is inconsistent";
               end if;
               if Observation.Has_Flag (Task_Items (Index), Observation.Task_Pinned_Flag) then
                  Pinned := Pinned + 1;
               end if;
               if Observation.Has_Flag (Task_Items (Index), Observation.Task_Timer_Wait_Flag) then
                  Timer_Waits := Timer_Waits + 1;
               end if;
               if Observation.Has_Flag (Task_Items (Index), Observation.Task_Descriptor_Wait_Flag) then
                  Descriptors := Descriptors + 1;
               end if;
            end loop;
            if Pinned /= 1 or else Timer_Waits /= 2 or else Descriptors /= 1 then
               raise Program_Error with "task snapshot flags are inconsistent";
            end if;
         end;
         if not Observation.Snapshot_Tasks (1, Later_Task_Items, Later_Task_Count, Later_Task_Total)
           or else Later_Task_Count /= 3
           or else Later_Task_Total /= 3
         then
            raise Program_Error with "repeated task snapshot failed";
         end if;
         for Index in 1 .. Task_Count loop
            if not Contains (Later_Task_Items, Later_Task_Count, Task_Items (Index).Instance) then
               raise Program_Error with "task instance identity changed between snapshots";
            end if;
         end loop;
         for Index in 1 .. 3 loop
            if not Contains (Task_Items, Task_Count, Control.Instance (Index)) then
               raise Program_Error with "self task identity was absent from group snapshot";
            end if;
         end loop;
         if not Observation.Snapshot_Tasks (1, Small_Task_Items, Small_Task_Count, Small_Task_Total)
           or else Small_Task_Count /= 2
           or else Small_Task_Total /= 3
         then
            raise Program_Error with "bounded task snapshot did not truncate";
         end if;

         Release_All;
         select
            Control.Wait_Until_Finished;
         or
            delay 2.0;
            raise Program_Error with "observation tasks did not finish";
         end select;
      exception
         when others =>
            --  A diagnostic failure must still open both task gates so the
            --  enclosing master can expose the original exception.
            begin
               Release_All;
            exception
               when others =>
                  null;
            end;
            raise;
      end;
   end;

   for Attempt in 1 .. 2_000 loop
      Completion_Observed := Observation.Snapshot (1, After_Release) and then Completed (After_Release);
      exit when Completion_Observed;
      delay 0.001;
   end loop;
   if not Completion_Observed then
      raise Program_Error with "cumulative observation counters did not move";
   end if;
   if not Observation.Snapshot_Tasks (1, Task_Items, Task_Count, Task_Total)
     or else Task_Count /= 0
     or else Task_Total /= 0
   then
      raise Program_Error with "empty task snapshot is inconsistent";
   end if;

   Flyology.IO.Sockets.Close_Socket (Reader_Socket);
   Flyology.IO.Sockets.Close_Socket (Writer_Socket);
end Observability_Smoke;
