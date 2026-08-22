with Ada.Streams;
with Flyology.IO;
with Flyology.IO.Sockets;
with Interfaces.C;

procedure Socket_Preparation_Smoke is
   package Sockets renames Flyology.IO.Sockets;
   use Ada.Streams;
   use type Sockets.Address_Family;
   use type Interfaces.C.unsigned_long_long;

   procedure Reset_Nonblocking_Setups
   with Import, Convention => C, External_Name => "flyology_test_socket_reset_nonblocking_setups";

   function Nonblocking_Setup_Count return Interfaces.C.unsigned_long_long
   with Import, Convention => C, External_Name => "flyology_test_socket_nonblocking_setup_count";

   Payload : constant Stream_Element_Array := [16#A5#, 16#5A#];

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   end Close_If_Open;

   procedure Send_And_Receive
     (Sender : Sockets.Socket_Type; Receiver : Sockets.Socket_Type; Destination : Sockets.Endpoint)
   is
      Incoming : Stream_Element_Array (Payload'Range);
      Last     : Stream_Element_Offset;
      Metadata : Sockets.Datagram_Metadata;
   begin
      Sockets.Send_Datagram (Sender, Payload, Last, Destination, Timeout => 1.0);
      pragma Assert (Last = Payload'Last);
      Sockets.Receive_Datagram (Receiver, Incoming, Last, Metadata, Timeout => 1.0);
      pragma Assert (Last = Incoming'Last);
      pragma Assert (Incoming = Payload);
      pragma Assert (Metadata.Original_Length = Payload'Length);
      pragma Assert (not Metadata.Truncated);
   end Send_And_Receive;

   Server, Client, Moved          : Sockets.Socket_Type;
   Server_Address, Client_Address : Sockets.Endpoint;
begin
   Sockets.Create_Socket (Server, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket (Server, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Server_Address := Sockets.Get_Socket_Name (Server);
   Sockets.Create_Socket (Client, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket (Client, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Client_Address := Sockets.Get_Socket_Name (Client);

   Reset_Nonblocking_Setups;
   for Iteration in 1 .. 3 loop
      Send_And_Receive (Client, Server, Server_Address);
      Send_And_Receive (Server, Client, Client_Address);
   end loop;
   pragma Assert (Nonblocking_Setup_Count = 2);

   Sockets.Move (Client, Moved);
   Send_And_Receive (Moved, Server, Server_Address);
   pragma Assert (Nonblocking_Setup_Count = 2);

   declare
      Blocking : Sockets.Request_Type (Sockets.Non_Blocking_IO) :=
        (Name => Sockets.Non_Blocking_IO, Enabled => False);
   begin
      Sockets.Control_Socket (Moved, Blocking);
   end;
   Send_And_Receive (Moved, Server, Server_Address);
   pragma Assert (Nonblocking_Setup_Count = 3);

   declare
      Descriptor : Flyology.IO.Descriptor;
   begin
      Sockets.Release (Moved, Descriptor);
      Sockets.Adopt (Descriptor, Client);
   end;
   Send_And_Receive (Client, Server, Server_Address);
   pragma Assert (Nonblocking_Setup_Count = 4);

   Sockets.Close_Socket (Client);
   Sockets.Create_Socket (Client, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket (Client, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Client_Address := Sockets.Get_Socket_Name (Client);
   Send_And_Receive (Client, Server, Server_Address);
   pragma Assert (Nonblocking_Setup_Count = 5);

   Sockets.Close_Socket (Client);
   Sockets.Close_Socket (Server);

   declare
      Listener, Connector, Accepted, Accepted_Moved : Sockets.Socket_Type;
      Listener_Address, Peer_Address                : Sockets.Endpoint;
      Incoming                                      : Stream_Element_Array (Payload'Range);
   begin
      Sockets.Create_Socket (Listener, Sockets.IPv4, Sockets.Socket_Stream);
      Sockets.Bind_Socket (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Listener_Address := Sockets.Get_Socket_Name (Listener);
      Sockets.Create_Socket (Connector, Sockets.IPv4, Sockets.Socket_Stream);

      Reset_Nonblocking_Setups;
      Sockets.Connect (Connector, Listener_Address, Timeout => 1.0);
      Sockets.Accept_Connection (Listener, Accepted, Peer_Address, Timeout => 1.0);
      pragma Assert (Peer_Address.Family = Sockets.IPv4);
      pragma Assert (Nonblocking_Setup_Count = 3);

      Sockets.Move (Accepted, Accepted_Moved);
      Sockets.Send_All (Connector, Payload, Timeout => 1.0);
      Sockets.Receive_Exactly (Accepted_Moved, Incoming, Timeout => 1.0);
      pragma Assert (Incoming = Payload);
      pragma Assert (Nonblocking_Setup_Count = 3);

      Sockets.Close_Socket (Accepted_Moved);
      Sockets.Close_Socket (Connector);
      Sockets.Close_Socket (Listener);
   exception
      when others =>
         Close_If_Open (Accepted_Moved);
         Close_If_Open (Accepted);
         Close_If_Open (Connector);
         Close_If_Open (Listener);
         raise;
   end;
exception
   when others =>
      Close_If_Open (Moved);
      Close_If_Open (Client);
      Close_If_Open (Server);
      raise;
end Socket_Preparation_Smoke;
