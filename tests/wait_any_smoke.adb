with Ada.Streams;
with Ada.Real_Time;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO;
with Gnatevl.IO.Sockets;

procedure Wait_Any_Smoke is
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;

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

   task type Runner (Model : Gnatevl.Execution_Model) is
      pragma Task_Info (Model);
   end Runner;

   task body Runner is
      Left_1, Right_1 : GNAT.Sockets.Socket_Type;
      Left_2, Right_2 : GNAT.Sockets.Socket_Type;
      Data : constant Ada.Streams.Stream_Element_Array := [1 => 42];
      Last : Ada.Streams.Stream_Element_Offset;
      Passed : Boolean := False;
   begin
      GNAT.Sockets.Create_Socket_Pair (Left_1, Right_1);
      GNAT.Sockets.Create_Socket_Pair (Left_2, Right_2);
      Gnatevl.IO.Sockets.Prepare (Left_1);
      Gnatevl.IO.Sockets.Prepare (Left_2);
      GNAT.Sockets.Send_Socket (Right_2, Data, Last);
      pragma Assert (Last = Data'Last);

      declare
         Requests : constant Gnatevl.IO.Wait_Request_Array (7 .. 8) :=
           [7 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_1),
                  Gnatevl.IO.For_Read),
            8 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_2),
                  Gnatevl.IO.For_Read)];
      begin
         Passed := Gnatevl.IO.Wait_Any (Requests, 1.0) = 8;
      end;

      --  Right_2 became ready first, but both distinct descriptors are ready
      --  before this event-loop maintenance pass. Lowest caller index wins,
      --  independent of kernel event ordering.
      GNAT.Sockets.Send_Socket (Right_1, Data, Last);
      declare
         Requests : constant Gnatevl.IO.Wait_Request_Array (7 .. 8) :=
           [7 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_1),
                  Gnatevl.IO.For_Read),
            8 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_2),
                  Gnatevl.IO.For_Read)];
         Got : constant Natural := Gnatevl.IO.Wait_Any (Requests, 1.0);
         Drained : Ada.Streams.Stream_Element_Array (1 .. 1);
      begin
         Passed := Passed and then Got = 7;
         GNAT.Sockets.Receive_Socket (Left_1, Drained, Last);
      end;

      declare
         Requests : constant Gnatevl.IO.Wait_Request_Array (4 .. 5) :=
           [others =>
              (Gnatevl.IO.Sockets.Native_Descriptor (Left_2),
               Gnatevl.IO.For_Read)];
      begin
         Passed := Passed and then Gnatevl.IO.Wait_Any (Requests, 0.0) = 4;
      end;

      declare
         Requests : Gnatevl.IO.Wait_Request_Array
           (1 .. Gnatevl.IO.Max_Wait_Requests);
      begin
         Requests :=
           [others =>
              (Gnatevl.IO.Sockets.Native_Descriptor (Left_2),
               Gnatevl.IO.For_Read)];
         Passed := Passed and then Gnatevl.IO.Wait_Any (Requests, 0.0) = 1;
      end;

      declare
         Empty : Gnatevl.IO.Wait_Request_Array (2 .. 1);
      begin
         Passed := Passed and then Gnatevl.IO.Wait_Any (Empty, 0.0) = 0;
      end;

      declare
         Requests : constant Gnatevl.IO.Wait_Request_Array :=
           [1 => (Gnatevl.IO.Invalid_Descriptor, Gnatevl.IO.For_Read),
            2 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_1),
                  Gnatevl.IO.For_Write)];
         Rejected : Boolean := False;
      begin
         begin
            declare
               Ignored : constant Natural := Gnatevl.IO.Wait_Any (Requests);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Gnatevl.IO.Device_Error => Rejected := True;
         end;
         Passed := Passed and Rejected;
      end;

      --  A closed, nonnegative descriptor reaches poll/kqueue/epoll rather
      --  than the public negative-descriptor guard.  Placing a valid request
      --  second makes the evented reverse-registration path arm it before the
      --  closed descriptor fails, exercising transactional rollback.
      declare
         Closed_Left, Closed_Right : GNAT.Sockets.Socket_Type;
      begin
         GNAT.Sockets.Create_Socket_Pair (Closed_Left, Closed_Right);
         declare
            Closed_FD : constant Gnatevl.IO.Descriptor :=
              Gnatevl.IO.Sockets.Native_Descriptor (Closed_Left);
            Requests : constant Gnatevl.IO.Wait_Request_Array :=
              [1 => (Closed_FD, Gnatevl.IO.For_Read),
               2 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_1),
                     Gnatevl.IO.For_Write)];
            Rejected : Boolean := False;
         begin
            GNAT.Sockets.Close_Socket (Closed_Left);
            begin
               declare
                  Ignored : constant Natural :=
                    Gnatevl.IO.Wait_Any (Requests, 0.1);
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            exception
               when Gnatevl.IO.Device_Error => Rejected := True;
            end;
            Passed := Passed and Rejected;
         end;
         GNAT.Sockets.Close_Socket (Closed_Right);
      end;

      declare
         Requests : constant Gnatevl.IO.Wait_Request_Array (1 .. 2) :=
           [1 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_1),
                  Gnatevl.IO.For_Read),
            2 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_1),
                  Gnatevl.IO.For_Write)];
      begin
         Passed := Passed and then Gnatevl.IO.Wait_Any (Requests, 1.0) = 2;
      end;

      declare
         Request : constant Gnatevl.IO.Wait_Request_Array :=
           [1 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_1),
                  Gnatevl.IO.For_Read)];
      begin
         Passed := Passed and then Gnatevl.IO.Wait_Any (Request, 0.01) = 0;
      end;

      GNAT.Sockets.Close_Socket (Left_1);
      GNAT.Sockets.Close_Socket (Right_1);
      GNAT.Sockets.Close_Socket (Left_2);
      GNAT.Sockets.Close_Socket (Right_2);

      --  A timed-out wait must leave no registration that can act on a later
      --  descriptor generation reusing the same integer.
      GNAT.Sockets.Create_Socket_Pair (Left_1, Right_1);
      Gnatevl.IO.Sockets.Prepare (Left_1);
      declare
         Request : constant Gnatevl.IO.Wait_Request_Array :=
           [1 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_1),
                  Gnatevl.IO.For_Read)];
      begin
         Passed := Passed and then Gnatevl.IO.Wait_Any (Request, 0.005) = 0;
      end;
      GNAT.Sockets.Close_Socket (Left_1);
      GNAT.Sockets.Close_Socket (Right_1);
      GNAT.Sockets.Create_Socket_Pair (Left_1, Right_1);
      Gnatevl.IO.Sockets.Prepare (Left_1);
      GNAT.Sockets.Send_Socket (Right_1, Data, Last);
      declare
         Request : constant Gnatevl.IO.Wait_Request_Array :=
           [1 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_1),
                  Gnatevl.IO.For_Read)];
      begin
         Passed := Passed and then Gnatevl.IO.Wait_Any (Request, 0.1) = 1;
      end;
      GNAT.Sockets.Close_Socket (Left_1);
      GNAT.Sockets.Close_Socket (Right_1);
      Result.Set (Passed);
   exception
      when others =>
         Result.Set (False);
   end Runner;

   type Runner_Access is access Runner;
   Native  : Runner_Access;
   Evented : Runner_Access;
   pragma Unreferenced (Native, Evented);
   Passed  : Boolean;
