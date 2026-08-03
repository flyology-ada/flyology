with Ada.Finalization;
with Ada.Streams;
with GNAT.Sockets;
with Flyology.Cancellation;
with Flyology.Wake_Sources;

--  Adds ownership, admission control, and cancellation to socket connections.
--
--  Example:
--
--     Flyology.IO.Connections.Take (Manager, Socket, Client);
package Flyology.IO.Connections is

   --  Raised when a Server no longer admits connections.
   Admission_Closed : exception;
   --  Raised when server shutdown, an explicit token, or concurrent Close
   --  interrupts an operation. This is the canonical cross-I/O exception.
   Operation_Cancelled : exception renames
     Flyology.Cancellation.Operation_Cancelled;

   --  Canonical thread-safe one-shot cancellation source. Request is
   --  idempotent. The token must outlive every operation using it.
   subtype Cancellation_Token is Flyology.Cancellation.Token;

   --  Thread-safe connection admission controller. Acquire suspends when
   --  Capacity is full: lightweight tasks suspend cooperatively and native
   --  tasks block their threads. The object must outlive every Connection
   --  admitted through it.
   protected type Server
     (Capacity : Positive)  --  Maximum concurrently owned connections
   is
      --  Wait for capacity or shutdown.
      entry Acquire
        (Accepted : out Boolean);  --  Whether a permit was acquired
      --  Release one acquired permit.
      --  @exception Program_Error No permit is active
      procedure Release;
      --  Idempotently close admission and wake waiters.
      --  @exception Program_Error The shutdown descriptor cannot be signalled
      procedure Request_Shutdown;
      --  Wait until shutdown was requested and all permits were released.
      entry Await_Drained;
      --  Report whether shutdown has been requested.
      --  @return True after Request_Shutdown
      function Shutdown_Requested return Boolean;
      --  Return the number of active permits.
      --  @return Current admitted connection count
      function Active return Natural;
      --  Return the number of callers queued at Acquire.
      --  @return Current Acquire entry count
      function Waiting return Natural;
      --  Return the borrowed shutdown descriptor without consuming it.
      --  @exception Program_Error The shutdown descriptor cannot be created
      procedure Wait_Source
        (FD : out Flyology.IO.Descriptor;  --  Borrowed readiness descriptor
         Already_Requested : out Boolean);
         --  Whether shutdown already started
   private
      Active_Count : Natural := 0;  --  Current admitted connections
      Stopping     : Boolean := False;  --  Whether admission is closed
      Wake :
        Flyology.Wake_Sources.Source;  --  Shutdown readiness source
   end Server;

   --  Sole closing owner of one socket and one Server admission permit.
   --  Finalize calls Close. Close is idempotent and may run concurrently with
   --  one I/O operation; that operation is cancelled before the socket closes.
   --  Other operations on the same Connection are serialized. Server must
   --  outlive the Connection.
   type Connection is new Ada.Finalization.Limited_Controlled with private;

   --  Transfer Socket and one Manager permit to Item. On success Socket
   --  becomes
   --  No_Socket and Item is the sole closing owner.
   --  @param Manager Admission controller that must outlive Item
   --  @param Socket Open socket whose ownership transfers on success
   --  @param Item Closed Connection that receives ownership
   --  @exception Admission_Closed Manager has started shutdown
   --  @exception Program_Error Socket or Item is invalid, or wake setup fails
   procedure Take
     (Manager : aliased in out Server;
      Socket  : in out GNAT.Sockets.Socket_Type;
      Item    : in out Connection);

   --  Acquire capacity before accepting, so a full Manager backpressures the
   --  listening socket. Transient aborted admissions are retried; descriptor
   --  exhaustion uses interruptible bounded backoff. One Timeout deadline
   --  spans readiness, retries, and backoff. Negative is unlimited and zero is
   --  immediate. Cancellation_Quantum must be positive for compatibility but
   --  is ignored; wake-source readiness notices cancellation without periodic
   --  polling. Lightweight tasks suspend; native tasks block their threads.
   --  @param Manager Admission controller that must outlive Item
   --  @param Listener Open listening socket; ownership is retained
   --  @param Item Closed Connection that receives the accepted socket
   --  @param Address Accepted peer address
   --  @param Timeout Deadline interval in seconds
   --  @param Cancellation_Quantum Compatibility parameter; value is ignored
   --  @param Token Optional one-shot cancellation source that must outlive
   --     the call
   --  @exception Admission_Closed Manager has closed admission before reserve
   --  @exception Operation_Cancelled Shutdown or Token interrupts the accept
   --  @exception Timeout_Error The accept deadline expires
   --  @exception Device_Error Readiness polling fails
   --  @exception GNAT.Sockets.Socket_Error Accept or socket setup fails
   --  @exception Program_Error Item is open or a wake source cannot be created
   procedure Accept_Connection
     (Manager              : aliased in out Server;
      Listener             : GNAT.Sockets.Socket_Type;
      Item                 : in out Connection;
      Address              : out GNAT.Sockets.Sock_Addr_Type;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   with Pre => Cancellation_Quantum > 0.0;

   --  Cancel any active operation, close Item's socket, and release its Server
   --  permit. Concurrent callers wait for the same close. Closing a closed
   --  Item is harmless.
   --  @param Item Connection whose ownership is released
   --  @exception GNAT.Sockets.Socket_Error The underlying close reports
   --     failure
   procedure Close (Item : in out Connection);
   --  Query the protected ownership state.
   --  @param Item Connection to inspect
   --  @return True while Item owns a socket and is not closing
   function Is_Open (Item : Connection) return Boolean;

   --  Receive one chunk under Item's exclusive operation lease. Timeout and
   --  lane behavior match Accept_Connection. Cancellation_Quantum is ignored;
   --  Manager shutdown, Token, or concurrent Close wakes the operation.
   --  @param Item Open connection
   --  @param Data Destination buffer
   --  @param Last Last element received, or Data'First - 1 on orderly closure
   --  @param Timeout Deadline interval in seconds
   --  @param Cancellation_Quantum Compatibility parameter; value is ignored
   --  @param Token Optional token that must outlive this call
   --  @exception Operation_Cancelled Shutdown, Token, or Close interrupts I/O
   --  @exception Timeout_Error The deadline expires
   --  @exception Device_Error Readiness polling fails
   --  @exception GNAT.Sockets.Socket_Error Socket receive or setup fails
   --  @exception Program_Error Item is closed or a wake source cannot be used
   procedure Receive
     (Item                 : in out Connection;
      Data                 : out Ada.Streams.Stream_Element_Array;
      Last                 : out Ada.Streams.Stream_Element_Offset;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   with Pre => Cancellation_Quantum > 0.0;

   --  Fill Data under a sequence-wide deadline. One deadline spans all partial
   --  receives and retries. Cancellation and lane behavior match Receive.
   --  @param Item Open connection
   --  @param Data Destination buffer to fill
   --  @param Timeout Deadline interval in seconds
   --  @param Cancellation_Quantum Compatibility parameter; value is ignored
   --  @param Token Optional token that must outlive this call
   --  @exception Operation_Cancelled Shutdown, Token, or Close interrupts I/O
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Device_Error Polling fails or the peer closes early
   --  @exception GNAT.Sockets.Socket_Error Socket receive or setup fails
   --  @exception Program_Error Item is closed or a wake source cannot be used
   procedure Receive_Exactly
     (Item                 : in out Connection;
      Data                 : out Ada.Streams.Stream_Element_Array;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   with Pre => Cancellation_Quantum > 0.0;

   --  Send all Data under one exclusive operation lease and one deadline.
   --  Cancellation_Quantum is ignored; cancellation sources wake readiness.
   --  @param Item Open connection
   --  @param Data Source buffer to send completely
   --  @param Timeout Deadline interval in seconds
   --  @param Cancellation_Quantum Compatibility parameter; value is ignored
   --  @param Token Optional token that must outlive this call
   --  @exception Operation_Cancelled Shutdown, Token, or Close interrupts I/O
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Device_Error Polling fails or no forward progress is made
   --  @exception GNAT.Sockets.Socket_Error Socket send or setup fails
   --  @exception Program_Error Item is closed or a wake source cannot be used
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
      --  Publish descriptor, socket, and admission ownership atomically.
      procedure Adopt
        (FD     : Flyology.IO.Descriptor;
         Socket : GNAT.Sockets.Socket_Type;
         Owner  : Server_Access);
      entry Acquire
        (FD           : out Flyology.IO.Descriptor;
         Generation   : out Descriptor_Generation;
         Close_Source : out Flyology.IO.Descriptor;
         Socket       : out GNAT.Sockets.Socket_Type;
         Owner        : out Server_Access);
      procedure Release (Generation : Descriptor_Generation);
      procedure Begin_Close
        (FD         : out Flyology.IO.Descriptor;
         Generation : out Descriptor_Generation;
         Leader     : out Boolean);
      entry Await_Drained
        (Socket : out GNAT.Sockets.Socket_Type;
         Owner  : out Server_Access);
      entry Await_Closed;
      procedure Finish_Close (Generation : Descriptor_Generation);
      function Is_Open_State return Boolean;
   private
      Current_FD         : Flyology.IO.Descriptor := Invalid_Descriptor;
      Current_Generation : Descriptor_Generation := 0;
      Active             : Boolean := False;
      Closing            : Boolean := False;
      Close_Wake         : Flyology.Wake_Sources.Source;
      Current_Socket     : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Current_Owner      : Server_Access := null;
   end Descriptor_Controller;

   type Connection is new Ada.Finalization.Limited_Controlled with record
      Controller : Descriptor_Controller;
   end record;

   --  Close Item without propagating cleanup errors.
   --  @param Item Connection being finalized
   overriding procedure Finalize (Item : in out Connection);
end Flyology.IO.Connections;
