with Ada.Streams;
with GNAT.Sockets;

package Gnatevl.IO.Sockets is

   function Native_Descriptor
     (Socket : GNAT.Sockets.Socket_Type) return Descriptor;

   --  Put a socket into the mode required by cooperative readiness waits.
   --  All operations below call Prepare automatically.
   procedure Prepare (Socket : GNAT.Sockets.Socket_Type);

   procedure Receive
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := Infinite);

   procedure Receive_Exactly
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite);

   procedure Send
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := Infinite);

   procedure Send_All
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite);

   procedure Accept_Connection
     (Server  : GNAT.Sockets.Socket_Type;
      Socket  : out GNAT.Sockets.Socket_Type;
      Address : out GNAT.Sockets.Sock_Addr_Type;
      Timeout : Duration := Infinite);

   procedure Connect
     (Socket  : GNAT.Sockets.Socket_Type;
      Server  : GNAT.Sockets.Sock_Addr_Type;
      Timeout : Duration := Infinite);

end Gnatevl.IO.Sockets;
