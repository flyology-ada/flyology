with Ada.Real_Time;
with Ada.Streams;
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
   use type Flyology.IO.Wait_Outcome;
   use type Flyology.Observability.Counter;
   use type Sockets.Error_Type;

   Scale : constant Positive := 12;

   Shared_Server : Sockets.Socket_Type;
   Shared_Peer   : Sockets.Socket_Type;
   Target_Wake   : Sockets.Socket_Type;
   Target_Peer   : Sockets.Socket_Type;

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

      entry All_Finished when Finished_Count = Scale + 1 is
      begin
         null;
      end All_Finished;

      function Passed return Boolean
      is (Ready_Count = Scale and then Interrupted_Count = 1 and then Failure_Count = 0);
   end Progress;

   task type Target_Waiter is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Target_Waiter;

   task body Target_Waiter is
      Interrupts : Flyology.IO.Interrupt_Set (1 .. 1);
      Outcome    : Flyology.IO.Wait_Outcome := Flyology.IO.Timed_Out;
   begin
      Interrupts (1) := Sockets.Native_Descriptor (Target_Wake);
      Outcome :=
        Flyology.IO.Wait_Interruptibly
          (Sockets.Native_Descriptor (Shared_Server), Flyology.IO.For_Write, 10.0, Interrupts);
      Progress.Finished (Outcome);
   exception
      when others =>
         Progress.Finished (Flyology.IO.Timed_Out);
   end Target_Waiter;

   task type Blocker_Waiter is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Blocker_Waiter;

   task body Blocker_Waiter is
      Outcome : Flyology.IO.Wait_Outcome := Flyology.IO.Timed_Out;
   begin
      if Flyology.IO.Wait
           (Sockets.Native_Descriptor (Shared_Server), Flyology.IO.For_Read, Timeout => 10.0)
      then
         Outcome := Flyology.IO.Ready;
      end if;
      Progress.Finished (Outcome);
   exception
      when others =>
         Progress.Finished (Flyology.IO.Timed_Out);
   end Blocker_Waiter;

   type Target_Waiter_Access is access Target_Waiter;
   type Blocker_Waiter_Access is access Blocker_Waiter;

   Target   : Target_Waiter_Access := null;
   Blockers : array (1 .. Scale) of Blocker_Waiter_Access := (others => null);

   procedure Await_Descriptor_Waits (Expected : Natural) is
      Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      Sample   : Flyology.Observability.Group_Snapshot;
   begin
      loop
         if Flyology.Observability.Snapshot (0, Sample) then
            exit when Sample.Descriptor_Waits = Flyology.Observability.Counter (Expected);
         end if;
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "descriptor wait count did not converge";
         end if;
         delay 0.001;
      end loop;
   end Await_Descriptor_Waits;

   procedure Fill_Send_Buffer is
      Data        : constant Ada.Streams.Stream_Element_Array (1 .. 4_096) := (others => 1);
      Last        : Ada.Streams.Stream_Element_Offset;
      Nonblocking : Sockets.Request_Type (Sockets.Non_Blocking_IO) :=
        (Name => Sockets.Non_Blocking_IO, Enabled => True);
   begin
      Sockets.Control_Socket (Shared_Server, Nonblocking);
      loop
         begin
            Sockets.Send_Socket (Shared_Server, Data, Last);
         exception
            when Occurrence : Sockets.Socket_Error =>
               if Sockets.Resolve_Exception (Occurrence) =
                 Sockets.Resource_Temporarily_Unavailable
               then
                  exit;
               end if;
               raise;
         end;
      end loop;
   end Fill_Send_Buffer;

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

   Target_Wake_Work : Testing.Waiter_Work_Snapshot;
   Shared_Wake_Work : Testing.Waiter_Work_Snapshot;
begin
   Sockets.Create_Socket_Pair (Shared_Server, Shared_Peer);
   Sockets.Create_Socket_Pair (Target_Wake, Target_Peer);
   Fill_Send_Buffer;

   Target := new Target_Waiter;
   Await_Descriptor_Waits (1);

   --  Read waiters on the same descriptor prepend ahead of the older write
   --  waiter while the descriptor remains neither readable nor writable.
   for Index in Blockers'Range loop
      Blockers (Index) := new Blocker_Waiter;
      Await_Descriptor_Waits (Index + 1);
   end loop;

   Testing.Reset_Waiter_Work;
   Sockets.Send_All (Target_Peer, [1 => 1], Timeout => 1.0);
   Await_Descriptor_Waits (Scale);
   Target_Wake_Work := Testing.Waiter_Work;
   Report ("target wake", Target_Wake_Work);

   pragma Assert (Target_Wake_Work.Unlink_Scans = Interfaces.Unsigned_64 (Scale));
   pragma Assert (Target_Wake_Work.Retention_Scans = Interfaces.Unsigned_64 (Scale));
   pragma Assert (Target_Wake_Work.Delivery_Scans = 1);

   Testing.Reset_Waiter_Work;
   Sockets.Send_All (Shared_Peer, [1 => 2], Timeout => 1.0);
   Progress.All_Finished;
   Await_Descriptor_Waits (0);
   Shared_Wake_Work := Testing.Waiter_Work;
   Report ("shared wake", Shared_Wake_Work);

   pragma Assert (Shared_Wake_Work.Unlink_Scans = 0);
   pragma Assert (Shared_Wake_Work.Retention_Scans = 0);
   pragma Assert (Shared_Wake_Work.Delivery_Scans = Interfaces.Unsigned_64 (Scale));
   pragma Assert (Progress.Passed);

   Sockets.Close_Socket (Shared_Server);
   Sockets.Close_Socket (Shared_Peer);
   Sockets.Close_Socket (Target_Wake);
   Sockets.Close_Socket (Target_Peer);
end Waiter_Work_Smoke;
