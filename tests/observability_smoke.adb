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

   Reader_Socket : Flyology.IO.Sockets.Socket_Type;
   Writer_Socket : Flyology.IO.Sockets.Socket_Type;

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
   Parked_Observed : Boolean := False;
   Completion_Observed : Boolean := False;

   function Parked (Sample : Observation.Group_Snapshot) return Boolean is
     (Sample.Thread_State = Observation.Running
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
      and then Sample.Dispatches >= 3);

   function Completed (Sample : Observation.Group_Snapshot) return Boolean is
     (Sample.Members = 0
      and then Sample.Dispatches > Before_Release.Dispatches
      and then Sample.Poll_Batches > Before_Release.Poll_Batches
      and then Sample.Poll_Events > Before_Release.Poll_Events
      and then Sample.Wakeups > Before_Release.Wakeups
      and then Observation.Made_Progress (Before_Release, Sample));
begin
   Flyology.IO.Sockets.Create_Socket_Pair
     (Reader_Socket, Writer_Socket);

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

      Released : Boolean := False;

      procedure Release_All is
      begin
         if not Released then
            Released := True;
            Control.Open;
            Flyology.IO.Sockets.Send_All
              (Writer_Socket, [1 => 42], Timeout => 1.0);
         end if;
      end Release_All;

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
            Control.Started;
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
            Parked_Observed := Observation.Snapshot (0, Before_Release)
              and then Parked (Before_Release);
            exit when Parked_Observed;
            delay 0.001;
         end loop;
         if not Parked_Observed then
            raise Program_Error with "parked group snapshot is inconsistent";
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
      Completion_Observed := Observation.Snapshot (0, After_Release)
        and then Completed (After_Release);
      exit when Completion_Observed;
      delay 0.001;
   end loop;
   if not Completion_Observed then
      raise Program_Error with "cumulative observation counters did not move";
   end if;

   Flyology.IO.Sockets.Close_Socket (Reader_Socket);
   Flyology.IO.Sockets.Close_Socket (Writer_Socket);
end Observability_Smoke;
