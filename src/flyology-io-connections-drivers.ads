with Ada.Streams;
private with Ada.Real_Time;
private with Flyology.Wake_Sources;

--  Gives one protocol pump bounded full-duplex access to an admitted
--  connection without exposing its descriptor or transport ownership.
package Flyology.IO.Connections.Drivers is

   --  Scoped capability passed only while Run holds the Connection operation
   --  lease. It cannot be copied or constructed by an application.
   type Capability (<>) is limited private;

   --  Result of one bounded transport step.
   --  @enum Made_Progress At least one byte was transferred, or the input was
   --     empty
   --  @enum Need_Read The next provider or socket step needs read readiness
   --  @enum Need_Write The next provider or socket step needs write readiness
   --  @enum Peer_Closed The peer ended the applicable transport direction
   type Step_Result is
     (Made_Progress, Need_Read, Need_Write, Peer_Closed);

   --  Transport conditions to include in one Wait call. The outbound protocol
   --  wakeup and lifecycle cancellation sources are always included.
   --  @field Readable Observe descriptor read readiness
   --  @field Writable Observe descriptor write readiness
   type Readiness_Interest is record
      Readable : Boolean := True;
      Writable : Boolean := False;
   end record;

   --  Wait for inbound or TLS read progress.
   Read_Interest : constant Readiness_Interest :=
     (Readable => True, Writable => False);
   --  Wait for outbound or TLS write progress.
   Write_Interest : constant Readiness_Interest :=
     (Readable => False, Writable => True);
   --  Wait for both transport directions.
   Duplex_Interest : constant Readiness_Interest :=
     (Readable => True, Writable => True);
   --  Wait only for a protocol wakeup or lifecycle cancellation.
   Protocol_Only : constant Readiness_Interest :=
     (Readable => False, Writable => False);

   --  Reason one capability wait returned.
   --  @enum Transport_Ready One requested descriptor condition is ready
   --  @enum Outbound_Ready A coalesced protocol wakeup was consumed
   --  @enum Wait_Timed_Out The per-wait timeout expired before Run's deadline
   type Wait_Result is
     (Transport_Ready, Outbound_Ready, Wait_Timed_Out);

   --  Thread-safe, reusable protocol-output notification. It owns its wake
   --  descriptor and never exposes it. Signals coalesce until Wait consumes
   --  them. The object must outlive Run and every task that can call Signal.
   type Outbound_Wakeup is limited private;

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
   --  @exception Timeout_Error Flyology.IO.Timeout_Error is raised when Run's
   --     deadline expires
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
   --  @exception Timeout_Error Flyology.IO.Timeout_Error is raised when Run's
   --     deadline expires
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
      procedure Wait_Source
        (FD : out Flyology.IO.Descriptor; Already_Pending : out Boolean);
      procedure Consume;
   private
      Pending   : Boolean := False;
      Signalled : Boolean := False;
      Wake      : Flyology.Wake_Sources.Source;
   end Wakeup_Controller;

   type Outbound_Wakeup is limited record
      Controller : Wakeup_Controller;
   end record;

   type Capability
     (Item  : not null access Connection;
      Token : access Cancellation_Token)
   is limited record
      Guard        : Operation_Guard (Item);
      FD           : Flyology.IO.Descriptor := Invalid_Descriptor;
      Close_Source : Flyology.IO.Descriptor := Invalid_Descriptor;
      Owner        : Server_Access := null;
      Transport    : Transport_Kind := No_Transport;
      Started      : Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Deadline     : Duration := Infinite;
   end record;

end Flyology.IO.Connections.Drivers;
