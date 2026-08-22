with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Flyology.IO.Socket_Handoffs;
with Flyology.IO.Sockets;
with Flyology.Subprocesses;
with Flyology.Subprocesses.Bootstrap;

procedure Process_Bootstrap_Smoke is
   package Bootstrap renames Flyology.Subprocesses.Bootstrap;
   package Handoffs renames Flyology.IO.Socket_Handoffs;
   package Sockets renames Flyology.IO.Sockets;
   package Subprocesses renames Flyology.Subprocesses;

   use type Ada.Streams.Stream_Element_Array;

   Fixture : constant String := Ada.Directories.Compose
     (Ada.Directories.Containing_Directory
        (Ada.Directories.Full_Name (Ada.Command_Line.Command_Name)),
      "subprocess_fixture");

   Command      : Subprocesses.Command := Subprocesses.To_Command (Fixture);
   Child        : Subprocesses.Process;
   Control      : Sockets.Socket_Type;
   Capabilities : Handoffs.Handoff_Channel;
   Listener     : Sockets.Socket_Type;
   Client       : Sockets.Socket_Type;
   Address      : Sockets.Endpoint;
   Reply        : Ada.Streams.Stream_Element_Array (1 .. 1);
   Ack          : Ada.Streams.Stream_Element_Array (1 .. 1);
   Status       : Subprocesses.Exit_Status;
begin
   Subprocesses.Append_Argument (Command, "bootstrap");
   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Listen_Socket (Listener, Length => 4);
   Address := Sockets.Get_Socket_Name (Listener);

   Bootstrap.Spawn (Command, Child, Control, Capabilities);
   pragma Assert (not Subprocesses.Standard_Input_Is_Open (Child));
   pragma Assert (not Subprocesses.Standard_Output_Is_Open (Child));
   pragma Assert (not Subprocesses.Standard_Error_Is_Open (Child));
   Sockets.Send_All (Control, [1 => 16#42#], Timeout => 2.0);
   Handoffs.Send_Listener (Capabilities, Listener, Handoffs.Borrow);

   Sockets.Create_Socket (Client);
   Sockets.Connect (Client, Address, Timeout => 2.0);
   Sockets.Send_All (Client, [1 => 16#58#], Timeout => 2.0);
   Sockets.Receive_Exactly (Client, Reply, Timeout => 2.0);
   Sockets.Receive_Exactly (Control, Ack, Timeout => 2.0);
   pragma Assert (Reply = [1 => 16#59#]);
   pragma Assert (Ack = [1 => 16#41#]);

   Subprocesses.Wait (Child, Status, Timeout => 2.0);
   pragma Assert (Subprocesses.Has_Exited (Child));
   pragma Assert (Subprocesses.Successful (Status));
   Subprocesses.Close (Child);
end Process_Bootstrap_Smoke;
