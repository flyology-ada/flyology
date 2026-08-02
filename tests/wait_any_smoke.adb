with Ada.Streams;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO;
with Gnatevl.IO.Sockets;

procedure Wait_Any_Smoke is
   use type Ada.Streams.Stream_Element_Offset;

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

      --  Simultaneously ready, distinct descriptors deliberately have no
      --  ordering promise; either precise index is valid.
      GNAT.Sockets.Send_Socket (Right_1, Data, Last);
      declare
         Requests : constant Gnatevl.IO.Wait_Request_Array (7 .. 8) :=
           [7 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_1),
                  Gnatevl.IO.For_Read),
            8 => (Gnatevl.IO.Sockets.Native_Descriptor (Left_2),
                  Gnatevl.IO.For_Read)];
         Got : constant Natural := Gnatevl.IO.Wait_Any (Requests, 0.0);
         Drained : Ada.Streams.Stream_Element_Array (1 .. 1);
      begin
         Passed := Passed and then Got in 7 | 8;
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
   Passed  : Boolean;
begin
   GNAT.Sockets.Initialize;
   Native := new Runner (Gnatevl.Native_Thread);
   Result.Wait (Passed);
   pragma Assert (Passed);
   Evented := new Runner (Gnatevl.Event_Loop_Task);
   Result.Wait (Passed);
   pragma Assert (Passed);
   GNAT.Sockets.Finalize;
end Wait_Any_Smoke;
