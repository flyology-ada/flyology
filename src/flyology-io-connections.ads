with Ada.Finalization;
with Ada.Streams;
with Flyology.Capacity;
with Flyology.Cancellation;
with Flyology.IO.Sockets;
with Flyology.Wake_Sources;
private with Flyology.IO.TLS;

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

   --  General bounded admission gate used for connection ownership. Existing
   --  Server declarations remain source-compatible; the implementation is
   --  shared with non-I/O capacity control through Flyology.Capacity.
   subtype Server is Flyology.Capacity.Gate;

   --  Sole closing owner of one socket and one Server admission permit.
   --  Finalize calls Close. At most one I/O operation holds the active lease,
   --  while multiple callers may be registered or queued for it. Close is
   --  idempotent and may run concurrently with all of them: it cancels and
   --  drains the active operation and every registered or queued operation
   --  before closing the socket. The TLS child may replace the plaintext
   --  transport in place without changing this ownership. Server must outlive
   --  the Connection.
   type Connection is new Ada.Finalization.Limited_Controlled with private;

   --  Wait indefinitely for one Manager permit, then transfer Socket to Item.
   --  This compatibility operation has no timeout or cancellation token;
   --  Manager shutdown releases its admission wait with Admission_Closed. On
   --  success Socket is closed and Item is the sole closing owner.
   --  @param Manager Admission controller that must outlive Item
   --  @param Socket Open socket whose ownership transfers on success
   --  @param Item Closed Connection that receives ownership
   --  @exception Admission_Closed Manager has started shutdown
   --  @exception Program_Error Socket or Item is invalid, or wake setup fails
   procedure Take
     (Manager : aliased in out Server;
      Socket  : in out Flyology.IO.Sockets.Socket_Type;
      Item    : in out Connection);

   --  Acquire capacity before accepting, so a full Manager backpressures the
   --  listening socket. Transient aborted admissions are retried; descriptor
   --  exhaustion uses interruptible bounded backoff. One Timeout deadline
   --  spans capacity admission, readiness, retries, and backoff. Negative is
   --  unlimited and zero is immediate. Token cancellation and Manager shutdown
   --  interrupt a full-capacity admission wait without polling.
   --  Cancellation_Quantum must be positive for compatibility but is ignored;
   --  wake-source readiness notices cancellation without periodic polling.
   --  Lightweight tasks suspend; native tasks block their threads.
   --  @param Manager Admission controller that must outlive Item
   --  @param Listener Open listening socket; ownership is retained
   --  @param Item Closed Connection that receives the accepted socket
   --  @param Address Accepted peer address
   --  @param Timeout Deadline interval in seconds
   --  @param Cancellation_Quantum Compatibility parameter; value is ignored
   --  @param Token Optional one-shot cancellation source that must outlive
   --     the call
   --  @exception Admission_Closed Manager closes a pending admission
   --  @exception Operation_Cancelled Token interrupts admission; Manager
   --     shutdown or Token interrupts the admitted accept
   --  @exception Timeout_Error The accept deadline expires
   --  @exception Device_Error Readiness polling fails
   --  @exception Flyology.IO.Sockets.Socket_Error Accept or setup fails
   --  @exception Program_Error Item is open or a wake source cannot be created
   procedure Accept_Connection
     (Manager              : aliased in out Server;
      Listener             : Flyology.IO.Sockets.Socket_Type;
      Item                 : in out Connection;
      Address              : out Flyology.IO.Sockets.Endpoint;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   with Pre => Cancellation_Quantum > 0.0;

   --  Cancel and drain the active operation and every registered or queued
   --  caller, close Item's socket, and release its Server permit.
   --  Concurrent Close callers wait for the same close. Closing a closed Item
   --  is harmless.
   --  @param Item Connection whose ownership is released
   --  @exception Flyology.IO.Sockets.Socket_Error The underlying close reports
   --     failure
   --  @exception Flyology.IO.TLS.TLS_Error An upgraded provider session
   --     violates its non-raising finalization contract; cleanup still
   --     completes
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
   --  @exception Operation_Cancelled Shutdown, Token, or Close interrupts a
   --     call that started while Item was open
   --  @exception Timeout_Error The deadline expires
   --  @exception Device_Error Readiness polling fails
   --  @exception Flyology.IO.TLS.TLS_Error An upgraded provider fails or
   --     returns invalid progress
   --  @exception Flyology.IO.Sockets.Socket_Error Receive or setup fails
   --  @exception Program_Error Item is already closed when the call starts,
   --     or a wake source cannot be used
   procedure Receive
     (Item                 : in out Connection;
      Data                 : out Ada.Streams.Stream_Element_Array;
      Last                 : out Ada.Streams.Stream_Element_Offset;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   with Pre => Cancellation_Quantum > 0.0;

   --  Fill Data under one exclusive operation lease and one sequence-wide
   --  deadline. Cancellation and lane behavior match Receive.
   --  @param Item Open connection
   --  @param Data Destination buffer to fill
   --  @param Timeout Deadline interval in seconds
   --  @param Cancellation_Quantum Compatibility parameter; value is ignored
   --  @param Token Optional token that must outlive this call
   --  @exception Operation_Cancelled Shutdown, Token, or Close interrupts a
   --     call that started while Item was open
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Device_Error Polling fails or the peer closes early
   --  @exception Flyology.IO.TLS.TLS_Error An upgraded provider fails, closes
   --     early, or returns invalid progress
   --  @exception Flyology.IO.Sockets.Socket_Error Receive or setup fails
   --  @exception Program_Error Item is already closed when the call starts,
   --     or a wake source cannot be used
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
   --  @exception Operation_Cancelled Shutdown, Token, or Close interrupts a
   --     call that started while Item was open
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Device_Error Polling fails or no forward progress is made
   --  @exception Flyology.IO.TLS.TLS_Error An upgraded provider or peer fails,
   --     or the provider returns invalid progress
   --  @exception Flyology.IO.Sockets.Socket_Error Socket send or setup fails
   --  @exception Program_Error Item is already closed when the call starts,
   --     or a wake source cannot be used
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

   --  Result of a nonblocking lease attempt.
   type Lease_Result is (Lease_Busy, Lease_Acquired, Lease_Cancelled);

   --  Cleanup obligation published by the controller. The caller owns no
   --  controller state while Unregistered, one started-operation count while
   --  Registered, and both that count and the exclusive lease while Acquired.
   type Operation_State is (Unregistered, Registered, Acquired);

   --  Transport replacement occurs under the descriptor operation lease. A
   --  connection never exposes the intermediate state to application I/O.
   type Transport_Kind is
     (No_Transport, Plain_Transport, TLS_Upgrading, TLS_Transport);

   protected type Descriptor_Controller is
      --  Publish descriptor, socket, and admission ownership atomically.
      procedure Adopt
        (FD            : Flyology.IO.Descriptor;
         Socket        : in out Flyology.IO.Sockets.Socket_Type;
         Owner         : Server_Access;
         Cleanup_Armed : not null access Boolean);
      --  Register an open generation before waiting for its exclusive lease.
      --  Close retains the borrowed sources until Try_Acquire, abandonment, or
      --  operation release resolves this registration.
      procedure Start_Operation
        (Generation   : not null access Descriptor_Generation;
         State        : not null access Operation_State;
         Lease_Source : out Flyology.IO.Descriptor;
         Close_Source : out Flyology.IO.Descriptor;
         Owner        : out Server_Access);
      procedure Try_Acquire
        (Expected_Generation : Descriptor_Generation;
         State        : not null access Operation_State;
         Result       : out Lease_Result;
         FD           : out Flyology.IO.Descriptor;
         Close_Source : out Flyology.IO.Descriptor;
         Socket       : in out Flyology.IO.Sockets.Socket_Type;
         Owner        : out Server_Access;
         Transport    : out Transport_Kind);
      --  Withdraw one operation whose lease acquisition did not complete.
      procedure Abandon_Operation (Generation : Descriptor_Generation);
      --  Reject further chunks after Close has marked this leased generation.
      procedure Check_Operation (Generation : Descriptor_Generation);
      --  Replace the plaintext operation generation while retaining the same
      --  descriptor and admission owner. Older queued operations are rejected.
      --  Arm cleanup in the same protected action so abort cannot expose an
      --  upgrading transport without a terminal cleanup obligation.
      procedure Begin_TLS_Upgrade
        (Generation : in out Descriptor_Generation;
         Cleanup_Armed : not null access Boolean);
      procedure Finish_TLS_Upgrade (Generation : Descriptor_Generation);
      procedure Release
        (Generation : Descriptor_Generation;
         Socket     : in out Flyology.IO.Sockets.Socket_Type);
      procedure Begin_Close
        (FD         : out Flyology.IO.Descriptor;
         Generation : out Descriptor_Generation;
         Leader     : out Boolean);
      entry Await_Drained
        (Socket : in out Flyology.IO.Sockets.Socket_Type;
         Owner  : out Server_Access);
      entry Await_Closed;
      procedure Finish_Close (Generation : Descriptor_Generation);
      function Is_Open_State return Boolean;
      --  Private protected snapshots avoid exposing the controller's memory
      --  layout to diagnostic descendants.
      function Waiting_Count return Natural;
      function Lease_Active return Boolean;
      function Close_Pending return Boolean;
   private
      Current_FD         : Flyology.IO.Descriptor := Invalid_Descriptor;
      Current_Generation : Descriptor_Generation := 0;
      Active             : Boolean := False with Atomic;
      Closing            : Boolean := False with Atomic;
      --  Active operation plus callers between Start_Operation and
      --  Try_Acquire.
      Started_Operations : Natural := 0 with Atomic;
      Lease_Signalled    : Boolean := False;
      Lease_Wake         : Flyology.Wake_Sources.Source;
      Close_Wake         : Flyology.Wake_Sources.Source;
      Current_Socket     : Flyology.IO.Sockets.Socket_Type;
      Current_Owner      : Server_Access := null;
      Current_Transport  : Transport_Kind := No_Transport;
   end Descriptor_Controller;

   type Connection is new Ada.Finalization.Limited_Controlled with record
      Controller            : Descriptor_Controller;
      TLS_Session           : Flyology.IO.TLS.Session_Access := null;
      TLS_Shutdown_Complete : Boolean := False;
   end record;

   --  @exclude
   --  Private implementation entry point exported only through the TLS child;
   --  the connection remains the socket and admission owner.
   --  @param Item Admitted connection being upgraded
   --  @param Backend Provider used to create the session
   --  @param Side Client or server handshake role
   --  @param Server_Name Client verification name or empty server name
   --  @param Timeout Shared operation deadline in seconds
   --  @param Token Optional cancellation source
   procedure Upgrade_TLS
     (Item        : in out Connection;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Timeout     : Duration;
      Token       : access Cancellation_Token);

   --  @exclude
   --  @param Item Upgraded admitted connection being shut down
   --  @param Timeout Shared operation deadline in seconds
   --  @param Token Optional cancellation source
   procedure Shutdown_TLS
     (Item    : in out Connection;
      Timeout : Duration;
      Token   : access Cancellation_Token);

   --  Close Item without propagating cleanup errors.
   --  @param Item Connection being finalized
   overriding procedure Finalize (Item : in out Connection);
end Flyology.IO.Connections;
