with Ada.Finalization;
with Ada.Streams;
with Flyology.Operations;
private with Ada.Real_Time;
private with Flyology.Wake_Sources;

--  Gives one protocol pump bounded full-duplex access to an admitted
--  connection without exposing its descriptor or transport ownership.

package Flyology.IO.Connections.Drivers is

   --  Set-independent connection driver state. A higher-level protocol may
   --  store one Capability in its concrete transport adapter while its outer
   --  operation owns the only completion-set slot. The capability is limited,
   --  reusable after Release, and allocation-free. It never exposes the
   --  connection descriptor or TLS provider session.
   type Capability is new Ada.Finalization.Limited_Controlled with private;

   --  Result of one nonblocking connection-lease acquisition step.
   --  @enum Acquired The capability may perform transport steps
   --  @enum Need_Acquire_Readiness Arm_Acquisition and retry after wakeup
   type Acquisition_Result is (Acquired, Need_Acquire_Readiness);

   --  Result of one bounded transport step.
   --  @enum Made_Progress At least one byte was transferred, or the input was
   --     empty
   --  @enum Need_Read The next provider or socket step needs read readiness
   --  @enum Need_Write The next provider or socket step needs write readiness
   --  @enum Peer_Closed The peer ended the applicable transport direction
   type Step_Result is (Made_Progress, Need_Read, Need_Write, Peer_Closed);

   --  Transport conditions to include in one Wait call. The outbound protocol
   --  wakeup and lifecycle cancellation sources are always included.
   --  @field Readable Observe descriptor read readiness
   --  @field Writable Observe descriptor write readiness
   type Readiness_Interest is record
      Readable : Boolean := True;
      Writable : Boolean := False;
   end record;

   --  Wait for inbound or TLS read progress.
   Read_Interest   : constant Readiness_Interest := (Readable => True, Writable => False);
   --  Wait for outbound or TLS write progress.
   Write_Interest  : constant Readiness_Interest := (Readable => False, Writable => True);
   --  Wait for both transport directions.
   Duplex_Interest : constant Readiness_Interest := (Readable => True, Writable => True);
   --  Wait only for a protocol wakeup or lifecycle cancellation.
   Protocol_Only   : constant Readiness_Interest := (Readable => False, Writable => False);

   --  Reason one capability wait returned.
   --  @enum Transport_Ready One requested descriptor condition is ready
   --  @enum Outbound_Ready A coalesced protocol wakeup was consumed
   --  @enum Wait_Timed_Out The per-wait timeout expired before Run's deadline
   type Wait_Result is (Transport_Ready, Outbound_Ready, Wait_Timed_Out);

   --  Start borrowing Item for a higher-level operation and attempt its lease
   --  once. Capability must be fresh or released. No wait occurs. Item and
   --  Token remain borrowed until Release or finalization.
   --  @param Item Open admitted plaintext or TLS connection
   --  @param IO Fresh or released set-independent capability
   --  @param Result Immediate lease result
   --  @param Timeout Shared acquisition and transport deadline
   --  @param Token Optional cancellation source that outlives the capability
   --  @exception Operation_Cancelled Shutdown, Token, or Close is active
   --  @exception Socket_Error Socket preparation fails after acquisition
   --  @exception Program_Error IO is active or Item is closed
   procedure Start
     (IO      : in out Capability;
      Item    : not null access Connection'Class;
      Result  : out Acquisition_Result;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null);

   --  Retry one lease acquisition after its armed source becomes ready.
   --  @param IO Started capability awaiting the connection lease
   --  @param Result Immediate lease result
   --  @exception Operation_Cancelled Shutdown, Token, or Close is active
   --  @exception Socket_Error Socket preparation fails after acquisition
   --  @exception Program_Error IO is fresh, released, or already acquired
   procedure Poll_Acquisition (IO : in out Capability; Result : out Acquisition_Result);

   --  Arm the outer provider operation for connection lease availability and
   --  every applicable lifecycle source. The capability owns no set slot.
   --  @param IO Started capability awaiting its lease
   --  @param Operation Outer user-visible provider operation
   --  @exception Program_Error IO is not awaiting acquisition
   procedure Arm_Acquisition (IO : in out Capability; Operation : in out Flyology.Operations.Operation'Class);

   --  Thread-safe, reusable protocol-output notification. It owns its wake
   --  descriptor and never exposes it. Signals coalesce until Wait or the
   --  composable Arm_Transport overload consumes them. The object must outlive
   --  every operation, Run call, and task that can use it.
   type Outbound_Wakeup is limited private;

   --  Arm the outer provider operation for the single readiness direction
   --  returned by Receive or Send, plus close, manager shutdown, and Token.
   --  @param IO Acquired capability
   --  @param Operation Outer user-visible provider operation
   --  @param Required Need_Read or Need_Write returned by a transport step
   --  @exception Program_Error IO is not acquired or Required is not a wait
   procedure Arm_Transport
     (IO : in out Capability; Operation : in out Flyology.Operations.Operation'Class; Required : Step_Result);

   --  Arm the outer provider operation for one transport direction, one
   --  caller-borrowed latched descriptor, close, manager shutdown, and Token
   --  in one bounded readiness set. Arm_Deadline may be used independently on
   --  the same Operation. The caller owns Additional and disarms its borrow
   --  after wakeup before querying or releasing its source again.
   --  @param IO Acquired capability
   --  @param Operation Outer user-visible provider operation
   --  @param Required Need_Read or Need_Write returned by a transport step
   --  @param Additional Valid caller-borrowed latched descriptor
   --  @param Additional_For_Write True to observe Additional write readiness
   --  @exception Program_Error IO is not acquired, Required is not a wait
   --     result, or Additional is invalid
   procedure Arm_Transport
     (IO                   : in out Capability;
      Operation            : in out Flyology.Operations.Operation'Class;
      Required             : Step_Result;
      Additional           : Flyology.IO.Descriptor;
      Additional_For_Write : Boolean);

   --  Arm the outer provider operation for one transport direction, protocol
   --  output publication, close, manager shutdown, and Token in one bounded
   --  readiness set. Outbound remains opaque and consumes no completion-set
   --  slot. If a coalesced output notification is already pending, it is
   --  consumed and Operation is rescheduled instead of armed. Arm_Deadline may
   --  be used independently on the same Operation.
   --  @param IO Acquired capability
   --  @param Operation Outer user-visible provider operation
   --  @param Required Need_Read or Need_Write returned by a transport step
   --  @param Outbound Reusable protocol-output notification
   --  @exception Program_Error IO is not acquired or Required is not a wait
   --     result, or wake descriptor creation or consumption fails
   procedure Arm_Transport
     (IO        : in out Capability;
      Operation : in out Flyology.Operations.Operation'Class;
      Required  : Step_Result;
      Outbound  : in out Outbound_Wakeup);

   --  Arm the outer provider operation for one transport direction, protocol
   --  output publication, one caller-borrowed latched descriptor, close,
   --  manager shutdown, and Token in one bounded readiness set. Outbound
   --  retains its consume-before-reschedule rule; Additional is never consumed
   --  by this call. Arm_Deadline may be used independently on Operation. The
   --  caller owns Additional and disarms its borrow after wakeup before
   --  querying or releasing its source again.
   --  @param IO Acquired capability
   --  @param Operation Outer user-visible provider operation
   --  @param Required Need_Read or Need_Write returned by a transport step
   --  @param Outbound Reusable protocol-output notification
   --  @param Additional Valid caller-borrowed latched descriptor
   --  @param Additional_For_Write True to observe Additional write readiness
   --  @exception Program_Error IO is not acquired, Required is not a wait
   --     result, Additional is invalid, or wake preparation fails
   procedure Arm_Transport
     (IO                   : in out Capability;
      Operation            : in out Flyology.Operations.Operation'Class;
      Required             : Step_Result;
      Outbound             : in out Outbound_Wakeup;
      Additional           : Flyology.IO.Descriptor;
      Additional_For_Write : Boolean);

   --  Arm the outer provider operation with the unused portion of the shared
   --  Start deadline. An infinite deadline adds no timer source.
   --  @param IO Engaged capability
   --  @param Operation Outer user-visible provider operation
   procedure Arm_Deadline (IO : in out Capability; Operation : in out Flyology.Operations.Operation'Class);

   --  Release or abandon the connection lease and every retained borrow. Call
   --  this before publishing the outer operation's terminal outcome. Repeating
   --  Release on a released capability is harmless.
   --  @param IO Capability whose connection borrow is discharged
   procedure Release (IO : in out Capability);

   --  Cancellation has the same ownership transition as Release; the outer
   --  provider chooses and publishes its own terminal cancellation outcome.
   --  @param IO Capability whose connection borrow is discharged
   procedure Cancel (IO : in out Capability) renames Release;

   --  Report whether IO retains a registered or acquired connection borrow.
   --  @param IO Capability to inspect
   --  @return True until Release, Cancel, or finalization completes
   function Is_Engaged (IO : Capability) return Boolean;

   --  Report whether IO currently owns the connection operation lease.
   --  @param IO Capability to inspect
   --  @return True when transport steps are permitted
   function Is_Acquired (IO : Capability) return Boolean;

   --  Publish protocol output availability. Publish the protected queue state
   --  before calling Signal. After Outbound_Ready, the driver must observe all
   --  currently published work before waiting again because signals coalesce.
   --  @param Item Wakeup owned by the protocol driver
   --  @exception Program_Error Wake descriptor creation or signaling fails;
   --     the notification remains pending and a later Wait still observes it
   procedure Signal (Item : in out Outbound_Wakeup);

   --  Attempt one immediate receive step. At most one plaintext socket call or
   --  TLS provider step is made. No readiness wait occurs. Unless Result is
   --  Made_Progress with nonempty Data, Last is one less than Data'First. TLS
   --  may report Need_Write; plaintext reports Need_Read when it would block.
   --  @param Item Active scoped capability
   --  @param Data Destination buffer for one bounded step
   --  @param Last Last element received, or Data'First - 1 without progress
   --  @param Result Progress, required readiness, or orderly peer closure
   --  @exception Operation_Cancelled Shutdown, token cancellation, or Close
   --     interrupts the driver
   --  @exception Timeout_Error Flyology.IO.Timeout_Error is raised when the
   --     shared Start deadline expires
   --  @exception TLS_Error Flyology.IO.TLS.TLS_Error is raised when the TLS
   --     provider fails or reports invalid progress
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     plaintext receive fails
   procedure Receive
     (Item   : in out Capability;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result);

   --  Attempt one immediate send step. At most one plaintext socket call or
   --  TLS provider step is made. No readiness wait occurs. Unless Result is
   --  Made_Progress with nonempty Data, Last is one less than Data'First. TLS
   --  may report Need_Read; plaintext reports Need_Write when it would block.
   --  @param Item Active scoped capability
   --  @param Data Source buffer for one bounded step
   --  @param Last Last element sent, or Data'First - 1 without progress
   --  @param Result Progress, required readiness, or peer closure
   --  @exception Operation_Cancelled Shutdown, token cancellation, or Close
   --     interrupts the driver
   --  @exception Timeout_Error Flyology.IO.Timeout_Error is raised when the
   --     shared Start deadline expires
   --  @exception TLS_Error Flyology.IO.TLS.TLS_Error is raised when the TLS
   --     provider fails or reports invalid progress
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     plaintext send fails
   procedure Send
     (Item   : in out Capability;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result);

   --  Suspend until a requested transport condition or Outbound is ready.
   --  Close, Manager shutdown, and token cancellation wake the call and raise
   --  Operation_Cancelled. Timeout bounds this wait and is also capped by the
   --  shared Run deadline. A negative value waits until either limit; zero is
   --  an immediate poll. Lightweight tasks suspend on their event loop and
   --  native tasks block only their pthread.
   --  @param Item Active scoped capability
   --  @param Outbound Reusable protocol-output notification
   --  @param Interest Transport readiness conditions to observe
   --  @param Timeout Maximum interval for this wait in seconds
   --  @param Result Transport, protocol, or per-wait timeout result
   --  @exception Operation_Cancelled Shutdown, token cancellation, or Close
   --     interrupts the driver
   --  @exception Timeout_Error Flyology.IO.Timeout_Error is raised when Run's
   --     shared deadline expires
   --  @exception Device_Error Flyology.IO.Device_Error is raised when
   --     readiness polling fails
   --  @exception Program_Error Wake descriptor creation or consumption fails
   procedure Wait
     (Item     : in out Capability;
      Outbound : in out Outbound_Wakeup;
      Interest : Readiness_Interest := Read_Interest;
      Timeout  : Duration := Infinite;
      Result   : out Wait_Result);

   --  Hold Item's exclusive operation lease while Process drives both
   --  transport directions through a scoped Capability. One deadline includes
   --  lease acquisition and every capability call. Provider calls and Process
   --  itself are synchronous and are not preempted; expiration is observed at
   --  the next capability boundary. If Process returns, raises, or is aborted,
   --  the socket and admission permit remain owned by Item. Concurrent Close
   --  waits for that restoration before closing the descriptor and releasing
   --  admission. Process is invoked only during Run and must not let an access
   --  to Capability escape.
   --  @param Item Open admitted plaintext or TLS connection
   --  @param Process Protocol pump callback invoked once under the lease
   --  @param Timeout Shared driver deadline in seconds
   --  @param Token Optional one-shot token that must outlive Run
   --  @exception Operation_Cancelled Shutdown, token cancellation, or Close
   --     interrupts lease acquisition or the driver
   --  @exception Timeout_Error Flyology.IO.Timeout_Error is raised when the
   --     shared deadline expires
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     socket preparation fails
   --  @exception Program_Error Item is closed or transport state is invalid
   procedure Run
     (Item    : in out Connection;
      Process : not null access procedure (IO : in out Capability);
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null);

private
   protected type Wakeup_Controller is
      procedure Signal;
      procedure Wait_Source (FD : out Flyology.IO.Descriptor; Already_Pending : out Boolean);
      procedure Consume;
   private
      Pending   : Boolean := False;
      Signalled : Boolean := False;
      Wake      : Flyology.Wake_Sources.Source;
   end Wakeup_Controller;

   type Outbound_Wakeup is limited record
      Controller : Wakeup_Controller;
   end record;

   type Capability is new Ada.Finalization.Limited_Controlled with record
      Item                 : Connection_Access := null;
      Token                : Cancellation_Access := null;
      Guard                : Scoped_Operation_Guard;
      FD                   : Flyology.IO.Descriptor := Invalid_Descriptor;
      Lease_Source         : Flyology.IO.Descriptor := Invalid_Descriptor;
      Initial_Close_Source : Flyology.IO.Descriptor := Invalid_Descriptor;
      Close_Source         : Flyology.IO.Descriptor := Invalid_Descriptor;
      Owner                : Server_Access := null;
      Transport            : Transport_Kind := No_Transport;
      Started              : Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Deadline             : Duration := Infinite;
   end record;

   --  Release an engaged capability during scope finalization.
   --  @exclude
   --  @param IO Capability being finalized
   overriding
   procedure Finalize (IO : in out Capability);

end Flyology.IO.Connections.Drivers;
