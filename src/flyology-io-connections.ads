with Ada.Finalization;
with Ada.Streams;
with GNAT.Sockets;
with Flyology.Wake_Sources;

package Flyology.IO.Connections is

   Admission_Closed : exception;
   Operation_Cancelled : exception;

   protected type Cancellation_Token is
      procedure Request;
      function Requested return Boolean;
      procedure Wait_Source
        (FD : out Flyology.IO.Descriptor; Already_Requested : out Boolean);
   private
      Is_Requested : Boolean := False;
      Wake         : Flyology.Wake_Sources.Source;
   end Cancellation_Token;

   protected type Server (Capacity : Positive) is
      entry Acquire (Accepted : out Boolean);
      procedure Release;
      procedure Request_Shutdown;
      entry Await_Drained;
      function Shutdown_Requested return Boolean;
      function Active return Natural;
      function Waiting return Natural;
      procedure Wait_Source
        (FD : out Flyology.IO.Descriptor; Already_Requested : out Boolean);
   private
      Active_Count : Natural := 0;
      Stopping     : Boolean := False;
      Wake         : Flyology.Wake_Sources.Source;
   end Server;

   type Connection is new Ada.Finalization.Limited_Controlled with private;

   --  Cancellation_Token and Server are one-shot wake sources. They must
   --  outlive operations using them. Cancellation_Quantum is retained on the
   --  operations below for source compatibility; scheduler-driven wakeups make
   --  it unnecessary and its value is ignored.

   --  Server must outlive every Connection admitted through it. On success,
   --  Socket becomes No_Socket and Item becomes its sole closing owner. One
   --  operation at a time is admitted per Connection; this deliberate
   --  exclusivity prevents a readiness event from waking an unbounded set of
   --  waiters on the same descriptor.
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

   type Descriptor_Generation is mod 2 ** 64;

   protected type Descriptor_Controller is
      procedure Adopt (FD : Flyology.IO.Descriptor);
      entry Acquire
        (FD           : out Flyology.IO.Descriptor;
         Generation   : out Descriptor_Generation;
         Close_Source : out Flyology.IO.Descriptor);
      procedure Release (Generation : Descriptor_Generation);
      procedure Begin_Close
        (FD         : out Flyology.IO.Descriptor;
         Generation : out Descriptor_Generation;
         Leader     : out Boolean);
      entry Await_Drained;
      entry Await_Closed;
      procedure Finish_Close (Generation : Descriptor_Generation);
      function Is_Open_State return Boolean;
   private
      Current_FD         : Flyology.IO.Descriptor := Invalid_Descriptor;
      Current_Generation : Descriptor_Generation := 0;
      Active             : Boolean := False;
      Closing            : Boolean := False;
      Close_Wake         : Flyology.Wake_Sources.Source;
   end Descriptor_Controller;

   type Connection is new Ada.Finalization.Limited_Controlled with record
      Socket : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Owner  : Server_Access := null;
      Controller : Descriptor_Controller;
   end record;

   overriding procedure Finalize (Item : in out Connection);
end Flyology.IO.Connections;
