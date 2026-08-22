with Ada.Finalization;
with Ada.Streams;
with Flyology.Operations;

--  Bounded, set-independent access to one standalone TLS connection lease.
--  Higher-level protocol operations store a Capability while owning the only
--  completion-set slot themselves.
package Flyology.IO.TLS.Drivers is

   --  Set-independent standalone TLS driver state. A higher-level protocol
   --  may store one Capability while its outer operation owns the only
   --  completion-set slot. The capability is limited, reusable after Release,
   --  and allocation-free. It never exposes the descriptor or provider
   --  session.
   type Capability is new Ada.Finalization.Limited_Controlled with private;

   --  Result of one nonblocking TLS connection-lease acquisition step.
   --  @enum Acquired The capability may perform provider steps
   --  @enum Need_Acquire_Readiness Arm_Acquisition and retry after wakeup
   type Acquisition_Result is (Acquired, Need_Acquire_Readiness);

   --  Result of one bounded TLS provider step.
   --  @enum Made_Progress The provider advanced or completed the operation
   --  @enum Need_Read The next provider step needs descriptor read readiness
   --  @enum Need_Write The next provider step needs descriptor write readiness
   --  @enum Peer_Closed The peer ended the applicable TLS direction
   type Step_Result is
     (Made_Progress, Need_Read, Need_Write, Peer_Closed);

   --  Register Item and attempt its exclusive provider lease once. Item and
   --  Token remain borrowed until Release or finalization.
   --  @param IO Fresh or released set-independent capability
   --  @param Item Open standalone TLS connection
   --  @param Result Immediate lease result
   --  @param Timeout Shared acquisition and provider deadline
   --  @param Token Optional cancellation source that outlives the capability
   --  @exception Operation_Cancelled Token or Close is active
   --  @exception Timeout_Error The lease is busy at the shared deadline
   --  @exception Program_Error IO is active or Item is closed
   procedure Start
     (IO      : in out Capability;
      Item    : not null access Connection'Class;
      Result  : out Acquisition_Result;
      Timeout : Duration := Infinite;
      Token   : access Flyology.Cancellation.Token := null);

   --  Retry one lease acquisition after Arm_Acquisition becomes ready.
   --  @param IO Started capability awaiting the TLS connection lease
   --  @param Result Immediate lease result
   --  @exception Operation_Cancelled Token or Close is active
   --  @exception Timeout_Error The lease remains busy at the shared deadline
   --  @exception Program_Error IO is fresh, released, or already acquired
   procedure Poll_Acquisition
     (IO     : in out Capability;
      Result : out Acquisition_Result);

   --  Arm an outer operation for lease availability, close, and cancellation.
   --  @param IO Started capability awaiting its lease
   --  @param Operation Outer user-visible provider operation
   --  @exception Program_Error IO is not awaiting acquisition
   procedure Arm_Acquisition
     (IO        : in out Capability;
      Operation : in out Flyology.Operations.Operation'Class);

   --  Arm an outer operation for the readiness direction returned by a step,
   --  plus close and cancellation.
   --  @param IO Acquired capability
   --  @param Operation Outer user-visible provider operation
   --  @param Required Need_Read or Need_Write returned by a provider step
   --  @exception Program_Error IO is not acquired or Required is not a wait
   procedure Arm_Transport
     (IO        : in out Capability;
      Operation : in out Flyology.Operations.Operation'Class;
      Required  : Step_Result);

   --  Add the unused portion of Start's shared deadline to an outer operation.
   --  A higher-level provider must call this once after Start; provider steps
   --  themselves do not inspect time because the outer operation owns the
   --  Deadline_Reached transition.
   --  @param IO Engaged capability
   --  @param Operation Outer user-visible provider operation
   procedure Arm_Deadline
     (IO        : in out Capability;
      Operation : in out Flyology.Operations.Operation'Class);

   --  Perform one bounded provider handshake step.
   --  @param IO Acquired capability
   --  @param Result Progress, required readiness, or peer closure
   --  @exception Operation_Cancelled Token or Close interrupts the driver
   --  @exception TLS_Error The provider fails or reports invalid progress
   procedure Handshake
     (IO     : in out Capability;
      Result : out Step_Result);

   --  Perform one bounded decrypted receive step.
   --  @param IO Acquired capability
   --  @param Data Destination buffer for one bounded step
   --  @param Last Last element received, or Data'First - 1 without progress
   --  @param Result Progress, required readiness, or orderly peer closure
   --  @exception Operation_Cancelled Token or Close interrupts the driver
   --  @exception TLS_Error The provider fails or reports invalid progress
   procedure Receive
     (IO     : in out Capability;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result);

   --  Perform one bounded encrypted send step.
   --  @param IO Acquired capability
   --  @param Data Source buffer for one bounded step
   --  @param Last Last element sent, or Data'First - 1 without progress
   --  @param Result Progress, required readiness, or peer closure
   --  @exception Operation_Cancelled Token or Close interrupts the driver
   --  @exception TLS_Error The provider fails or reports invalid progress
   procedure Send
     (IO     : in out Capability;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Step_Result);

   --  Perform one bounded close-notify step.
   --  @param IO Acquired capability
   --  @param Result Progress, required readiness, or peer closure
   --  @exception Operation_Cancelled Token or Close interrupts the driver
   --  @exception TLS_Error The provider fails or reports invalid progress
   procedure Shutdown
     (IO     : in out Capability;
      Result : out Step_Result);

   --  Discharge the lease or registration and every retained borrow.
   --  @param IO Capability whose TLS connection borrow is discharged
   procedure Release (IO : in out Capability);

   --  Cancellation has the same ownership transition as Release; the outer
   --  provider chooses and publishes its own terminal cancellation outcome.
   --  @param IO Capability whose TLS connection borrow is discharged
   procedure Cancel (IO : in out Capability) renames Release;

   --  Report whether IO retains a registered or acquired connection borrow.
   --  @param IO Capability to inspect
   --  @return True until Release, Cancel, or finalization completes
   function Is_Engaged (IO : Capability) return Boolean;

   --  Report whether IO currently owns the TLS connection operation lease.
   --  @param IO Capability to inspect
   --  @return True when provider steps are permitted
   function Is_Acquired (IO : Capability) return Boolean;

private
   type Capability is new Ada.Finalization.Limited_Controlled with record
      State : Driver_State;
   end record;

   --  Release an abandoned registration or lease without propagating cleanup
   --  failures.
   --  @param IO Capability whose retained borrow is discharged
   --  @exclude
   overriding procedure Finalize (IO : in out Capability);

end Flyology.IO.TLS.Drivers;
