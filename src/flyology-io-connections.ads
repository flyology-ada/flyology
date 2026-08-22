with Ada.Finalization;
with Ada.Streams;
with Flyology.Capacity;
with Flyology.Cancellation;
with Flyology.IO.Sockets;
with Flyology.Operations;
with Flyology.Wake_Sources;
private with Ada.Real_Time;
private with Flyology.IO.TLS;

--  Adds ownership, admission control, and cancellation to socket connections.
--
--  Example:
--
--     Flyology.IO.Connections.Connect (Manager, Server, Client);
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
   --  transport in place without changing this ownership.
   --
   --  An admitted Connection borrows its Server for as long as it owns a
   --  socket: every operation, Close, and Finalize call into that Server, so
   --  the Server must outlive the Connection. Supply the borrowed Server as
   --  the Manager discriminant to have the compiler enforce that rule
   --
   --     Gate : aliased Flyology.IO.Connections.Server (Capacity => 64);
   --     Item : Flyology.IO.Connections.Connection (Gate'Access);
   --
   --  because an access discriminant may not designate an object of a
   --  shorter-lived scope than the object it discriminates. Take and
   --  Accept_Connection then reject any other Manager. The default null
   --  discriminant keeps older declarations compiling, but leaves the
   --  lifetime rule unchecked: a Connection that outlives the Server it was
   --  admitted through has no defined behavior.
   type Connection
     (Manager : access Server := null)  --  Bound Server, null when unbound
   is new Ada.Finalization.Limited_Controlled with private;

   --  Wait indefinitely for one Manager permit, then transfer Socket to Item.
   --  This compatibility operation has no timeout or cancellation token;
   --  Manager shutdown releases its admission wait with Admission_Closed. On
   --  success Socket is closed and Item is the sole closing owner. If an
   --  unsuccessful transfer releases its permit but admission readiness
   --  signalling fails, the permit remains released and Socket remains owned
   --  by the caller. Ada finalization rules determine the observable exception
   --  occurrence when that cleanup failure accompanies another exception.
   --  @param Manager Admission controller that must outlive Item, and that
   --     must be Item's Manager discriminant when Item has one
   --  @param Socket Open socket whose ownership transfers on success
   --  @param Item Closed Connection that receives ownership
   --  @exception Admission_Closed Manager has started shutdown
   --  @exception Program_Error Socket or Item is invalid, Item is bound to a
   --     different Manager, wake setup fails, or failed-transfer cleanup
   --     releases its permit but cannot signal admission readiness
   procedure Take
     (Manager : aliased in out Server;
      Socket  : in out Flyology.IO.Sockets.Socket_Type;
      Item    : in out Connection);

   --  Reserve one Manager permit, create an Internet stream socket for
   --  Server's address family, connect it, and transfer sole closing ownership
   --  to Item. One monotonic Timeout spans admission, socket creation, and the
   --  task-aware connection attempt. Negative is unlimited and zero is
   --  immediate. Manager shutdown closes a pending admission with
   --  Admission_Closed; after admission, shutdown and Token cancellation
   --  interrupt the connection attempt with Operation_Cancelled. Lightweight
   --  tasks suspend; native tasks block only their pthreads.
   --
   --  On every failure before adoption, cleanup releases the permit and closes
   --  any created socket. If admission readiness signalling fails, the permit
   --  remains released. Ada finalization rules determine the observable
   --  exception occurrence when that cleanup failure accompanies a timeout,
   --  cancellation, socket failure, or another exception.
   --  @param Manager Admission controller that must outlive Item, and that
   --     must be Item's Manager discriminant when Item has one
   --  @param Server Destination endpoint
   --  @param Item Closed Connection that receives the connected socket
   --  @param Timeout Shared admission-and-connect deadline in seconds
   --  @param Token Optional one-shot cancellation source that must outlive
   --     the call
   --  @exception Admission_Closed Manager closes a pending admission
   --  @exception Operation_Cancelled Manager shutdown or Token interrupts an
   --     admitted connection attempt
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Device_Error Readiness polling fails
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     socket creation, connection, or setup fails
   --  @exception Program_Error Item is open, Item is bound to a different
   --     Manager, a wake source cannot be created, or cleanup releases its
   --     permit but cannot signal admission readiness
   procedure Connect
     (Manager : aliased in out Server;
      Server  : Flyology.IO.Sockets.Endpoint;
      Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null);

   --  Opaque build-in-place storage for a managed connect's child operation.
   --  @exclude
   --  @field Owner Completion set shared with the child operation
   type Connect_Operation_State
     (Owner : not null access Flyology.Operations.Completion_Set'Class) is
     limited private;

   --  Scoped managed connection construction. The operation reserves one
   --  Manager permit, owns its temporary socket, and composes the raw socket
   --  connection attempt as a hidden child. It does not borrow a Connection;
   --  typed Finish transfers both resources into a caller-selected closed
   --  target. Manager and Token must outlive the operation.
   --
   --  The parent and its hidden child temporarily consume two completion-set
   --  slots while the socket is connecting. Admission waiting and a retained
   --  successful result consume only the parent's slot.
   --  @field Owner Completion set that owns the parent and hidden child slots
   --  @field State Opaque build-in-place child and ownership storage
   type Connect_Operation
     (Owner : not null access Flyology.Operations.Completion_Set'Class) is
     new Flyology.Operations.Operation (Owner) with record
      State : Connect_Operation_State (Owner);
   end record;

   --  Start one managed connection without suspending the owner task.
   --  @param Set Completion set with room for the parent and hidden child
   --  @param Manager Admission controller that outlives the operation
   --  @param Server Destination endpoint copied into the operation
   --  @param Timeout Shared admission-and-connect deadline in seconds
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited managed connect operation
   function Connect
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Manager : not null access Server;
      Server  : Flyology.IO.Sockets.Endpoint;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null) return Connect_Operation;

   --  Start or restart managed connection construction in an established
   --  operation object.
   --  @param Manager Admission controller that outlives the operation
   --  @param Server Destination endpoint copied into the operation
   --  @param Timeout Shared admission-and-connect deadline in seconds
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed managed connect operation
   procedure Connect
     (Manager   : not null access Server;
      Server    : Flyology.IO.Sockets.Endpoint;
      Timeout   : Duration := Infinite;
      Token     : access Cancellation_Token := null;
      Operation : in out Connect_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Consume a terminal managed connect. On success, transfer the operation's
   --  socket and permit to Item. A mismatched or open Item raises
   --  Program_Error
   --  without consuming the result, so Finish can be retried with a valid
   --  target. Failed and cancelled outcomes leave Item unchanged.
   --  @param Operation Terminal managed connection attempt
   --  @param Item Closed Connection that is unbound or bound to Manager
   --  @exception Admission_Closed Manager closed before admission
   --  @exception Operation_Cancelled Explicit cancellation, Token, or Manager
   --     shutdown interrupted an admitted attempt
   --  @exception Timeout_Error The shared deadline expired
   --  @exception Socket_Error Socket creation or connection failed
   --  @exception Capacity_Error Completion-set child capacity was unavailable
   --  @exception Program_Error Item is open or bound to another Manager, or
   --     cleanup failed
   procedure Finish
     (Operation : in out Connect_Operation;
      Item      : in out Connection'Class);

   --  Acquire capacity before accepting, so a full Manager backpressures the
   --  listening socket. Transient aborted admissions are retried; descriptor
   --  exhaustion uses interruptible bounded backoff. One Timeout deadline
   --  spans capacity admission, readiness, retries, and backoff. Negative is
   --  unlimited and zero is immediate. Token cancellation and Manager shutdown
   --  interrupt a full-capacity admission wait without polling.
   --  Cancellation_Quantum must be positive for compatibility but is ignored;
   --  wake-source readiness notices cancellation without periodic polling.
   --  Lightweight tasks suspend; native tasks block their threads. On failure
   --  after admission, cleanup independently releases the permit and attempts
   --  to close any accepted socket. If admission readiness signalling fails,
   --  the permit remains released. Ada finalization rules determine the
   --  observable exception occurrence when that cleanup failure accompanies
   --  a timeout, cancellation, socket failure, or another exception.
   --  @param Manager Admission controller that must outlive Item, and that
   --     must be Item's Manager discriminant when Item has one
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
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     accept or setup fails
   --  @exception Program_Error Item is open, Item is bound to a different
   --     Manager, a wake source cannot be created, or cleanup releases its
   --     permit but cannot signal admission readiness
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
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     the underlying close reports failure
   --  @exception TLS_Error Flyology.IO.TLS.TLS_Error is raised when an
   --     upgraded provider session violates its non-raising finalization
   --     contract; cleanup still completes
   --  @exception Program_Error The Server permit is released but admission
   --     readiness cannot be signalled
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
   --  @exception TLS_Error Flyology.IO.TLS.TLS_Error is raised when an
   --     upgraded provider fails or returns invalid progress
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     receive or setup fails
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
   --  @exception TLS_Error Flyology.IO.TLS.TLS_Error is raised when an
   --     upgraded provider fails, closes early, or returns invalid progress
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     receive or setup fails
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
   --  @exception TLS_Error Flyology.IO.TLS.TLS_Error is raised when an
   --     upgraded provider or peer fails, or the provider returns invalid
   --     progress
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     socket send or setup fails
   --  @exception Program_Error Item is already closed when the call starts,
   --     or a wake source cannot be used
   procedure Send_All
     (Item                 : in out Connection;
      Data                 : Ada.Streams.Stream_Element_Array;
      Timeout              : Duration := Infinite;
      Cancellation_Quantum : Duration := 0.050;
      Token                : access Cancellation_Token := null)
   with Pre => Cancellation_Quantum > 0.0;

   --  Common limited base for scoped high-level connection I/O. Each
   --  operation retains one generation-checked exclusive connection lease,
   --  transparently driving either the plaintext socket or upgraded TLS
   --  provider. Item, Token, and the borrowed buffer must outlive it. The
   --  owning task must finish or cancel and drain its pending scoped
   --  operations before it calls synchronous Close; Close may wait for those
   --  operations, while only their owner can drive them to completion.
   type Connection_Operation is
     abstract new Flyology.Operations.Operation with private;

   --  Scoped one-chunk plaintext-or-TLS receive.
   type Receive_Operation is new Connection_Operation with private;
   --  Scoped plaintext-or-TLS receive that fills its array.
   type Receive_Exactly_Operation is new Connection_Operation with private;
   --  Scoped plaintext-or-TLS complete send.
   type Send_All_Operation is new Connection_Operation with private;

   --  Start one high-level receive without suspending the owner. The
   --  operation acquires Item's lease asynchronously and borrows Data until
   --  typed Finish or finalization.
   --  @param Set Completion set that owns the operation slot
   --  @param Item Open admitted plaintext or TLS connection
   --  @param Data Aliased destination buffer
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited receive operation
   function Receive
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null) return Receive_Operation;

   --  Start or restart a receive in an established operation object.
   --  @param Item Open admitted plaintext or TLS connection
   --  @param Data Aliased destination buffer
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed receive operation
   procedure Receive
     (Item      : not null access Connection'Class;
      Data      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Cancellation_Token := null;
      Operation : in out Receive_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Start a high-level receive that fills Data.
   --  @param Set Completion set that owns the operation slot
   --  @param Item Open admitted plaintext or TLS connection
   --  @param Data Aliased destination buffer to fill
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited exact-receive operation
   function Receive_Exactly
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null)
      return Receive_Exactly_Operation;

   --  Start or restart an exact receive.
   --  @param Item Open admitted plaintext or TLS connection
   --  @param Data Aliased destination buffer to fill
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed exact-receive operation
   procedure Receive_Exactly
     (Item      : not null access Connection'Class;
      Data      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Cancellation_Token := null;
      Operation : in out Receive_Exactly_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Start a high-level complete send.
   --  @param Set Completion set that owns the operation slot
   --  @param Item Open admitted plaintext or TLS connection
   --  @param Data Aliased source buffer borrowed read-only
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited complete-send operation
   function Send_All
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null) return Send_All_Operation;

   --  Start or restart a complete send.
   --  @param Item Open admitted plaintext or TLS connection
   --  @param Data Aliased source buffer borrowed read-only
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed complete-send operation
   procedure Send_All
     (Item      : not null access Connection'Class;
      Data      : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Cancellation_Token := null;
      Operation : in out Send_All_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Consume a terminal receive and publish the familiar Last result.
   --  @param Operation Terminal receive operation
   --  @param Last Last element received, or Data'First - 1 on peer closure
   procedure Finish
     (Operation : in out Receive_Operation;
      Last      : out Ada.Streams.Stream_Element_Offset);

   --  Consume a terminal exact receive.
   --  @param Operation Terminal exact-receive operation
   procedure Finish (Operation : in out Receive_Exactly_Operation);

   --  Consume a terminal complete send.
   --  @param Operation Terminal send operation
   procedure Finish (Operation : in out Send_All_Operation);

private
   type Connection_Access is access all Connection'Class;
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
         FD           : out Flyology.IO.Descriptor;
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
      procedure Abandon_Operation
        (Generation : Descriptor_Generation;
         State      : not null access Operation_State);
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
         Socket     : in out Flyology.IO.Sockets.Socket_Type;
         State      : not null access Operation_State);
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

   type Connection (Manager : access Server := null) is
     new Ada.Finalization.Limited_Controlled with record
      Controller            : Descriptor_Controller;
      TLS_Session           : Flyology.IO.TLS.Session_Access := null;
      TLS_Shutdown_Complete : Boolean := False;
   end record;

   --  @exclude
   --  @exclude
   --  Scope guard for one generation-checked descriptor operation. Descendant
   --  packages use this to add ownership-preserving capabilities without
   --  exposing the socket or controller publicly.
   type Operation_Guard (Item : not null access Connection) is
     new Ada.Finalization.Limited_Controlled with record
      Generation : aliased Descriptor_Generation := 0;
      State      : aliased Operation_State := Unregistered;
      Socket     : Flyology.IO.Sockets.Socket_Type;
   end record;

   type Scoped_IO_Kind is
     (Receive_One,
      Receive_Complete,
      Send_Complete,
      Upgrade_TLS_Transport);
   type Scoped_IO_Failure is
     (No_Failure,
      State_Failure,
      Socket_Failure,
      TLS_Failure,
      Peer_Closed_Failure,
      No_Progress_Failure,
      Deadline_Failure,
      Cleanup_Failure);
   type Stream_Array_Access is
     access all Ada.Streams.Stream_Element_Array;
   type Constant_Stream_Array_Access is
     access constant Ada.Streams.Stream_Element_Array;
   type Cancellation_Access is access all Cancellation_Token;

   type Pending_Connect_Owner is
     new Ada.Finalization.Limited_Controlled with record
      Manager : Server_Access := null;
      Armed   : aliased Boolean := False;
      Socket  : aliased Flyology.IO.Sockets.Socket_Type;
   end record;

   --  @exclude
   --  @param Item Pending socket and admission owner to release
   overriding procedure Finalize (Item : in out Pending_Connect_Owner);

   type Connect_Phase is
     (Waiting_For_Admission, Waiting_For_Connect, Connection_Ready);
   type Connect_Failure is
     (No_Connect_Failure,
      Admission_Failure,
      Connect_Timeout_Failure,
      Connect_Socket_Failure,
      Connect_Capacity_Failure,
      Connect_State_Failure,
      Connect_Cleanup_Failure);

   type Connect_Operation_State
     (Owner : not null access Flyology.Operations.Completion_Set'Class) is
     limited record
      Resources   : Pending_Connect_Owner;
      Child       : Flyology.IO.Sockets.Connect_Operation (Owner);
      Token       : Cancellation_Access := null;
      Destination : Flyology.IO.Sockets.Endpoint :=
        Flyology.IO.Sockets.No_Endpoint;
      Started     : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Timeout     : Duration := Infinite;
      Phase       : Connect_Phase := Waiting_For_Admission;
      Child_Live  : Boolean := False;
      Cancelling  : Boolean := False;
      Timed_Out   : Boolean := False;
      Failure     : Connect_Failure := No_Connect_Failure;
   end record;

   --  @exclude
   --  @param Item Managed connect operation to advance
   --  @param Event Driver event to process
   overriding procedure Drive
     (Item  : in out Connect_Operation;
      Event : Flyology.Operations.Driver_Event);

   --  @exclude
   --  @param Item Managed connect operation to cancel and drain
   overriding procedure Request_Cancellation
     (Item : in out Connect_Operation);

   --  @exclude
   --  @param Guard Active lease cleanup scope
   overriding procedure Finalize (Guard : in out Operation_Guard);

   --  @exclude
   --  Release or abandon a generation-checked lease immediately. Finalize is
   --  the fallback for synchronous callers and abnormal operation cleanup.
   --  @param Guard Registered or acquired connection lease
   procedure Release_Operation (Guard : in out Operation_Guard);

   --  @exclude
   --  @param Item Connection whose lease is acquired
   --  @param Started Shared deadline start
   --  @param Timeout Shared deadline interval
   --  @param Token Optional cancellation source
   --  @param FD Borrowed active descriptor
   --  @param Guard Scope guard that receives the lease
   --  @param Close_Source Borrowed close wake descriptor
   --  @param Owner Admission owner that must outlive the operation
   --  @param Transport Active plaintext or TLS transport kind
   procedure Acquire_Operation
     (Item          : not null Connection_Access;
      Started       : Ada.Real_Time.Time;
      Timeout       : Duration;
      Token         : access Cancellation_Token;
      FD            : out Flyology.IO.Descriptor;
      Guard         : in out Operation_Guard;
      Close_Source  : out Flyology.IO.Descriptor;
      Owner         : out Server_Access;
      Transport     : out Transport_Kind);

   --  @exclude
   --  @param Item Connection whose generation remains active
   --  @param Generation Expected active generation
   --  @param Owner Admission owner whose shutdown state is checked
   --  @param Token Optional cancellation source
   procedure Check_TLS_Operation
     (Item       : in out Connection;
      Generation : Descriptor_Generation;
      Owner      : not null Server_Access;
      Token      : access Cancellation_Token);

   --  @exclude
   --  @param Started Shared deadline start
   --  @param Timeout Shared deadline interval
   --  @return Remaining deadline interval
   function Remaining
     (Started : Ada.Real_Time.Time;
      Timeout : Duration) return Duration;

   --  @exclude
   --  @param Owner Admission owner supplying shutdown readiness
   --  @param Token Optional cancellation source
   --  @param Sources Borrowed interrupt descriptors
   --  @param Count Number of initialized descriptors
   procedure Interrupt_Sources
     (Owner   : not null Server_Access;
      Token   : access Cancellation_Token;
      Sources : out Flyology.IO.Interrupt_Set;
      Count   : out Natural);

   --  @exclude
   --  Private implementation entry point exported only through the TLS child;
   --  the connection remains the socket and admission owner.
   --  @param Item Admitted connection being upgraded
   --  @param Backend Provider used to create the session
   --  @param Side Client or server handshake role
   --  @param Server_Name Client verification name or empty server name
   --  @param Factory Capability-specific session factory
   --  @param Timeout Shared operation deadline in seconds
   --  @param Token Optional cancellation source
   procedure Upgrade_TLS
     (Item        : in out Connection;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Factory     : not null access function
        (FD : Flyology.IO.Descriptor) return Flyology.IO.TLS.Session_Access;
      Timeout     : Duration;
      Token       : access Cancellation_Token);

   --  @exclude
   --  Query an installed TLS session while holding the connection lease.
   --  @param Item Upgraded admitted connection to inspect
   --  @param Query Session-specific query callback
   --  @return Stable query result copied before releasing the lease
   function Query_TLS_Session
     (Item  : in out Connection;
      Query : not null access function
        (Value : Flyology.IO.TLS.Session'Class) return String) return String;

   --  @exclude
   --  @param Item Upgraded admitted connection being shut down
   --  @param Timeout Shared operation deadline in seconds
   --  @param Token Optional cancellation source
   procedure Shutdown_TLS
     (Item    : in out Connection;
      Timeout : Duration;
      Token   : access Cancellation_Token);

   type Scoped_Operation_Guard is limited record
      Item       : Connection_Access := null;
      Generation : aliased Descriptor_Generation := 0;
      State      : aliased Operation_State := Unregistered;
      Socket     : Flyology.IO.Sockets.Socket_Type;
   end record;

   --  @exclude
   --  Release or abandon the lease retained by a scoped operation.
   --  @param Guard Registered or acquired scoped connection lease
   procedure Release_Operation (Guard : in out Scoped_Operation_Guard);

   type Connection_Operation is
     abstract new Flyology.Operations.Operation with record
      Item                 : Connection_Access := null;
      Token                : Cancellation_Access := null;
      Guard                : Scoped_Operation_Guard;
      Kind                 : Scoped_IO_Kind := Receive_One;
      Data                 : Stream_Array_Access := null;
      Send_Data            : Constant_Stream_Array_Access := null;
      Cursor               : Ada.Streams.Stream_Element_Offset := 1;
      Last                 : Ada.Streams.Stream_Element_Offset := 0;
      Lease_Source         : Descriptor := Invalid_Descriptor;
      Initial_Close_Source : Descriptor := Invalid_Descriptor;
      Close_Source         : Descriptor := Invalid_Descriptor;
      Owner                : Server_Access := null;
      FD                   : Descriptor := Invalid_Descriptor;
      Transport            : Transport_Kind := No_Transport;
      Pending_TLS_Session  : Flyology.IO.TLS.Session_Access := null;
      Upgrade_Started      : aliased Boolean := False;
      Failure              : Scoped_IO_Failure := No_Failure;
   end record;

   --  @exclude
   --  @param Item Connection operation to advance
   --  @param Event Source event that caused the drive
   overriding procedure Drive
     (Item  : in out Connection_Operation;
      Event : Flyology.Operations.Driver_Event);

   --  @exclude
   --  @param Item Connection operation to cancel and release
   overriding procedure Request_Cancellation
     (Item : in out Connection_Operation);

   --  @exclude
   --  Start a high-level TLS upgrade. Factory is invoked synchronously before
   --  this procedure returns, while its captured caller actuals are live.
   --  @param Operation Fresh or consumed upgrade operation
   --  @param Item Open plaintext admitted connection
   --  @param Factory Provider-specific session factory
   --  @param Timeout Shared lease-and-handshake deadline
   --  @param Token Optional cancellation source
   procedure Start_Scoped_TLS_Upgrade
     (Operation : in out Connection_Operation'Class;
      Item      : not null access Connection'Class;
      Factory   : not null access function
        (FD : Flyology.IO.Descriptor) return Flyology.IO.TLS.Session_Access;
      Timeout   : Duration;
      Token     : access Cancellation_Token);

   --  @exclude
   --  Consume a terminal connection-family operation and raise its retained
   --  provider result using the familiar synchronous exception class.
   --  @param Item Terminal connection-family operation
   procedure Finish_Connection_Operation
     (Item : in out Connection_Operation'Class);

   type Receive_Operation is new Connection_Operation with null record;
   type Receive_Exactly_Operation is
     new Connection_Operation with null record;
   type Send_All_Operation is new Connection_Operation with null record;

   --  Close Item without propagating cleanup errors.
   --  @param Item Connection being finalized
   overriding procedure Finalize (Item : in out Connection);
end Flyology.IO.Connections;
