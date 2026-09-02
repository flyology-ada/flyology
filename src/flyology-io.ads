with Interfaces.C;
with Flyology.Operations;

--  Supplies readiness primitives shared by lightweight and native tasks.
--
--  Example:
--
--     if Flyology.IO.Wait (FD, Flyology.IO.For_Read, 0.0) then
--        null;
--     end if;

package Flyology.IO
  with Preelaborate
is

   --  Conventional negative timeout denoting no time limit. All negative
   --  Duration values have the same meaning in this API.
   Infinite : constant Duration := -1.0;

   --  Raised by higher-level I/O operations when one deadline expires.
   Timeout_Error : exception;
   --  Raised when descriptor validation, polling, or a device operation fails.
   Device_Error  : exception;

   --  Native operating-system descriptor number.
   subtype Descriptor is Interfaces.C.int;
   --  Sentinel denoting no descriptor.
   Invalid_Descriptor : constant Descriptor := Interfaces.C.int (-1);
   --  Readable wake descriptors composed into an interruptible wait. The
   --  wait observes but never reads or closes them; their owners must outlive
   --  the call.
   type Interrupt_Set is array (Positive range <>) of Descriptor;
   --  Empty interrupt set used when no wake source is present.
   No_Interrupts      : constant Interrupt_Set (1 .. 0) := (others => Invalid_Descriptor);
   --  Readiness condition requested from the poller.
   --  @enum For_Read The descriptor can be read without blocking
   --  @enum For_Write The descriptor can be written without blocking
   type Wait_Kind is (For_Read, For_Write);
   --  Result from an interruptible wait.
   --  @enum Ready The primary descriptor became ready
   --  @enum Timed_Out The deadline expired
   --  @enum Interrupted A member of the interrupt set became readable
   type Wait_Outcome is (Ready, Timed_Out, Interrupted);

   --  One descriptor readiness request.
   --  @field FD Descriptor to observe
   --  @field Condition Read or write readiness to observe
   type Wait_Request is record
      FD        : Descriptor;
      Condition : Wait_Kind;
   end record;
   --  Caller-indexed set passed to Wait_Any.
   type Wait_Request_Array is array (Positive range <>) of Wait_Request;

   --  Bounded list of caller indexes that became ready in one wait. Only
   --  Indexes (1 .. Count) are defined. Indexes are reported in ascending
   --  caller-index order.
   type Wait_Index_Array is array (Positive range <>) of Positive;
   --  Batch of caller indexes observed ready by one Wait_Some call.
   --  @field Capacity Maximum number of indexes in the batch
   --  @field Count Number of defined entries in Indexes
   --  @field Indexes Ready indexes from the caller's request array
   type Wait_Batch (Capacity : Natural) is record
      Count   : Natural := 0;
      Indexes : Wait_Index_Array (1 .. Capacity) := (others => Positive'First);
   end record;

   --  Maximum number of descriptors in one allocation-free Wait_Any call.
   --  Bound shared with completion sets: 32 operations may each retain six
   --  transport, protocol, source, and lifecycle descriptor interests without
   --  helper tasks.
   Max_Wait_Requests : constant := 192;

   --  Report whether the calling Ada task uses a Flyology event loop.
   --  @return True for a lightweight task; False for a native task
   function Is_Lightweight_Task return Boolean;

   --  Wait until FD is ready or Timeout seconds expire. Negative means no
   --  limit; zero performs an immediate poll. A lightweight task suspends on
   --  its event loop; a native task blocks its thread in poll(2). Retries
   --  after EINTR share the original deadline. This is a potentially
   --  blocking operation and must not be called inside a protected action:
   --  a lightweight task that would suspend there raises Program_Error
   --  before suspending, while the zero-Timeout immediate poll does not
   --  suspend and is not refused. Native tasks keep stock behavior.
   --  @param FD Valid descriptor to observe
   --  @param Condition Requested readiness condition
   --  @param Timeout Deadline interval in seconds
   --  @return True when ready; False on timeout
   --  @exception Device_Error FD is invalid or the poller fails
   --  @exception Program_Error A lightweight task would suspend inside a
   --     protected action
   function Wait (FD : Descriptor; Condition : Wait_Kind; Timeout : Duration := Infinite) return Boolean;

   --  Wait until one request is ready. Negative Timeout means no limit and
   --  zero is an immediate poll. One deadline spans EINTR retries. Duplicate
   --  descriptors and read/write pairs are supported; the lowest caller index
   --  wins simultaneous readiness. No descriptor is consumed. Lightweight
   --  tasks suspend; native tasks block their thread. A lightweight task
   --  that would suspend inside a protected action raises Program_Error, as
   --  for Wait.
   --  @param Requests At most Max_Wait_Requests readiness requests
   --  @param Timeout Deadline interval in seconds
   --  @return Exact Requests index ready, or 0 on timeout or empty input
   --  @exception Device_Error A descriptor is invalid or polling fails
   --  @exception Program_Error A lightweight task would suspend inside a
   --     protected action
   function Wait_Any (Requests : Wait_Request_Array; Timeout : Duration := Infinite) return Natural
   with Pre => Requests'Length <= Max_Wait_Requests;

   --  Wait until at least one request is ready, then report the requests
   --  observed ready by the terminal zero-time probe. A readiness event that
   --  disappears before that probe is still reported. Empty input and timeout
   --  return an empty batch. Completed.Capacity must equal Requests'Length.
   --  Duplicate requests remain distinct caller indexes. A lightweight task
   --  that would suspend inside a protected action raises Program_Error, as
   --  for Wait.
   --  @param Requests At most Max_Wait_Requests readiness requests
   --  @param Completed Ready caller indexes
   --  @param Timeout Deadline interval in seconds
   --  @exception Device_Error A descriptor is invalid or polling fails
   --  @exception Program_Error A lightweight task would suspend inside a
   --     protected action
   procedure Wait_Some
     (Requests : Wait_Request_Array; Completed : out Wait_Batch; Timeout : Duration := Infinite)
   with Pre => Requests'Length <= Max_Wait_Requests and then Completed.Capacity = Requests'Length;

   --  Wait for FD or any readable interrupt source. Interrupt
   --  descriptors are neither read nor closed. Timeout and lane behavior
   --  match Wait; one deadline spans native EINTR retries.
   --  @param FD Primary valid descriptor
   --  @param Condition Primary readiness condition
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts At most Max_Wait_Requests - 1 readable wake
   --     descriptors
   --  @return Ready, Timed_Out, or Interrupted
   --  @exception Device_Error FD is invalid or the poller fails
   --  @exception Program_Error A lightweight task would suspend inside a
   --     protected action
   function Wait_Interruptibly
     (FD         : Descriptor;
      Condition  : Wait_Kind;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts) return Wait_Outcome
   with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Scoped readiness operation associated with one completion set. Calling
   --  the operation-producing Wait overload below records the request without
   --  waiting. The completion set must outlive the operation.
   type Readiness_Operation is new Flyology.Operations.Operation with private;

   --  Construct and start one readiness operation in place.
   --  @param Set Completion set that owns the operation slot
   --  @param FD Valid descriptor to observe
   --  @param Condition Requested readiness condition
   --  @return Started limited readiness operation
   function Wait
     (Set : not null access Flyology.Operations.Completion_Set'Class; FD : Descriptor; Condition : Wait_Kind)
      return Readiness_Operation;

   --  Start or restart readiness in an established operation object. This is
   --  the composition form of the familiar Wait name.
   --  @param FD Valid descriptor to observe
   --  @param Condition Requested readiness condition
   --  @param Operation Fresh, released, or consumed readiness operation
   procedure Wait (FD : Descriptor; Condition : Wait_Kind; Operation : in out Readiness_Operation)
   with
     Pre =>
       not Flyology.Operations.Is_Active (Operation) and then not Flyology.Operations.Is_Terminal (Operation);

   --  Restart a previously consumed readiness operation.
   --  @param FD Valid descriptor to observe
   --  @param Condition Requested readiness condition
   --  @param Operation Previously consumed operation state
   procedure Rearm (FD : Descriptor; Condition : Wait_Kind; Operation : in out Readiness_Operation)
   with
     Pre =>
       not Flyology.Operations.Is_Active (Operation) and then not Flyology.Operations.Is_Terminal (Operation);

   --  Consume a terminal readiness operation. Cancellation raises the common
   --  scoped-operation cancellation exception.
   --  @param Operation Terminal readiness operation to consume
   --  @exception Device_Error The readiness provider failed
   procedure Finish (Operation : in out Readiness_Operation)
   with Pre => Flyology.Operations.Is_Terminal (Operation);

private
   type Readiness_Operation is new Flyology.Operations.Operation with null record;

   --  @exclude
   --  @param Item Readiness operation to advance
   --  @param Event Driver event to process
   overriding
   procedure Drive (Item : in out Readiness_Operation; Event : Flyology.Operations.Driver_Event);

   --  @exclude
   --  @param Item Readiness operation to cancel
   overriding
   procedure Request_Cancellation (Item : in out Readiness_Operation);

end Flyology.IO;
