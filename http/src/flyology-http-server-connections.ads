with Ada.Streams;
with Flyology.Cancellation;
with Flyology.IO.Connections;

--  Adapts an owned plain Flyology connection to the HTTP transport boundary.
package Flyology.HTTP.Server.Connections is

   --  Borrowing adapter. Channel remains the sole closing owner and must
   --  outlive this object and every HTTP.Server.Connection that refers to it.
   --  The discriminant is the borrowed plain connection.
   type Connection_Transport
     (Channel : not null access Flyology.IO.Connections.Connection)
   is limited new Flyology.HTTP.Server.Transport with private;

   --  Forward a receive through the owned plain connection.
   --  @param Item Plain HTTP transport
   --  @param Data Destination buffer
   --  @param Last Last received byte or close sentinel
   --  @param Timeout Operation deadline
   --  @param Token Optional cancellation source
   overriding procedure Receive
     (Item    : in out Connection_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   --  Forward a complete send through the owned plain connection.
   --  @param Item Plain HTTP transport
   --  @param Data Source bytes
   --  @param Timeout Operation deadline
   --  @param Token Optional cancellation source
   overriding procedure Send_All
     (Item    : in out Connection_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

private
   type Connection_Transport
     (Channel : not null access Flyology.IO.Connections.Connection)
   is limited new Flyology.HTTP.Server.Transport with null record;

end Flyology.HTTP.Server.Connections;
