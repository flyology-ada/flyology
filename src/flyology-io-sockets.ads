with Ada.Streams;
with GNAT.Sockets;

package Flyology.IO.Sockets is

   Operation_Interrupted : exception;

   --  Interrupt descriptors are optional readable one-shot wake sources. The
   --  operation raises Operation_Interrupted when any becomes ready; it
   --  never reads or closes them. Ordinary callers can omit both parameters.

   function Native_Descriptor
     (Socket : GNAT.Sockets.Socket_Type) return Descriptor;

   --  Put a socket into the mode required by cooperative readiness waits.
   --  All operations below call Prepare automatically.
   procedure Prepare (Socket : GNAT.Sockets.Socket_Type);

   procedure Receive
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor);

   procedure Receive_Exactly
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor);

   procedure Send
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor);

   procedure Send_All
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor);

   procedure Accept_Connection
     (Server  : GNAT.Sockets.Socket_Type;
      Socket  : out GNAT.Sockets.Socket_Type;
      Address : out GNAT.Sockets.Sock_Addr_Type;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor);

   procedure Connect
     (Socket  : GNAT.Sockets.Socket_Type;
      Server  : GNAT.Sockets.Sock_Addr_Type;
      Timeout : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor);

end Flyology.IO.Sockets;
