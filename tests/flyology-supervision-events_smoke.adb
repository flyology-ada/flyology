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
