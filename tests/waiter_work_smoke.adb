with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.IO.Scheduler_Testing;
with Flyology.IO.Sockets;
with Flyology.Observability;
with Interfaces;

procedure Waiter_Work_Smoke is
   package Sockets renames Flyology.IO.Sockets;
   package Testing renames Flyology.IO.Scheduler_Testing;

   use type Ada.Real_Time.Time;
   use type Flyology.Observability.Counter;
   use type Interfaces.Unsigned_64;

   Scale      : constant Positive :=
     (if Ada.Command_Line.Argument_Count = 0
      then 12
      else Positive'Value (Ada.Command_Line.Argument (1)));
   Wake_Index : constant Positive :=
     (if Ada.Command_Line.Argument_Count < 2
      then 1
      else Positive'Value (Ada.Command_Line.Argument (2)));

   Shared_Server : Sockets.Socket_Type;
   Shared_Peer   : Sockets.Socket_Type;
   Servers       : array (1 .. Scale) of Sockets.Socket_Type;
   Peers         : array (1 .. Scale) of Sockets.Socket_Type;

   protected Progress is
      procedure Finished (Outcome : Flyology.IO.Wait_Outcome);
      entry All_Finished;
      function Passed return Boolean;
   private
      Ready_Count       : Natural := 0;
      Interrupted_Count : Natural := 0;
      Failure_Count     : Natural := 0;
      Finished_Count    : Natural := 0;
   end Progress;

   protected body Progress is
      procedure Finished (Outcome : Flyology.IO.Wait_Outcome) is
      begin
         case Outcome is
            when Flyology.IO.Ready       =>
               Ready_Count := Ready_Count + 1;

            when Flyology.IO.Interrupted =>
               Interrupted_Count := Interrupted_Count + 1;

            when Flyology.IO.Timed_Out   =>
               Failure_Count := Failure_Count + 1;
         end case;
         Finished_Count := Finished_Count + 1;
      end Finished;

      entry All_Finished when Finished_Count = Scale is
      begin
         null;
      end All_Finished;

      function Passed return Boolean
      is (Ready_Count = 1
          and then Interrupted_Count = Scale - 1
          and then Failure_Count = 0);
   end Progress;

   task type Waiter (Index : Positive) is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Waiter;

   task body Waiter is
      Interrupts : Flyology.IO.Interrupt_Set (1 .. 1);
      Outcome    : Flyology.IO.Wait_Outcome := Flyology.IO.Timed_Out;
   begin
      Interrupts (1) := Sockets.Native_Descriptor (Shared_Server);
      Outcome :=
        Flyology.IO.Wait_Interruptibly
          (Sockets.Native_Descriptor (Servers (Index)),
           Flyology.IO.For_Read,
           10.0,
           Interrupts);
      Progress.Finished (Outcome);
   exception
      when others =>
         Progress.Finished (Flyology.IO.Timed_Out);
   end Waiter;

   type Waiter_Access is access Waiter;
   Workers : array (1 .. Scale) of Waiter_Access := (others => null);

   procedure Await_Descriptor_Waits (Expected : Natural) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      Sample   : Flyology.Observability.Group_Snapshot;
   begin
      loop
         if Flyology.Observability.Snapshot (0, Sample) then
            exit when
              Sample.Descriptor_Waits
              = Flyology.Observability.Counter (Expected);
         end if;
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "descriptor wait count did not converge";
         end if;
         delay 0.001;
      end loop;
   end Await_Descriptor_Waits;

   procedure Report (Label : String; Work : Testing.Waiter_Work_Snapshot) is
   begin
      Ada.Text_IO.Put_Line
        (Label
         & " unlink="
         & Interfaces.Unsigned_64'Image (Work.Unlink_Scans)
         & " retention="
         & Interfaces.Unsigned_64'Image (Work.Retention_Scans)
         & " delivery="
         & Interfaces.Unsigned_64'Image (Work.Delivery_Scans));
   end Report;

   Private_Wake_Work : Testing.Waiter_Work_Snapshot;
   Shared_Wake_Work  : Testing.Waiter_Work_Snapshot;
begin
   pragma Assert (Wake_Index <= Scale);
   Sockets.Create_Socket_Pair (Shared_Server, Shared_Peer);
   for Index in Workers'Range loop
      Sockets.Create_Socket_Pair (Servers (Index), Peers (Index));
      Workers (Index) := new Waiter (Index);
      Await_Descriptor_Waits (Index);
   end loop;

   --  Each newer waiter prepends a same-direction link on the shared source.
   --  Waking the oldest private source detaches its tail shared-source link.
   Testing.Reset_Waiter_Work;
   Sockets.Send_All (Peers (Wake_Index), [1 => 1], Timeout => 1.0);
   Await_Descriptor_Waits (Scale - 1);
   Private_Wake_Work := Testing.Waiter_Work;
   Report ("private wake", Private_Wake_Work);

   Testing.Reset_Waiter_Work;
   Sockets.Send_All (Shared_Peer, [1 => 2], Timeout => 1.0);
   Progress.All_Finished;
   Await_Descriptor_Waits (0);
   Shared_Wake_Work := Testing.Waiter_Work;
   Report ("shared wake", Shared_Wake_Work);

   pragma Assert (Private_Wake_Work.Unlink_Scans = 0);
   pragma
     Assert (Private_Wake_Work.Retention_Scans = (if Scale = 1 then 0 else 1));
   pragma Assert (Private_Wake_Work.Delivery_Scans = 1);
   pragma Assert (Shared_Wake_Work.Unlink_Scans = 0);
   pragma Assert (Shared_Wake_Work.Retention_Scans = 0);
   pragma
     Assert
       (Shared_Wake_Work.Delivery_Scans = Interfaces.Unsigned_64 (Scale - 1));
   pragma Assert (Progress.Passed);

   for Index in Workers'Range loop
      Sockets.Close_Socket (Servers (Index));
      Sockets.Close_Socket (Peers (Index));
   end loop;
   Sockets.Close_Socket (Shared_Server);
   Sockets.Close_Socket (Shared_Peer);
end Waiter_Work_Smoke;
