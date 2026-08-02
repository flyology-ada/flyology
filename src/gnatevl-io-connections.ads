with Ada.Finalization;
with Ada.Streams;
with GNAT.Sockets;

package Gnatevl.IO.Connections is

   Admission_Closed : exception;
   Operation_Cancelled : exception;

   protected type Cancellation_Token is
      procedure Request;
      function Requested return Boolean;
   private
      Is_Requested : Boolean := False;
   end Cancellation_Token;

   protected type Server (Capacity : Positive) is
      entry Acquire (Accepted : out Boolean);
      procedure Release;
      procedure Request_Shutdown;
      entry Await_Drained;
      function Shutdown_Requested return Boolean;
      function Active return Natural;
      function Waiting return Natural;
   private
      Active_Count : Natural := 0;
      Stopping     : Boolean := False;
   end Server;

   type Connection is new Ada.Finalization.Limited_Controlled with private;

   --  Server must outlive every Connection admitted through it. On success,
   --  Socket becomes No_Socket and Item becomes its sole closing owner.
   procedure Take
     (Manager : aliased in out Server;
      Socket  : in out GNAT.Sockets.Socket_Type;
      Item    : in out Connection);

   --  Admission is acquired before accept, so Capacity applies backpressure
   --  to the listening socket rather than accepting unbounded connections.
   procedure Accept_Connection
     (Manager              : aliased in out Server;
      Listener             : GNAT.Sockets.Socket_Type;
      Item                 : in out Connection;
      Address              : out GNAT.Sockets.Sock_Addr_Type;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   with Pre => Cancellation_Quantum > 0.0;

   procedure Close (Item : in out Connection);
   function Is_Open (Item : Connection) return Boolean;

   procedure Receive
     (Item                 : in out Connection;
      Data                 : out Ada.Streams.Stream_Element_Array;
      Last                 : out Ada.Streams.Stream_Element_Offset;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   with Pre => Cancellation_Quantum > 0.0;

   procedure Receive_Exactly
     (Item                 : in out Connection;
      Data                 : out Ada.Streams.Stream_Element_Array;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   with Pre => Cancellation_Quantum > 0.0;

   procedure Send_All
     (Item                 : in out Connection;
      Data                 : Ada.Streams.Stream_Element_Array;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   with Pre => Cancellation_Quantum > 0.0;

private
   type Server_Access is access all Server;

   type Connection is new Ada.Finalization.Limited_Controlled with record
      Socket : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Owner  : Server_Access := null;
   end record;

   overriding procedure Finalize (Item : in out Connection);
end Gnatevl.IO.Connections;
