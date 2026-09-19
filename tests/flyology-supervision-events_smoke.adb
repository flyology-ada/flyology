with Ada.Text_IO;
with Flyology.IO;

procedure Flyology.Supervision.Events_Smoke is
   Signal : Change_Signal;
   FD     : Flyology.IO.Descriptor;
begin
   --  A transition before the waiter arms remains observable.
   Signal.Notify;
   Signal.Arm (FD);
   if not Flyology.IO.Wait (FD, Flyology.IO.For_Read, Timeout => 0.0) then
      raise Program_Error with "pre-arm supervision transition was lost";
   end if;
   Signal.Consume;
   if Flyology.IO.Wait (FD, Flyology.IO.For_Read, Timeout => 0.03) then
      raise Program_Error
        with "idle supervision signal woke without a transition";
   end if;

   --  Lifecycle controllers record under their own protected lock. The
   --  outside caller writes the notification only after that action exits.
   declare
      protected Publisher is
         procedure Record_Change;
      end Publisher;

      protected body Publisher is
         procedure Record_Change is
         begin
            Signal.Mark_Pending;
         end Record_Change;
      end Publisher;
   begin
      Publisher.Record_Change;
      if Flyology.IO.Wait (FD, Flyology.IO.For_Read, Timeout => 0.0) then
         raise Program_Error
           with "protected supervision transition signaled before flush";
      end if;
      Signal.Flush;
      if not Flyology.IO.Wait (FD, Flyology.IO.For_Read, Timeout => 0.0) then
         raise Program_Error
           with "protected supervision transition lost its flush";
      end if;
      Signal.Consume;
   end;

   declare
      task Publisher;
      task body Publisher is
      begin
         delay 0.02;
         Signal.Notify;
         Signal.Notify;
      end Publisher;
   begin
      if not Flyology.IO.Wait (FD, Flyology.IO.For_Read, Timeout => 1.0) then
         raise Program_Error
           with "cross-task supervision transition did not wake";
      end if;
   end;

   Signal.Consume;
   if Flyology.IO.Wait (FD, Flyology.IO.For_Read, Timeout => 0.03) then
      raise Program_Error with "consumed supervision signal stayed readable";
   end if;
   Ada.Text_IO.Put_Line ("supervision events: PASS");
end Flyology.Supervision.Events_Smoke;