begin
   GNAT.Sockets.Initialize;
   Native := new Runner (Gnatevl.Native_Thread);
   Result.Wait (Passed);
   pragma Assert (Passed);
   Evented := new Runner (Gnatevl.Event_Loop_Task);
   Result.Wait (Passed);
   pragma Assert (Passed);

   --  Aborting an evented task while Wait_Any is suspended must unregister
   --  every kernel interest before its stack-resident wait links disappear.
   --  A second evented waiter on the same descriptor checks that the poller
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

      task type Abortable_Waiter (FD : Gnatevl.IO.Descriptor) is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Abortable_Waiter;

      task body Abortable_Waiter is
         Requests : constant Gnatevl.IO.Wait_Request_Array :=
           [1 => (FD, Gnatevl.IO.For_Read)];
         Ignored : Natural;
         pragma Unreferenced (Ignored);
      begin
         Started.Set;
         Ignored := Gnatevl.IO.Wait_Any (Requests);
      end Abortable_Waiter;

      task type Followup_Waiter (FD : Gnatevl.IO.Descriptor) is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Followup_Waiter;

      task body Followup_Waiter is
         Requests : constant Gnatevl.IO.Wait_Request_Array :=
           [1 => (FD, Gnatevl.IO.For_Read)];
      begin
         Result.Set (Gnatevl.IO.Wait_Any (Requests, 1.0) = 1);
      exception
         when others => Result.Set (False);
      end Followup_Waiter;

      type Abortable_Access is access Abortable_Waiter;
      Left, Right : GNAT.Sockets.Socket_Type;
      Data : constant Ada.Streams.Stream_Element_Array := [1 => 99];
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      GNAT.Sockets.Create_Socket_Pair (Left, Right);
      Gnatevl.IO.Sockets.Prepare (Left);
      declare
         FD : constant Gnatevl.IO.Descriptor :=
           Gnatevl.IO.Sockets.Native_Descriptor (Left);
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

         GNAT.Sockets.Send_Socket (Right, Data, Last);
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
      GNAT.Sockets.Close_Socket (Left);
      GNAT.Sockets.Close_Socket (Right);
   end;
   GNAT.Sockets.Finalize;
end Wait_Any_Smoke;
