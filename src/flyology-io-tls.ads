with Ada.Finalization;
with Ada.Streams;
with Flyology.IO.Sockets;
with Flyology.Cancellation;
with Flyology.Operations;
with Flyology.Wake_Sources;
private with Ada.Real_Time;
private with Ada.Exceptions;

--  Runs provider-neutral TLS sessions over Flyology socket readiness.
--
--  A Connection provides ordinary synchronous Ada operations. Lightweight
--  tasks suspend on WANT_READ or WANT_WRITE; native tasks block their pthread.
--  The selected provider performs TLS and cryptography outside this package.
--
--  Example:
--
--     Take (OpenSSL, Socket, Client, "example.com", Secure);
--     Handshake (Secure, Timeout => 5.0);
package Flyology.IO.TLS is

   --  Raised when a provider rejects configuration, a handshake, a record, or
   --  an alert. Exception messages contain the provider name and diagnostic.
   TLS_Error : exception;

   --  Raised when a token or concurrent Close interrupts an operation.
   Operation_Cancelled : exception renames
     Flyology.Cancellation.Operation_Cancelled;

   --  TLS endpoint role.
   --  @enum Client Initiates a handshake and verifies Server_Name
   --  @enum Server Accepts a handshake using configured credentials
   type Role is (Client, Server);

   --  Result of one nonblocking provider operation.
   --  @enum Complete The operation completed, possibly with transferred bytes
   --  @enum Want_Read Retry after descriptor read readiness
   --  @enum Want_Write Retry after descriptor write readiness
   --  @enum Peer_Closed A valid TLS close_notify was received
   --  @enum Failed The session diagnostic describes a fatal failure
   type Step_Status is
     (Complete, Want_Read, Want_Write, Peer_Closed, Failed);

   --  One provider-owned TLS session. Implementations must not perform a
   --  blocking descriptor operation: every would-block condition is returned
   --  as Want_Read or Want_Write. Operations on one Session are serialized by
   --  Flyology. Finalization must release provider state but must not close
   --  the borrowed descriptor or propagate an exception.
   type Session is abstract new Ada.Finalization.Limited_Controlled with
     null record;
   --  Owning access to one provider session; Flyology deallocates it after the
   --  active operation has drained and before closing the socket.
   type Session_Access is access all Session'Class;

   --  Execute one handshake step. Complete finishes the handshake; Want_Read
   --  and Want_Write request readiness; Failed supplies a provider diagnostic;
   --  Peer_Closed reports that the peer closed before completion.
   --  @param Item Session to advance
   --  @return Provider progress state
   function Handshake_Step
     (Item : in out Session) return Step_Status is abstract;

   --  Execute one decrypted receive step. All Step_Status values are valid.
   --  Complete must return at least one byte; Peer_Closed represents
   --  close_notify. Want_Read, Want_Write, Peer_Closed, and Failed consume no
   --  buffer and leave Last unchanged.
   --  @param Item Session to read
   --  @param Data Destination buffer
   --  @param Last Last element produced, if any
   --  @return Provider progress state
   function Receive_Step
     (Item : in out Session;
      Data : out Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return Step_Status
   is abstract;

   --  Execute one encrypted send step. All Step_Status values are valid;
   --  Peer_Closed means the peer closed before the send completed. Complete
   --  consumes at least one byte. Want_Read, Want_Write, Peer_Closed, and
   --  Failed consume no bytes, leave Last unchanged, and require the identical
   --  Data slice on retry.
   --  @param Item Session to write
   --  @param Data Source buffer
   --  @param Last Last element consumed, if any
   --  @return Provider progress state
   function Send_Step
     (Item : in out Session;
      Data : Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return Step_Status
   is abstract;

   --  Execute one bidirectional close_notify step. Complete finishes shutdown;
   --  Want_Read and Want_Write request readiness; Failed supplies a provider
   --  diagnostic; Peer_Closed reports transport closure before the TLS
   --  shutdown completed.
   --  @param Item Session to shut down
   --  @return Provider progress state
   function Shutdown_Step
     (Item : in out Session) return Step_Status is abstract;

   --  Return the diagnostic for the most recent Failed result. The returned
   --  String owns its Ada value and remains valid across later provider calls.
   --  @param Item Failed session
   --  @return Provider-specific diagnostic
   function Error_Message (Item : Session) return String is abstract;

   --  Factory for provider sessions. Provider objects are initialized once and
   --  may create sessions concurrently. Provider finalization must serialize
   --  with Name, Is_Available, and Create_Session. A created Session must
   --  remain usable after the Provider object is finalized. Create_Session
   --  initializes protocol state but must not perform network I/O; descriptor
   --  operations begin only through the step functions after Take succeeds.
   type Provider is limited interface;

   --  Owning provider reference. Retain creates an independent reference that
   --  remains usable after the original provider object is finalized. Release
   --  finalizes and deallocates it.
   type Provider_Access is access all Provider'Class;

   --  Retain independently owned provider configuration and code state.
   --  @param Item Initialized provider to retain
   --  @return Owning provider reference
   --  @exception TLS_Error Provider is unavailable or cannot be retained
   function Retain (Item : in out Provider) return Provider_Access is abstract;

   --  Finalize and clear an owning provider reference. A null reference is
   --  accepted.
   --  @param Item Owning reference to release
   procedure Release (Item : in out Provider_Access);

   --  Return a short stable provider name for diagnostics.
   --  @param Item Provider to identify
   --  @return Provider name
   function Name (Item : Provider) return String is abstract;

   --  Report whether provider code and configuration are ready for sessions.
   --  @param Item Provider to inspect
   --  @return True when Create_Session can be attempted
   function Is_Available (Item : Provider) return Boolean is abstract;

   --  Create a nonblocking session borrowing FD. A client implementation must
   --  apply Server_Name to both SNI and certificate hostname verification.
   --  The session does not own or close FD. This factory must not perform
   --  network I/O or depend on FD already being in nonblocking mode.
   --  @param Item Initialized provider
   --  @param FD Borrowed connected descriptor
   --  @param Side Client or server role
   --  @param Server_Name Verified DNS name for clients; empty for servers
   --  @return Newly allocated provider session
   --  @exception TLS_Error Provider setup fails
   function Create_Session
     (Item        : in out Provider;
      FD          : Descriptor;
      Side        : Role;
      Server_Name : String) return Session_Access is abstract;

   --  Sole closing owner of one connected socket and one provider session.
   --  Take transfers ownership. Finalize calls Close. Handshake, Receive,
   --  Send_All, and Shutdown are serialized. Close may run concurrently: it
   --  wakes the active operation, waits for it to release provider state,
   --  destroys the TLS session, then closes the descriptor. Other concurrent
   --  operations wait their turn. Take is the only non-concurrent operation:
   --  callers must give it exclusive access to a closed Connection.
   --  Operations queued behind an active provider call wait on the retained
   --  lease source and preserve their original monotonic deadline.
   type Connection is new Ada.Finalization.Limited_Controlled with private;

   --  Create a provider session and transfer Socket's sole closing ownership
   --  to Item. Socket becomes closed only after successful setup. Client
   --  sessions require a nonempty Server_Name so providers can perform SNI and
   --  hostname verification. Provider libraries are selected by Backend and
   --  may differ between connections. If setup fails, Socket keeps ownership,
   --  but its descriptor may already have been changed to nonblocking mode.
   --  The transfer is atomic with respect to task abort: an abort delivered
   --  during it leaves either Item owning both the session and the socket or
   --  Socket keeping ownership with no provider session left behind.
   --  Take must not run concurrently with any other operation on Item.
   --  @param Backend Initialized TLS provider
   --  @param Socket Connected socket transferred on success
   --  @param Side Client or server handshake role
   --  @param Server_Name DNS name verified by a client; empty for a server
   --  @param Item Closed connection that receives the socket and session
   --  @exception TLS_Error Provider setup fails or Backend is unavailable
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     preparing socket mode fails
   --  @exception Program_Error Item is open, Socket is invalid, or arguments
   --     do not match Side
   procedure Take
     (Backend     : in out Provider'Class;
      Socket      : in out Flyology.IO.Sockets.Socket_Type;
      Side        : Role;
      Server_Name : String;
      Item        : in out Connection);

   --  Complete the TLS handshake. Negative Timeout means no limit and zero is
   --  an immediate poll. One monotonic deadline spans every provider retry.
   --  A lightweight caller suspends its task; a native caller blocks its
   --  pthread. Cancellation never destroys a session until the provider call
   --  has returned.
   --  @param Item Open TLS connection
   --  @param Timeout Shared handshake deadline in seconds
   --  @param Token Optional one-shot token that must outlive this call
   --  @exception Operation_Cancelled Token or concurrent Close interrupts
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Device_Error Readiness polling fails
   --  @exception TLS_Error The provider rejects the handshake or peer
   --  @exception Program_Error Item is closed
   procedure Handshake
     (Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null);

   --  Receive one decrypted chunk. Last is Data'First - 1 after an orderly
   --  close_notify. One deadline spans WANT_READ and WANT_WRITE retries.
   --  Lane, cancellation, and serialization behavior match Handshake.
   --  @param Item Handshaken TLS connection
   --  @param Data Destination buffer
   --  @param Last Last element received, or Data'First - 1 on close_notify
   --  @param Timeout Shared operation deadline in seconds
   --  @param Token Optional one-shot token that must outlive this call
   --  @exception Operation_Cancelled Token or concurrent Close interrupts
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Device_Error Readiness polling fails
   --  @exception TLS_Error The provider reports protocol or transport failure
   --  @exception Program_Error Item is closed
   procedure Receive
     (Item    : in out Connection;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null);

   --  Fill Data under one deadline. An orderly close before Data is full is a
   --  TLS_Error. Lane and cancellation behavior match Handshake.
   --  @param Item Handshaken TLS connection
   --  @param Data Destination buffer to fill
   --  @param Timeout Shared sequence deadline in seconds
   --  @param Token Optional one-shot token that must outlive this call
   --  @exception Operation_Cancelled Token or concurrent Close interrupts
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Device_Error Readiness polling fails
   --  @exception TLS_Error The peer closes early or the provider fails
   --  @exception Program_Error Item is closed
   procedure Receive_Exactly
     (Item    : in out Connection;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null);

   --  Encrypt and send all Data under one deadline. Partial provider progress
   --  and all WANT retries share that deadline. Lane, cancellation, and
   --  serialization behavior match Handshake.
   --  @param Item Handshaken TLS connection
   --  @param Data Source buffer sent completely
   --  @param Timeout Shared sequence deadline in seconds
   --  @param Token Optional one-shot token that must outlive this call
   --  @exception Operation_Cancelled Token or concurrent Close interrupts
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Device_Error Readiness polling fails
   --  @exception TLS_Error The provider or peer fails
   --  @exception Program_Error Item is closed
   procedure Send_All
     (Item    : in out Connection;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null);

   --  Exchange TLS close_notify alerts without closing the owned socket. One
   --  deadline spans the complete bidirectional shutdown and all WANT retries.
   --  A peer transport close without close_notify raises TLS_Error. Repeating
   --  Shutdown after success is harmless.
   --  @param Item Open TLS connection
   --  @param Timeout Shared shutdown deadline in seconds
   --  @param Token Optional one-shot token that must outlive this call
   --  @exception Operation_Cancelled Token or concurrent Close interrupts
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Device_Error Readiness polling fails
   --  @exception TLS_Error The provider or peer fails shutdown
   --  @exception Program_Error Item is closed
   procedure Shutdown
     (Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null);

   --  Common limited base for scoped standalone TLS operations. Item, Token,
   --  and any borrowed buffer must outlive the operation through terminal
   --  completion or finalization. The owning task must cancel or finalize its
   --  pending operations before calling Close itself; a concurrent Close may
   --  interrupt them and waits until their leases are discharged.
   type Connection_Operation is
     abstract new Flyology.Operations.Operation with private;
   --  Scoped standalone TLS handshake result.
   type Handshake_Operation is new Connection_Operation with private;
   --  Scoped one-chunk decrypted receive result.
   type Receive_Operation is new Connection_Operation with private;
   --  Scoped exact decrypted receive result.
   type Receive_Exactly_Operation is new Connection_Operation with private;
   --  Scoped complete encrypted send result.
   type Send_All_Operation is new Connection_Operation with private;
   --  Scoped close-notify exchange result.
   type Shutdown_Operation is new Connection_Operation with private;

   --  Start a composable TLS handshake.
   --  @param Set Completion set owning the operation slot
   --  @param Item Open standalone TLS connection
   --  @param Timeout Shared lease-and-handshake deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited handshake operation
   function Handshake
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
      return Handshake_Operation;

   --  Start or restart a handshake operation.
   --  @param Item Open standalone TLS connection
   --  @param Timeout Shared lease-and-handshake deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed operation
   procedure Handshake
     (Item      : not null access Connection'Class;
      Timeout   : Duration := Infinite;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Handshake_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Start a composable one-chunk decrypted receive.
   --  @param Set Completion set owning the operation slot
   --  @param Item Open standalone TLS connection
   --  @param Data Aliased destination borrowed through completion
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited receive operation
   function Receive
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
      return Receive_Operation;

   --  Start or restart a one-chunk receive operation.
   --  @param Item Open standalone TLS connection
   --  @param Data Aliased destination borrowed through completion
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed operation
   procedure Receive
     (Item      : not null access Connection'Class;
      Data      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Receive_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Start a composable receive that fills Data.
   --  @param Set Completion set owning the operation slot
   --  @param Item Open standalone TLS connection
   --  @param Data Aliased destination borrowed through completion
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited exact-receive operation
   function Receive_Exactly
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
      return Receive_Exactly_Operation;

   --  Start or restart an exact-receive operation.
   --  @param Item Open standalone TLS connection
   --  @param Data Aliased destination borrowed through completion
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed operation
   procedure Receive_Exactly
     (Item      : not null access Connection'Class;
      Data      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Receive_Exactly_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Start a composable complete encrypted send.
   --  @param Set Completion set owning the operation slot
   --  @param Item Open standalone TLS connection
   --  @param Data Aliased source borrowed read-only through completion
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited complete-send operation
   function Send_All
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Data    : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
      return Send_All_Operation;

   --  Start or restart a complete-send operation.
   --  @param Item Open standalone TLS connection
   --  @param Data Aliased source borrowed read-only through completion
   --  @param Timeout Shared lease-and-I/O deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed operation
   procedure Send_All
     (Item      : not null access Connection'Class;
      Data      : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Infinite;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Send_All_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Start a composable TLS close-notify exchange.
   --  @param Set Completion set owning the operation slot
   --  @param Item Open standalone TLS connection
   --  @param Timeout Shared lease-and-shutdown deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @return Started limited shutdown operation
   function Shutdown
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : not null access Connection'Class;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null)
      return Shutdown_Operation;

   --  Start or restart a shutdown operation.
   --  @param Item Open standalone TLS connection
   --  @param Timeout Shared lease-and-shutdown deadline
   --  @param Token Optional cancellation source that outlives the operation
   --  @param Operation Fresh, released, or consumed operation
   procedure Shutdown
     (Item      : not null access Connection'Class;
      Timeout   : Duration := Infinite;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Shutdown_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Consume a terminal handshake operation.
   --  @param Operation Terminal handshake operation
   procedure Finish (Operation : in out Handshake_Operation);
   --  Consume a terminal receive and publish Last.
   --  @param Operation Terminal receive operation
   --  @param Last Last element received, or Data'First - 1 on close-notify
   procedure Finish
     (Operation : in out Receive_Operation;
      Last      : out Ada.Streams.Stream_Element_Offset);
   --  Consume a terminal exact-receive operation.
   --  @param Operation Terminal exact-receive operation
   procedure Finish (Operation : in out Receive_Exactly_Operation);
   --  Consume a terminal complete-send operation.
   --  @param Operation Terminal complete-send operation
   procedure Finish (Operation : in out Send_All_Operation);
   --  Consume a terminal shutdown operation.
   --  @param Operation Terminal shutdown operation
   procedure Finish (Operation : in out Shutdown_Operation);

   --  Cancel an active operation, destroy provider state, and close the
   --  socket.
   --  Provider state is destroyed before the descriptor. Concurrent callers
   --  wait for the same close. Closing a closed Item is harmless.
   --  @param Item Connection whose ownership is released
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     the descriptor close fails
   --  @exception TLS_Error A downstream session violates the non-raising
   --     finalization contract; descriptor cleanup still completes
   --  @exception Program_Error Internal controller cleanup fails after the
   --     connection has been made unusable
   procedure Close (Item : in out Connection);

   --  Report whether Item owns a session and descriptor and is not closing.
   --  @param Item Connection to inspect
   --  @return True while Item is usable
   function Is_Open (Item : Connection) return Boolean;

private
   --  Child capabilities use these callbacks to share the connection
   --  ownership and serialization machinery without extending Provider's
   --  required primitive set.
   --  @exclude
   --  @param Backend Provider used for validation and diagnostics
   --  @param Socket Connected socket transferred on success
   --  @param Side Client or server handshake role
   --  @param Server_Name Client verification name or empty server name
   --  @param Factory Capability-specific session factory
   --  @param Item Closed connection receiving the session
   procedure Take_With_Factory
     (Backend     : in out Provider'Class;
      Socket      : in out Flyology.IO.Sockets.Socket_Type;
      Side        : Role;
      Server_Name : String;
      Factory     : not null access function
        (FD : Descriptor) return Session_Access;
      Item        : in out Connection);

   --  @exclude
   --  @param Item Open connection whose session is queried
   --  @param Query Capability-specific session query
   --  @return Stable query result copied under operation serialization
   function Query_Session
     (Item  : in out Connection;
      Query : not null access function
        (Value : Session'Class) return String) return String;

   type Descriptor_Generation is mod 2 ** 64;
   --  Distinguish a busy lease from acquisition and lifecycle cancellation.
   type Lease_Result is (Lease_Busy, Lease_Acquired, Lease_Cancelled);
   type Operation_State is (Unregistered, Registered, Acquired);

   protected type Descriptor_Controller is
      procedure Adopt (FD : Descriptor);
      procedure Start_Operation
        (Generation   : not null access Descriptor_Generation;
         State        : not null access Operation_State;
         FD           : out Descriptor;
         Lease_Source : out Descriptor;
         Close_Source : out Descriptor);
      procedure Try_Acquire
        (Expected_Generation : Descriptor_Generation;
         State               : not null access Operation_State;
         Result              : out Lease_Result;
         FD                  : in out Descriptor;
         Close_Source        : in out Descriptor);
      procedure Abandon_Operation
        (Generation : Descriptor_Generation;
         State      : not null access Operation_State);
      procedure Check_Operation (Generation : Descriptor_Generation);
      procedure Release
        (Generation : Descriptor_Generation;
         State      : not null access Operation_State);
      procedure Begin_Close
        (FD         : out Descriptor;
         Generation : out Descriptor_Generation;
         Leader     : out Boolean);
      entry Await_Drained;
      entry Await_Closed;
      procedure Finish_Close (Generation : Descriptor_Generation);
      --  Snapshot connection state at an operation's public call boundary.
      function Is_Open_State return Boolean;
      function Close_Requested return Boolean;
   private
      Current_FD         : Descriptor := Invalid_Descriptor;
      Current_Generation : Descriptor_Generation := 0;
      Active             : Boolean := False;
      Close_In_Progress  : Boolean := False;
      Started_Operations : Natural := 0;
      Lease_Signalled    : Boolean := False;
      Lease_Wake         : Flyology.Wake_Sources.Source;
      Close_Wake         : Flyology.Wake_Sources.Source;
   end Descriptor_Controller;

   type Connection is new Ada.Finalization.Limited_Controlled with record
      Socket     : Flyology.IO.Sockets.Socket_Type;
      Session    : Session_Access := null;
      Controller : Descriptor_Controller;
   end record;

   type Connection_Access is access all Connection'Class;

   type Operation_Guard is new Ada.Finalization.Limited_Controlled with record
      Item       : Connection_Access := null;
      Generation : aliased Descriptor_Generation := 0;
      State      : aliased Operation_State := Unregistered;
   end record;

   --  @exclude
   --  @param Guard Internal lease guard
   procedure Release_Operation (Guard : in out Operation_Guard);
   --  @exclude
   --  @param Guard Internal lease guard
   overriding procedure Finalize (Guard : in out Operation_Guard);

   type Cancellation_Access is access all Flyology.Cancellation.Token;

   type Driver_State is limited record
      Item         : Connection_Access := null;
      Token        : Cancellation_Access := null;
      Guard        : Operation_Guard;
      FD           : Descriptor := Invalid_Descriptor;
      Lease_Source : Descriptor := Invalid_Descriptor;
      Close_Source : Descriptor := Invalid_Descriptor;
      Started      : Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Deadline     : Duration := Infinite;
   end record;

   --  @exclude
   --  @param State Internal driver state
   --  @param Item Borrowed TLS connection
   --  @param Result Initial lease result
   --  @param Timeout Shared operation deadline
   --  @param Token Optional cancellation token
   procedure Start_Driver
     (State   : in out Driver_State;
      Item    : not null access Connection'Class;
      Result  : out Lease_Result;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);
   --  @exclude
   --  @param State Internal driver state
   --  @param Result Lease retry result
   procedure Poll_Driver
     (State  : in out Driver_State;
      Result : out Lease_Result);
   --  @exclude
   --  @param State Internal driver state
   procedure Check_Driver (State : in out Driver_State);
   --  @exclude
   --  @param State Internal driver state
   procedure Release_Driver (State : in out Driver_State);
   --  @exclude
   --  @param State Internal driver state
   --  @return Unused portion of the shared deadline
   function Driver_Remaining (State : Driver_State) return Duration;
   --  @exclude
   --  @param State Internal driver state
   --  @param Operation Outer operation to arm
   procedure Arm_Driver_Acquisition
     (State     : in out Driver_State;
      Operation : in out Flyology.Operations.Operation'Class);
   --  @exclude
   --  @param State Internal driver state
   --  @param Operation Outer operation to arm
   --  @param Status Provider readiness direction
   procedure Arm_Driver_Transport
     (State     : in out Driver_State;
      Operation : in out Flyology.Operations.Operation'Class;
      Status    : Step_Status);
   --  @exclude
   --  @param State Internal driver state
   --  @param Operation Outer operation to arm
   procedure Arm_Driver_Deadline
     (State     : in out Driver_State;
      Operation : in out Flyology.Operations.Operation'Class);

   type Scoped_TLS_Kind is
     (Handshake_IO,
      Receive_One,
      Receive_Complete,
      Send_Complete,
      Shutdown_IO);
   type Stream_Array_Access is access all
     Ada.Streams.Stream_Element_Array;
   type Constant_Stream_Array_Access is access constant
     Ada.Streams.Stream_Element_Array;

   type Connection_Operation is
     abstract new Flyology.Operations.Operation with record
      State       : Driver_State;
      Kind        : Scoped_TLS_Kind := Handshake_IO;
      Data        : Stream_Array_Access := null;
      Send_Data   : Constant_Stream_Array_Access := null;
      Cursor      : Ada.Streams.Stream_Element_Offset := 1;
      Last        : Ada.Streams.Stream_Element_Offset := 0;
      Has_Failure : Boolean := False;
      Failure     : Ada.Exceptions.Exception_Occurrence;
   end record;

   --  @exclude
   --  @param Item Internal scoped TLS operation
   --  @param Event Driver event to process
   overriding procedure Drive
     (Item  : in out Connection_Operation;
      Event : Flyology.Operations.Driver_Event);
   --  @exclude
   --  @param Item Internal scoped TLS operation
   overriding procedure Request_Cancellation
     (Item : in out Connection_Operation);

   type Handshake_Operation is new Connection_Operation with null record;
   type Receive_Operation is new Connection_Operation with null record;
   type Receive_Exactly_Operation is
     new Connection_Operation with null record;
   type Send_All_Operation is new Connection_Operation with null record;
   type Shutdown_Operation is new Connection_Operation with null record;

   --  Close Item without propagating finalization errors.
   --  @param Item Connection being finalized
   overriding procedure Finalize (Item : in out Connection);
end Flyology.IO.TLS;
