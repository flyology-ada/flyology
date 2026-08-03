with Ada.Finalization;
with Ada.Streams;
with GNAT.Sockets;
with Flyology.Cancellation;
with Flyology.Wake_Sources;

--  Runs provider-neutral TLS sessions over Flyology socket readiness.
--
--  A Connection is an ordinary blocking-looking Ada object. Lightweight tasks
--  suspend on WANT_READ or WANT_WRITE; native tasks block their pthread. The
--  selected provider performs TLS and cryptography outside this package.
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

   --  Execute one handshake step.
   --  @param Item Session to advance
   --  @return Provider progress state
   function Handshake_Step
     (Item : in out Session) return Step_Status is abstract;

   --  Execute one decrypted receive step. Complete must return at least one
   --  byte; Peer_Closed represents close_notify. Want_Read, Want_Write,
   --  Peer_Closed, and Failed consume no buffer and leave Last unchanged.
   --  @param Item Session to read
   --  @param Data Destination buffer
   --  @param Last Last element produced, if any
   --  @return Provider progress state
   function Receive_Step
     (Item : in out Session;
      Data : out Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return Step_Status
   is abstract;

   --  Execute one encrypted send step. Complete consumes at least one byte.
   --  Want_Read, Want_Write, Peer_Closed, and Failed consume no bytes, leave
   --  Last unchanged, and require the identical Data slice on retry.
   --  @param Item Session to write
   --  @param Data Source buffer
   --  @param Last Last element consumed, if any
   --  @return Provider progress state
   function Send_Step
     (Item : in out Session;
      Data : Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return Step_Status
   is abstract;

   --  Execute one bidirectional close_notify step.
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
   --  Operations queued behind an active provider call recheck cancellation
   --  and their original deadline at intervals of at most 10 milliseconds.
   type Connection is new Ada.Finalization.Limited_Controlled with private;

   --  Create a provider session and transfer Socket's sole closing ownership
   --  to Item. Socket becomes No_Socket only after successful setup. Client
   --  sessions require a nonempty Server_Name so providers can perform SNI and
   --  hostname verification. Provider libraries are selected by Backend and
   --  may differ between connections. If setup fails, Socket keeps ownership,
   --  but its descriptor may already have been changed to nonblocking mode.
   --  Take must not run concurrently with any other operation on Item.
   --  @param Backend Initialized TLS provider
   --  @param Socket Connected socket transferred on success
   --  @param Side Client or server handshake role
   --  @param Server_Name DNS name verified by a client; empty for a server
   --  @param Item Closed connection that receives the socket and session
   --  @exception TLS_Error Provider setup fails or Backend is unavailable
   --  @exception Program_Error Item is open, Socket is invalid, or arguments
   --     do not match Side
   procedure Take
     (Backend     : in out Provider'Class;
      Socket      : in out GNAT.Sockets.Socket_Type;
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

   --  Cancel an active operation, destroy provider state, and close the
   --  socket.
   --  Provider state is destroyed before the descriptor. Concurrent callers
   --  wait for the same close. Closing a closed Item is harmless.
   --  @param Item Connection whose ownership is released
   --  @exception GNAT.Sockets.Socket_Error The descriptor close fails
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
   type Descriptor_Generation is mod 2 ** 64;
   --  Distinguish successful serialization from a close observed at the gate.
   type Acquire_Result is (Acquired, Closing, Closed, Replaced);

   protected type Descriptor_Controller is
      procedure Adopt (FD : Descriptor);
      entry Acquire
        (Expected     : Descriptor_Generation;
         FD           : out Descriptor;
         Generation   : not null access Descriptor_Generation;
         Armed        : not null access Boolean;
         Close_Source : out Descriptor;
         Result       : out Acquire_Result);
      procedure Release (Generation : Descriptor_Generation);
      procedure Begin_Close
        (FD         : out Descriptor;
         Generation : out Descriptor_Generation;
         Leader     : out Boolean);
      entry Await_Drained;
      entry Await_Closed;
      procedure Finish_Close (Generation : Descriptor_Generation);
      --  Snapshot connection state at an operation's public call boundary.
      procedure Snapshot_Acquisition
        (State      : out Acquire_Result;
         Generation : out Descriptor_Generation);
      function Is_Open_State return Boolean;
      function Close_Requested return Boolean;
      function Operation_Is_Active return Boolean;
      function Queued_Acquisitions return Natural;
      function Close_Is_In_Progress return Boolean;
      function Generation_State return Descriptor_Generation;
   private
      Current_FD         : Descriptor := Invalid_Descriptor;
      Current_Generation : Descriptor_Generation := 0;
      Active             : Boolean := False;
      Close_In_Progress  : Boolean := False;
      Close_Wake         : Flyology.Wake_Sources.Source;
   end Descriptor_Controller;

   type Connection is new Ada.Finalization.Limited_Controlled with record
      Socket     : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Session    : Session_Access := null;
      Controller : Descriptor_Controller;
   end record;

   --  Close Item without propagating finalization errors.
   --  @param Item Connection being finalized
   overriding procedure Finalize (Item : in out Connection);
end Flyology.IO.TLS;
