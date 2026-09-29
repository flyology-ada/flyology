with Ada.Streams;
with Flyology.IO.Socket_Handoffs;
with Flyology.IO.Sockets;
with Interfaces.C;

procedure Socket_Handoff_Smoke is
   package Handoffs renames Flyology.IO.Socket_Handoffs;
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Streams.Stream_Element_Array;
   use type Interfaces.C.long;
   use type Sockets.Endpoint;

   function Send_Descriptor_Once (Carrier, Descriptor : Interfaces.C.int) return Interfaces.C.long;
   pragma Import (C, Send_Descriptor_Once, "flyology_shm_send_fd_once");

   procedure Open_Listener (Listener : in out Sockets.Socket_Type; Address : out Sockets.Endpoint) is
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener, Length => 4);
      Address := Sockets.Get_Socket_Name (Listener);
   end Open_Listener;

   procedure Open_Channel_Pair
     (Left : in out Handoffs.Handoff_Channel; Right : in out Handoffs.Handoff_Channel)
   is
      Left_Socket  : Sockets.Socket_Type;
      Right_Socket : Sockets.Socket_Type;
   begin
      Sockets.Create_Socket_Pair (Left_Socket, Right_Socket);
      Handoffs.Adopt (Left, Left_Socket);
      Handoffs.Adopt (Right, Right_Socket);
   end Open_Channel_Pair;

   procedure Exercise_Borrow is
      Left     : Handoffs.Handoff_Channel;
      Right    : Handoffs.Handoff_Channel;
      Listener : Sockets.Socket_Type;
      Received : Sockets.Socket_Type;
      Client   : Sockets.Socket_Type;
      Accepted : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Peer     : Sockets.Endpoint;
      Byte     : constant Ada.Streams.Stream_Element_Array (1 .. 1) := [1 => 73];
      Reply    : Ada.Streams.Stream_Element_Array (1 .. 1);
   begin
      Open_Channel_Pair (Left, Right);
      Open_Listener (Listener, Address);
      Handoffs.Send_Listener (Left, Listener, Handoffs.Borrow);
      Handoffs.Receive_Listener (Right, Received);

      pragma Assert (Sockets.Is_Open (Listener));
      pragma Assert (Sockets.Get_Socket_Name (Received) = Address);
      pragma Assert (Handoffs.Is_Open (Left));
      pragma Assert (Handoffs.Is_Open (Right));

      Sockets.Create_Socket (Client);
      Sockets.Connect (Client, Address, Timeout => 1.0);
      Sockets.Accept_Connection (Received, Accepted, Peer, Timeout => 1.0);
      Sockets.Send_All (Client, Byte, Timeout => 1.0);
      Sockets.Receive_Exactly (Accepted, Reply, Timeout => 1.0);
      pragma Assert (Reply = Byte);
   end Exercise_Borrow;

   procedure Exercise_Transfer is
      Left     : Handoffs.Handoff_Channel;
      Right    : Handoffs.Handoff_Channel;
      Listener : Sockets.Socket_Type;
      Received : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
   begin
      Open_Channel_Pair (Left, Right);
      Open_Listener (Listener, Address);
      Handoffs.Send_Listener (Left, Listener, Handoffs.Transfer);
      pragma Assert (not Sockets.Is_Open (Listener));
      Handoffs.Receive_Listener (Right, Received);
      pragma Assert (Sockets.Get_Socket_Name (Received) = Address);
   end Exercise_Transfer;

   procedure Reject_Non_Listener is
      Left     : Handoffs.Handoff_Channel;
      Right    : Handoffs.Handoff_Channel;
      Ordinary : Sockets.Socket_Type;
      Rejected : Boolean := False;
   begin
      Open_Channel_Pair (Left, Right);
      Sockets.Create_Socket (Ordinary);
      begin
         Handoffs.Send_Listener (Left, Ordinary);
      exception
         when Handoffs.Validation_Error =>
            Rejected := True;
      end;
      pragma Assert (Rejected);
      pragma Assert (Sockets.Is_Open (Ordinary));
      pragma Assert (Handoffs.Is_Open (Left));
      pragma Assert (not Handoffs.Is_Poisoned (Left));
   end Reject_Non_Listener;

   procedure Poison_Invalid_Receipt is
      Carrier_Left  : Sockets.Socket_Type;
      Carrier_Right : Sockets.Socket_Type;
      Receiver      : Handoffs.Handoff_Channel;
      Ordinary      : Sockets.Socket_Type;
      Received      : Sockets.Socket_Type;
      Rejected      : Boolean := False;
      Amount        : Interfaces.C.long;
   begin
      Sockets.Create_Socket_Pair (Carrier_Left, Carrier_Right);
      Handoffs.Adopt (Receiver, Carrier_Right);
      Sockets.Create_Socket (Ordinary);
      Amount :=
        Send_Descriptor_Once
          (Interfaces.C.int (Sockets.Native_Descriptor (Carrier_Left)),
           Interfaces.C.int (Sockets.Native_Descriptor (Ordinary)));
      pragma Assert (Amount = 1);
      begin
         Handoffs.Receive_Listener (Receiver, Received);
      exception
         when Handoffs.Validation_Error =>
            Rejected := True;
      end;
      pragma Assert (Rejected);
      pragma Assert (not Sockets.Is_Open (Received));
      pragma Assert (not Handoffs.Is_Open (Receiver));
      pragma Assert (Handoffs.Is_Poisoned (Receiver));
   end Poison_Invalid_Receipt;

begin
   Exercise_Borrow;
   Exercise_Transfer;
   Reject_Non_Listener;
   Poison_Invalid_Receipt;
end Socket_Handoff_Smoke;
