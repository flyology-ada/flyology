with Ada.Streams;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;
with System.Flyology.Scheduling_Policy;

procedure Deadline_Clamp_Smoke is
   package Scheduling renames System.Flyology.Scheduling_Policy;

   use type Ada.Streams.Stream_Element_Array;
   use type Scheduling.Deadline_Status;

   protected Result is
      procedure Set (Value : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Result;

   protected body Result is
      procedure Set (Value : Boolean) is
      begin
         OK := Value;
         Done := True;
      end Set;

      entry Wait when Done is
      begin
         null;
      end Wait;

      function Passed return Boolean
      is (OK);
   end Result;

   Left, Right : Flyology.IO.Sockets.Socket_Type;
begin
   pragma
     Assert (Scheduling.Deadline_After (1.0, Duration'Last) = Duration'Last);
   pragma
     Assert
       (Scheduling.Classify_Deadline
          (Scheduling.Deadline_After (1.0, Duration'Last), 1.0)
          = Scheduling.Pending);

   Flyology.IO.Sockets.Create_Socket_Pair (Left, Right);
   declare
      Payload : constant Ada.Streams.Stream_Element_Array := [1 => 145];

      task Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Waiter;

      task Sender is
         pragma Task_Info (Flyology.Native_Task);
      end Sender;

      task body Waiter is
         Incoming : Ada.Streams.Stream_Element_Array (Payload'Range);
      begin
         if Flyology.IO.Wait
              (Flyology.IO.Sockets.Native_Descriptor (Left),
               Flyology.IO.For_Read,
               Timeout => Duration'Last)
         then
            Flyology.IO.Sockets.Receive_Exactly
              (Left, Incoming, Timeout => 1.0);
            Result.Set (Incoming = Payload);
         else
            Result.Set (False);
         end if;
      exception
         when others =>
            Result.Set (False);
      end Waiter;

      task body Sender is
      begin
         Flyology.IO.Timers.Sleep_For (0.020);
         Flyology.IO.Sockets.Send_All (Right, Payload, Timeout => 1.0);
      end Sender;
   begin
      select
         Result.Wait;
      or
         delay 2.0;
         raise Program_Error
           with "saturated lightweight wait did not resume on readiness";
      end select;
      pragma Assert (Result.Passed);
   end;
   Flyology.IO.Sockets.Close_Socket (Left);
   Flyology.IO.Sockets.Close_Socket (Right);
end Deadline_Clamp_Smoke;
