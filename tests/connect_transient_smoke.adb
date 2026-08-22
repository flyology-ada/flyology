with Ada.Streams;
with Fault_Control;
with Flyology;
with Flyology.IO.Sockets;

--  POSIX keeps an interrupted connect(2) attempt alive: the kernel continues
--  establishing the connection asynchronously. Both the blocking setup call
--  and the task-aware call must therefore finish that handshake instead of
--  reporting a hard failure, while a genuinely refused connection still
--  fails.

procedure Connect_Transient_Smoke is
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Streams.Stream_Element_Array;

   Probe : constant Ada.Streams.Stream_Element_Array (1 .. 1) := (1 => 97);

   procedure Open_Listener (Listener : in out Sockets.Socket_Type; Address : out Sockets.Endpoint);

   procedure Close_Endpoint_Owner (Socket : in out Sockets.Socket_Type);

   procedure Open_Listener (Listener : in out Sockets.Socket_Type; Address : out Sockets.Endpoint) is
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener, Length => 16);
      Address := Sockets.Get_Socket_Name (Listener);
   end Open_Listener;

   procedure Close_Endpoint_Owner (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   end Close_Endpoint_Owner;

   --  An interrupted blocking connect leaves the socket connected. Prove the
   --  call returns the established connection rather than raising, and that
   --  the peer really completed the handshake.
   procedure Run_Blocking_Interrupt is
      Listener : Sockets.Socket_Type;
      Client   : Sockets.Socket_Type;
      Served   : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Peer     : Sockets.Endpoint;
      Echoed   : Ada.Streams.Stream_Element_Array (1 .. 1);
      Returned : Ada.Streams.Stream_Element_Array (1 .. 1);
   begin
      Open_Listener (Listener, Address);
      Fault_Control.Reset;
      Fault_Control.Arm (Fault_Control.Connect_Interrupted);
      Sockets.Create_Socket (Client);
      Sockets.Connect_Socket (Client, Address);
      pragma Assert (Fault_Control.Calls (Fault_Control.Connect_Interrupted) = 1);

      Sockets.Accept_Connection (Listener, Served, Peer, Timeout => 5.0);
      Sockets.Send_All (Client, Probe, Timeout => 5.0);
      Sockets.Receive_Exactly (Served, Echoed, Timeout => 5.0);
      pragma Assert (Echoed = Probe);
      Sockets.Send_All (Served, Echoed, Timeout => 5.0);
      Sockets.Receive_Exactly (Client, Returned, Timeout => 5.0);
      pragma Assert (Returned = Probe);

      Close_Endpoint_Owner (Served);
      Close_Endpoint_Owner (Client);
      Close_Endpoint_Owner (Listener);
      Fault_Control.Reset;
   end Run_Blocking_Interrupt;

   --  A refused connection must still fail, whether or not the attempt is
   --  reported as interrupted.
   procedure Run_Blocking_Refused is
      Listener : Sockets.Socket_Type;
      Client   : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Refused  : Boolean := False;
   begin
      Open_Listener (Listener, Address);
      Close_Endpoint_Owner (Listener);
      Fault_Control.Reset;
      Fault_Control.Arm (Fault_Control.Connect_Interrupted);
      Sockets.Create_Socket (Client);
      begin
         Sockets.Connect_Socket (Client, Address);
      exception
         when Sockets.Socket_Error =>
            Refused := True;
      end;
      pragma Assert (Refused);
      Close_Endpoint_Owner (Client);
      Fault_Control.Reset;
   end Run_Blocking_Refused;

   generic
      Model : Flyology.Execution_Model;
   procedure Run_Task_Aware;

   procedure Run_Task_Aware is
      Listener   : Sockets.Socket_Type;
      Served     : Sockets.Socket_Type;
      Address    : Sockets.Endpoint;
      Peer       : Sockets.Endpoint;
      Echoed     : Ada.Streams.Stream_Element_Array (1 .. 1);
      Client_OK  : Boolean := False
      with Atomic;
      Refused_OK : Boolean := False
      with Atomic;
   begin
      Open_Listener (Listener, Address);
      Fault_Control.Reset;
      Fault_Control.Arm (Fault_Control.Connect_Interrupted);
      declare
         task Client is
            pragma Task_Info (Model);
         end Client;

         task body Client is
            Socket   : Sockets.Socket_Type;
            Returned : Ada.Streams.Stream_Element_Array (1 .. 1);
         begin
            Sockets.Create_Socket (Socket);
            Sockets.Connect (Socket, Address, Timeout => 5.0);
            Sockets.Send_All (Socket, Probe, Timeout => 5.0);
            Sockets.Receive_Exactly (Socket, Returned, Timeout => 5.0);
            Client_OK := Returned = Probe;
            Sockets.Close_Socket (Socket);
         exception
            when others =>
               Close_Endpoint_Owner (Socket);
         end Client;
      begin
         Sockets.Accept_Connection (Listener, Served, Peer, Timeout => 5.0);
         Sockets.Receive_Exactly (Served, Echoed, Timeout => 5.0);
         Sockets.Send_All (Served, Echoed, Timeout => 5.0);
      end;
      pragma Assert (Client_OK);
      pragma Assert (Fault_Control.Calls (Fault_Control.Connect_Interrupted) = 1);
      Close_Endpoint_Owner (Served);
      Close_Endpoint_Owner (Listener);
      Fault_Control.Reset;

      --  The same injection must not turn a refused connection into success:
      --  the pending socket error is read after readiness.
      Open_Listener (Listener, Address);
      Close_Endpoint_Owner (Listener);
      Fault_Control.Reset;
      Fault_Control.Arm (Fault_Control.Connect_Interrupted);
      declare
         task Rejected is
            pragma Task_Info (Model);
         end Rejected;

         task body Rejected is
            Socket : Sockets.Socket_Type;
         begin
            Sockets.Create_Socket (Socket);
            begin
               Sockets.Connect (Socket, Address, Timeout => 5.0);
            exception
               when Sockets.Socket_Error =>
                  Refused_OK := True;
            end;
            Close_Endpoint_Owner (Socket);
         end Rejected;
      begin
         null;
      end;
      pragma Assert (Refused_OK);
      Fault_Control.Reset;
   end Run_Task_Aware;

   procedure Run_Native is new Run_Task_Aware (Flyology.Native_Task);
   procedure Run_Lightweight is new Run_Task_Aware (Flyology.Lightweight_Task);
begin
   if not Fault_Control.Enabled then
      raise Program_Error with "connect transient test requires FLYOLOGY_TEST_FAULTS=1 runtime";
   end if;
   Run_Blocking_Interrupt;
   Run_Blocking_Refused;
   Run_Native;
   Run_Lightweight;
end Connect_Transient_Smoke;
