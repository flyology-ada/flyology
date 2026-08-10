with Ada.Streams;
with Ada.Real_Time;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;

procedure Wait_Any_Smoke is
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   use type Flyology.IO.Wait_Outcome;

   protected Result is
      procedure Set (Passed : Boolean);
      entry Wait (Passed : out Boolean);
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Result;

   protected body Result is
      procedure Set (Passed : Boolean) is
      begin
         OK := Passed;
         Done := True;
      end Set;

      entry Wait (Passed : out Boolean) when Done is
      begin
         Passed := OK;
         Done := False;
      end Wait;
   end Result;

   task type Runner (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Runner;

   task body Runner is
      Left_1, Right_1 : Flyology.IO.Sockets.Socket_Type;
      Left_2, Right_2 : Flyology.IO.Sockets.Socket_Type;
      Data : constant Ada.Streams.Stream_Element_Array := [1 => 42];
      Last : Ada.Streams.Stream_Element_Offset;
      Passed : Boolean := False;
   begin
      Flyology.IO.Sockets.Create_Socket_Pair (Left_1, Right_1);
      Flyology.IO.Sockets.Create_Socket_Pair (Left_2, Right_2);
      Flyology.IO.Sockets.Prepare (Left_1);
      Flyology.IO.Sockets.Prepare (Left_2);
      Flyology.IO.Sockets.Send_Socket (Right_2, Data, Last);
      pragma Assert (Last = Data'Last);

      declare
         Requests : constant Flyology.IO.Wait_Request_Array (7 .. 8) :=
           [7 => (Flyology.IO.Sockets.Native_Descriptor (Left_1),
                  Flyology.IO.For_Read),
            8 => (Flyology.IO.Sockets.Native_Descriptor (Left_2),
                  Flyology.IO.For_Read)];
      begin
         Passed := Flyology.IO.Wait_Any (Requests, 1.0) = 8;
      end;

      --  Interrupt sets are not tied to the three ownership sources used by
      --  structured connections. Raw callers can compose any bounded number
      --  of wake descriptors, and caller index bounds need not start at one.
      declare
         Interrupts : constant Flyology.IO.Interrupt_Set (5 .. 8) :=
           [others => Flyology.IO.Sockets.Native_Descriptor (Left_2)];
      begin
         Passed := Passed and then Flyology.IO.Wait_Interruptibly
           (Flyology.IO.Sockets.Native_Descriptor (Left_1),
            Flyology.IO.For_Read,
            1.0,
            Interrupts) = Flyology.IO.Interrupted;
      end;

      --  Right_2 became ready first, but both distinct descriptors are ready
      --  before this event-loop maintenance pass. Lowest caller index wins,
      --  independent of kernel event ordering.
      Flyology.IO.Sockets.Send_Socket (Right_1, Data, Last);
      declare
         Requests : constant Flyology.IO.Wait_Request_Array (7 .. 8) :=
           [7 => (Flyology.IO.Sockets.Native_Descriptor (Left_1),
                  Flyology.IO.For_Read),
            8 => (Flyology.IO.Sockets.Native_Descriptor (Left_2),
                  Flyology.IO.For_Read)];
         Got : constant Natural := Flyology.IO.Wait_Any (Requests, 1.0);
         Drained : Ada.Streams.Stream_Element_Array (1 .. 1);
      begin
         Passed := Passed and then Got = 7;
         Flyology.IO.Sockets.Receive_Socket (Left_1, Drained, Last);
      end;

      declare
         Requests : constant Flyology.IO.Wait_Request_Array (4 .. 5) :=
           [others =>
              (Flyology.IO.Sockets.Native_Descriptor (Left_2),
               Flyology.IO.For_Read)];
      begin
         Passed := Passed and then Flyology.IO.Wait_Any (Requests, 0.0) = 4;
      end;

      declare
         Requests : Flyology.IO.Wait_Request_Array
           (1 .. Flyology.IO.Max_Wait_Requests);
      begin
         Requests :=
           [others =>
              (Flyology.IO.Sockets.Native_Descriptor (Left_2),
               Flyology.IO.For_Read)];
         Passed := Passed and then Flyology.IO.Wait_Any (Requests, 0.0) = 1;
      end;

      declare
         Empty : Flyology.IO.Wait_Request_Array (2 .. 1);
      begin
         Passed := Passed and then Flyology.IO.Wait_Any (Empty, 0.0) = 0;
      end;

      declare
         Requests : constant Flyology.IO.Wait_Request_Array :=
           [1 => (Flyology.IO.Invalid_Descriptor, Flyology.IO.For_Read),
            2 => (Flyology.IO.Sockets.Native_Descriptor (Left_1),
                  Flyology.IO.For_Write)];
         Rejected : Boolean := False;
      begin
         begin
            declare
               Ignored : constant Natural := Flyology.IO.Wait_Any (Requests);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Flyology.IO.Device_Error => Rejected := True;
         end;
         Passed := Passed and Rejected;
      end;

      --  A closed, nonnegative descriptor reaches poll/kqueue/epoll rather
      --  than the public negative-descriptor guard.  Placing a valid request
      --  second makes the lightweight reverse-registration path arm it before the
      --  closed descriptor fails, exercising transactional rollback.
      declare
         Closed_Left, Closed_Right : Flyology.IO.Sockets.Socket_Type;
      begin
         Flyology.IO.Sockets.Create_Socket_Pair
           (Closed_Left, Closed_Right);
         declare
            Closed_FD : constant Flyology.IO.Descriptor :=
              Flyology.IO.Sockets.Native_Descriptor (Closed_Left);
            Requests : constant Flyology.IO.Wait_Request_Array :=
              [1 => (Closed_FD, Flyology.IO.For_Read),
               2 => (Flyology.IO.Sockets.Native_Descriptor (Left_1),
                     Flyology.IO.For_Write)];
            Rejected : Boolean := False;
         begin
            Flyology.IO.Sockets.Close_Socket (Closed_Left);
            begin
               declare
                  Ignored : constant Natural :=
                    Flyology.IO.Wait_Any (Requests, 0.1);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when Flyology.IO.Device_Error => Rejected := True;
            end;
            Passed := Passed and Rejected;
         end;
         Flyology.IO.Sockets.Close_Socket (Closed_Right);
      end;

      declare
         Requests : constant Flyology.IO.Wait_Request_Array (1 .. 2) :=
           [1 => (Flyology.IO.Sockets.Native_Descriptor (Left_1),
                  Flyology.IO.For_Read),
            2 => (Flyology.IO.Sockets.Native_Descriptor (Left_1),
                  Flyology.IO.For_Write)];
      begin
         Passed := Passed and then Flyology.IO.Wait_Any (Requests, 1.0) = 2;
      end;

      declare
         Request : constant Flyology.IO.Wait_Request_Array :=
           [1 => (Flyology.IO.Sockets.Native_Descriptor (Left_1),
                  Flyology.IO.For_Read)];
      begin
         Passed := Passed and then Flyology.IO.Wait_Any (Request, 0.01) = 0;
      end;

      Flyology.IO.Sockets.Close_Socket (Left_1);
      Flyology.IO.Sockets.Close_Socket (Right_1);
      Flyology.IO.Sockets.Close_Socket (Left_2);
      Flyology.IO.Sockets.Close_Socket (Right_2);

      --  A timed-out wait must leave no registration that can act on a later
      --  descriptor generation reusing the same integer.
      Flyology.IO.Sockets.Create_Socket_Pair (Left_1, Right_1);
      Flyology.IO.Sockets.Prepare (Left_1);
      declare
         Request : constant Flyology.IO.Wait_Request_Array :=
           [1 => (Flyology.IO.Sockets.Native_Descriptor (Left_1),
                  Flyology.IO.For_Read)];
      begin
         Passed := Passed and then Flyology.IO.Wait_Any (Request, 0.005) = 0;
      end;
      Flyology.IO.Sockets.Close_Socket (Left_1);
      Flyology.IO.Sockets.Close_Socket (Right_1);
      Flyology.IO.Sockets.Create_Socket_Pair (Left_1, Right_1);
      Flyology.IO.Sockets.Prepare (Left_1);
      Flyology.IO.Sockets.Send_Socket (Right_1, Data, Last);
      declare
         Request : constant Flyology.IO.Wait_Request_Array :=
           [1 => (Flyology.IO.Sockets.Native_Descriptor (Left_1),
                  Flyology.IO.For_Read)];
      begin
         Passed := Passed and then Flyology.IO.Wait_Any (Request, 0.1) = 1;
      end;
      Flyology.IO.Sockets.Close_Socket (Left_1);
      Flyology.IO.Sockets.Close_Socket (Right_1);
      Result.Set (Passed);
   exception
      when others =>
         Result.Set (False);
   end Runner;

   type Runner_Access is access Runner;
   Native  : Runner_Access;
   Lightweight : Runner_Access;
   pragma Unreferenced (Native, Lightweight);
   Passed  : Boolean;
begin
   Native := new Runner (Flyology.Native_Task);
   Result.Wait (Passed);
   pragma Assert (Passed);
   Lightweight := new Runner (Flyology.Lightweight_Task);
   Result.Wait (Passed);
   pragma Assert (Passed);

   --  Exercise a distinct-descriptor change list rather than the duplicate
   --  entries above. A timeout must clear every source, the same set must
   --  rearm immediately, and simultaneous readiness must retain the required
   --  lowest-index ordering in both lanes.
   declare
      task type Batch_Runner (Model : Flyology.Execution_Model) is
         pragma Task_Info (Model);
      end Batch_Runner;

      task body Batch_Runner is
         type Socket_Array is array
           (Positive range <>) of Flyology.IO.Sockets.Socket_Type;
         Left  : Socket_Array (1 .. 8);
         Right : Socket_Array (Left'Range);
         Requests : Flyology.IO.Wait_Request_Array (Left'Range);
         Data : constant Ada.Streams.Stream_Element_Array := [1 => 17];
         Buffer : Ada.Streams.Stream_Element_Array (Data'Range);
         Last : Ada.Streams.Stream_Element_Offset;
         OK : Boolean := False;
      begin
         for Index in Left'Range loop
            Flyology.IO.Sockets.Create_Socket_Pair
              (Left (Index), Right (Index));
            Flyology.IO.Sockets.Prepare (Left (Index));
            Requests (Index) :=
              (Flyology.IO.Sockets.Native_Descriptor (Left (Index)),
               Flyology.IO.For_Read);
         end loop;

         OK := Flyology.IO.Wait_Any (Requests, 0.005) = 0;
         Flyology.IO.Sockets.Send_Socket (Right (8), Data, Last);
         OK := OK and then Last = Data'Last
           and then Flyology.IO.Wait_Any (Requests, 1.0) = 8;
         Flyology.IO.Sockets.Receive_Socket (Left (8), Buffer, Last);

         Flyology.IO.Sockets.Send_Socket (Right (6), Data, Last);
         Flyology.IO.Sockets.Send_Socket (Right (2), Data, Last);
         OK := OK and then Flyology.IO.Wait_Any (Requests, 1.0) = 2;

         for Index in Left'Range loop
            Flyology.IO.Sockets.Close_Socket (Left (Index));
            Flyology.IO.Sockets.Close_Socket (Right (Index));
         end loop;
         Result.Set (OK);
      exception
         when others => Result.Set (False);
      end Batch_Runner;

   begin
      declare
         Native_Batch : Batch_Runner (Flyology.Native_Task);
         pragma Unreferenced (Native_Batch);
      begin
         Result.Wait (Passed);
         pragma Assert (Passed);
      end;
      declare
         Lightweight_Batch : Batch_Runner (Flyology.Lightweight_Task);
         pragma Unreferenced (Lightweight_Batch);
      begin
         Result.Wait (Passed);
         pragma Assert (Passed);
      end;
   end;

   --  Aborting a lightweight task while Wait_Any is suspended must unregister
   --  every kernel interest before its stack-resident wait links disappear.
   --  A second lightweight waiter on the same descriptor checks that the poller
   --  and group registry remain usable after that unwind.
   declare
      protected Started is
         procedure Set;
         entry Wait;
      private
         Is_Set : Boolean := False;
      end Started;

      protected body Started is
         procedure Set is
         begin
            Is_Set := True;
         end Set;

         entry Wait when Is_Set is
         begin
            null;
         end Wait;
      end Started;

      task type Abortable_Waiter (FD : Flyology.IO.Descriptor) is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Abortable_Waiter;

      task body Abortable_Waiter is
         Requests : constant Flyology.IO.Wait_Request_Array :=
           [1 => (FD, Flyology.IO.For_Read)];
         Ignored : Natural;
         pragma Unreferenced (Ignored);
      begin
         Started.Set;
         Ignored := Flyology.IO.Wait_Any (Requests);
      end Abortable_Waiter;

      task type Followup_Waiter (FD : Flyology.IO.Descriptor) is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Followup_Waiter;

      task body Followup_Waiter is
         Requests : constant Flyology.IO.Wait_Request_Array :=
           [1 => (FD, Flyology.IO.For_Read)];
      begin
         Result.Set (Flyology.IO.Wait_Any (Requests, 1.0) = 1);
      exception
         when others => Result.Set (False);
      end Followup_Waiter;

      type Abortable_Access is access Abortable_Waiter;
      Left, Right : Flyology.IO.Sockets.Socket_Type;
      Data : constant Ada.Streams.Stream_Element_Array := [1 => 99];
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      Flyology.IO.Sockets.Create_Socket_Pair (Left, Right);
      Flyology.IO.Sockets.Prepare (Left);
      declare
         FD : constant Flyology.IO.Descriptor :=
           Flyology.IO.Sockets.Native_Descriptor (Left);
         Victim : constant Abortable_Access := new Abortable_Waiter (FD);
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      begin
         Started.Wait;
         delay 0.01;
         abort Victim.all;
         while not Victim.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with "aborted Wait_Any did not terminate";
            end if;
            delay 0.001;
         end loop;

         Flyology.IO.Sockets.Send_Socket (Right, Data, Last);
         pragma Assert (Last = Data'Last);
         declare
            Followup : Followup_Waiter (FD);
            pragma Unreferenced (Followup);
         begin
            select
               Result.Wait (Passed);
            or
               delay 2.0;
               raise Program_Error with "follow-up Wait_Any timed out";
            end select;
            pragma Assert (Passed);
         end;
      end;
      Flyology.IO.Sockets.Close_Socket (Left);
      Flyology.IO.Sockets.Close_Socket (Right);
   end;
end Wait_Any_Smoke;
