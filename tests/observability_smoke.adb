with GNAT.Sockets;
with Flyology;
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

   Reader_Socket : GNAT.Sockets.Socket_Type;
   Writer_Socket : GNAT.Sockets.Socket_Type;

   protected Control is
      procedure Started;
      procedure Finished;
      procedure Open;
      entry Wait_Until_Started;
      entry Wait_Until_Finished;
      entry Gate;
   private
      Started_Count  : Natural := 0;
      Finished_Count : Natural := 0;
      Is_Open        : Boolean := False;
   end Control;

   protected body Control is
      procedure Started is
      begin
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
   end Control;

   Before_Release : Observation.Group_Snapshot;
   After_Release  : Observation.Group_Snapshot;
begin
   GNAT.Sockets.Create_Socket_Pair (Reader_Socket, Writer_Socket);

   declare
      task Timed is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Timed;

      task Descriptor is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Descriptor;

      task Rendezvous is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Rendezvous;

      task body Timed is
      begin
         Control.Started;
         delay 0.100;
         Control.Finished;
      end Timed;

      task body Descriptor is
      begin
         Control.Started;
         if not Flyology.IO.Wait
           (Flyology.IO.Descriptor (GNAT.Sockets.To_C (Reader_Socket)),
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
            Control.Started;
            Control.Gate;
            Control.Finished;
         end;
      end Rendezvous;
   begin
      Control.Wait_Until_Started;
      delay 0.020;
      if not Observation.Snapshot (0, Before_Release) then
         raise Program_Error with "event group was not observable";
      end if;
      if Before_Release.Thread_State /= Observation.Running
        or else Before_Release.Members /= 3
        or else Before_Release.Pinned_Members /= 1
        or else Before_Release.Waiting /= 3
        or else Before_Release.Ready /= 0
        or else Before_Release.Running /= 0
        or else Before_Release.Timer_Waits /= 2
        or else Before_Release.Descriptor_Waits /= 1
        or else Before_Release.Interrupt_Waits /= 0
        or else Before_Release.File_Waits /= 0
        or else Before_Release.Pending_File_Submissions /= 0
        or else Before_Release.Dispatches < 3
      then
         raise Program_Error with "parked group snapshot is inconsistent";
      end if;

      Control.Open;
      Flyology.IO.Sockets.Send_All
        (Writer_Socket, [1 => 42], Timeout => 1.0);
      Control.Wait_Until_Finished;
   end;

   delay 0.010;
   if not Observation.Snapshot (0, After_Release) then
      raise Program_Error with "completed event group disappeared";
   end if;
   if After_Release.Members /= 0
     or else After_Release.Dispatches <= Before_Release.Dispatches
     or else After_Release.Poll_Batches <= Before_Release.Poll_Batches
     or else After_Release.Poll_Events <= Before_Release.Poll_Events
     or else After_Release.Wakeups <= Before_Release.Wakeups
     or else not Observation.Made_Progress (Before_Release, After_Release)
   then
      raise Program_Error with "cumulative observation counters did not move";
   end if;

   GNAT.Sockets.Close_Socket (Reader_Socket);
   GNAT.Sockets.Close_Socket (Writer_Socket);
end Observability_Smoke;
