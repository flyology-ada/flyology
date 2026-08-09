with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Timers;

procedure Timer_Set_Smoke is
   package RT renames Ada.Real_Time;
   package Timers renames Flyology.IO.Timers;

   use type RT.Time;
   use type Timers.Timer_Wait_Outcome;

   protected Results is
      procedure Finish (Passed : Boolean);
      entry Await;
      function Passed return Boolean;
   private
      Completed : Natural := 0;
      All_OK    : Boolean := True;
   end Results;

   protected body Results is
      procedure Finish (Passed : Boolean) is
      begin
         Completed := Completed + 1;
         All_OK := All_OK and Passed;
      end Finish;

      entry Await when Completed = 2 is
      begin
         null;
      end Await;

      function Passed return Boolean is (All_OK);
   end Results;

   procedure Exercise is
      Small       : Timers.Timer_Set (6);
      Small_Batch : Timers.Activation_Batch (6);
      Outcome     : Timers.Timer_Wait_Outcome;
      Shared      : RT.Time;
   begin
      --  A timer activated while the caller is doing other work must be
      --  classified before Wait_Next sleeps for a later deadline.
      Timers.Arm (Small, 1, RT.Clock + RT.Milliseconds (10));
      Timers.Wait_Next (Small, Small_Batch);
      if Small_Batch.Count /= 1 or else Small_Batch.Ids (1) /= 1 then
         raise Program_Error with "initial timer activation was not isolated";
      end if;

      Shared := RT.Clock + RT.Milliseconds (20);
      Timers.Arm (Small, 2, Shared);
      Timers.Arm (Small, 3, Shared);
      Timers.Arm (Small, 4, RT.Time_Last);
      Timers.Sleep_For (0.060);
      Timers.Wait_Next (Small, Small_Batch);
      if Small_Batch.Count /= 2
        or else
          not ((Small_Batch.Ids (1) = 2 and Small_Batch.Ids (2) = 3)
               or else
                 (Small_Batch.Ids (1) = 3 and Small_Batch.Ids (2) = 2))
        or else Timers.Is_Armed (Small, 2)
        or else Timers.Is_Armed (Small, 3)
        or else not Timers.Is_Armed (Small, 4)
      then
         raise Program_Error with
           "processing-time timer activations were lost or repeated";
      end if;

      --  Arm replaces an existing deadline and Cancel is idempotent.
      Timers.Arm (Small, 5, RT.Clock + RT.Seconds (10));
      Timers.Arm (Small, 5, RT.Clock - RT.Milliseconds (1));
      Timers.Cancel (Small, 4);
      Timers.Cancel (Small, 4);
      Timers.Wait_Next (Small, Small_Batch);
      if Small_Batch.Count /= 1
        or else Small_Batch.Ids (1) /= 5
        or else Timers.Armed_Count (Small) /= 0
      then
         raise Program_Error with "reschedule or cancellation state failed";
      end if;

      --  A bounded wait leaves later timers armed, while a due timer wins over
      --  a simultaneous zero-time poll and is still delivered exactly once.
      Timers.Arm (Small, 6, RT.Time_Last);
      Timers.Wait_Next
        (Small, Small_Batch, Timeout => 0.010, Outcome => Outcome);
      if Outcome /= Timers.Wait_Timed_Out or else Small_Batch.Count /= 0
        or else not Timers.Is_Armed (Small, 6)
      then
         raise Program_Error with "bounded timer wait did not time out cleanly";
      end if;
      Timers.Arm (Small, 6, RT.Clock - RT.Milliseconds (1));
      Timers.Wait_Next
        (Small, Small_Batch, Timeout => 0.0, Outcome => Outcome);
      if Outcome /= Timers.Timers_Activated or else Small_Batch.Count /= 1
        or else Small_Batch.Ids (1) /= 6
        or else Timers.Is_Armed (Small, 6)
      then
         raise Program_Error with "zero-time poll omitted a due timer";
      end if;

      --  Replace maps the array indexes to timer ids and discards old arms.
      declare
         Deadlines : Timers.Deadline_Array (1 .. 6);
         Started   : constant RT.Time := RT.Clock;
      begin
         for Id in Deadlines'Range loop
            Deadlines (Id) :=
              Started + RT.Milliseconds ((Id * 7) mod 13 + 1);
         end loop;
         Timers.Replace (Small, Deadlines);
         Timers.Sleep_Until (Started + RT.Milliseconds (20));
         Timers.Wait_Next (Small, Small_Batch);
         if Small_Batch.Count /= Deadlines'Length
           or else Timers.Armed_Count (Small) /= 0
         then
            raise Program_Error with "replacement batch omitted a timer";
         end if;
      end;

      --  Exercise the bounded heap at the same scale as the runtime timer
      --  heap smoke test. Every arm must occur exactly once in the batch.
      declare
         Capacity  : constant := 512;
         Many      : Timers.Timer_Set (Capacity);
         Batch     : Timers.Activation_Batch (Capacity);
         Deadlines : Timers.Deadline_Array (1 .. Capacity);
         Seen      : array (1 .. Capacity) of Boolean := (others => False);
         Started   : constant RT.Time := RT.Clock;
      begin
         for Id in Deadlines'Range loop
            Deadlines (Id) :=
              Started + RT.Milliseconds ((Id * 17) mod 31 + 1);
         end loop;
         Timers.Replace (Many, Deadlines);
         --  Re-arming an existing id remains valid when every slot is full.
         Timers.Arm (Many, Capacity, Deadlines (Capacity));
         Timers.Sleep_Until (Started + RT.Milliseconds (40));
         Timers.Wait_Next (Many, Batch);
         if Batch.Count /= Capacity or else Timers.Armed_Count (Many) /= 0 then
            raise Program_Error with "large activation batch omitted a timer";
         end if;

         for Position in 1 .. Batch.Count loop
            if Seen (Batch.Ids (Position)) then
               raise Program_Error with "large activation batch repeated an id";
            end if;
            Seen (Batch.Ids (Position)) := True;
         end loop;

         for Id in Seen'Range loop
            if not Seen (Id) then
               raise Program_Error with "large activation batch lost an id";
            end if;
         end loop;
      end;
   end Exercise;

   task type Worker (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Worker;

   task body Worker is
   begin
      Exercise;
      Results.Finish (True);
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "timer set " & Flyology.Execution_Model'Image (Model)
            & " failed: " & Ada.Exceptions.Exception_Information (Error));
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         Results.Finish (False);
   end Worker;

   Lightweight : Worker (Flyology.Lightweight_Task);
   Native      : Worker (Flyology.Native_Task);
begin
   Results.Await;
   if not Results.Passed then
      raise Program_Error with "timer set behavior failed in one task lane";
   end if;
end Timer_Set_Smoke;
