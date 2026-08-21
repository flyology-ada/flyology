with Ada.Finalization;
with Flyology.Cancellation;
with Interfaces;
with Interfaces.C;
with System;
private with Flyology.Wake_Sources;

--  Provides bounded completion sets for scoped operations. An initiating I/O
--  overload associates a limited operation object with one set and returns
--  without waiting. The owning task can then wait for heterogeneous terminal
--  batches without creating helper tasks or per-operation stacks.
package Flyology.Operations with Preelaborate is

   --  Maximum number of operations in one completion set.
   Max_Operations : constant := 32;
   --  Maximum descriptor interests armed by one operation. This covers a
   --  primary transport plus bounded lifecycle and cancellation sources.
   Max_Readiness_Sources_Per_Operation : constant := 4;
   --  Valid caller-selected completion-set capacity.
   subtype Operation_Capacity is Positive range 1 .. Max_Operations;

   --  Raised when a completion set has no reusable slot.
   Capacity_Error : exception;
   --  Raised when an operation has an invalid or stale lifecycle state.
   Operation_Error : exception;
   --  Raised by a provider-specific Finish after terminal cancellation.
   Operation_Cancelled : exception renames
     Flyology.Cancellation.Operation_Cancelled;

   --  Stable one-based identity for a slot in one completion set.
   subtype Operation_Id is Positive range 1 .. Max_Operations;
   --  Bounded storage for completion identities.
   type Operation_Id_Array is array (Positive range <>) of Operation_Id;

   --  Every previously unreported terminal identity published by one wait.
   --  Only Ids (1 .. Count) are defined.
   --  @field Capacity Maximum number of identities in the batch
   --  @field Count Number of defined entries in Ids
   --  @field Ids Terminal operation identities in ascending slot order
   type Completion_Batch (Capacity : Positive) is record
      Count : Natural := 0;
      Ids   : Operation_Id_Array (1 .. Capacity) :=
        (others => Operation_Id'First);
   end record;

   --  Bounded caller-owned group used to wait for heterogeneous operations.
   --  One task must serialize initiation, waiting, cancellation, and Finish.
   --  @field Capacity Maximum number of associated operations
   type Completion_Set
     (Capacity : Operation_Capacity) is tagged limited private;

   --  Limited base for one scoped provider operation. Set must outlive the
   --  operation. Concrete provider packages declare derived types.
   type Operation
     (Set : not null access Completion_Set'Class) is
     abstract new Ada.Finalization.Limited_Controlled with private;

   --  Generation-stamped value identifying one operation outcome for gate
   --  composition. It contains no access value and does not extend the
   --  operation's lifetime. A reference must not outlive its completion set.
   type Operation_Reference is private;

   --  Snapshot one operation's set identity, slot, and generation.
   --  @param Item Active or terminal operation to reference
   --  @return Value reference accepted by gate constructors
   function Reference (Item : Operation'Class) return Operation_Reference;

   --  Definite arrays used to construct heterogeneous gates.
   type Operation_Reference_Array is
     array (Positive range <>) of Operation_Reference;

   --  Terminal result retained until provider-specific Finish consumes it.
   --  @enum Succeeded The provider completed its operation successfully
   --  @enum Failed The provider completed with an operation error
   --  @enum Cancelled Cancellation terminalized the operation
   type Terminal_Outcome is (Succeeded, Failed, Cancelled);

   --  Reason the owner task resumes a provider state machine.
   --  @enum Start_Operation Initiation requests the first immediate step
   --  @enum Source_Ready The provider's current descriptor became ready
   --  @enum Deadline_Reached The provider's monotonic deadline expired
   --  @enum Dependency_Changed A member operation changed terminal state
   --  @enum Continue_Operation A bounded progress step asked to run again
   type Driver_Event is
     (Start_Operation,
      Source_Ready,
      Deadline_Reached,
      Dependency_Changed,
      Continue_Operation);

   --  Advance one provider state machine on the owning task's stack. The
   --  implementation must rearm a source or publish a terminal outcome before
   --  returning. It must retain provider errors for Finish instead of raising.
   --  @param Item Operation whose state machine advances
   --  @param Event Source event that caused the drive
   procedure Drive
     (Item  : in out Operation;
      Event : Driver_Event) is abstract;

   --  Request cancellation from a provider. The implementation must publish
   --  Cancelled only after the runtime or kernel has released every borrowed
   --  actual parameter. This primitive must not raise.
   --  @param Item Operation to cancel or drain
   procedure Request_Cancellation (Item : in out Operation) is abstract;

   --  @exclude
   --  @param Item Operation whose slot must be released
   overriding procedure Finalize (Item : in out Operation);

   --  First-class operation whose terminal result is derived from a fixed
   --  snapshot of other operations in the same completion set. Gates may
   --  depend on provider operations or earlier gates. Member outcomes remain
   --  retained until every dependent gate terminalizes.
   type Gate_Operation is new Operation with private;

   --  Return the operation's stable set index, or zero before its first start
   --  and after finalization.
   --  @param Item Operation to inspect
   --  @return Stable set index, or zero before first start
   function Id (Item : Operation'Class) return Natural;

   --  Report whether an operation is waiting for terminal completion.
   --  @param Item Operation to inspect
   --  @return True only while the provider remains pending
   function Is_Active (Item : Operation'Class) return Boolean;
   --  Report whether an operation retains a terminal result.
   --  @param Item Operation to inspect
   --  @return True until Finish consumes the terminal result
   function Is_Terminal (Item : Operation'Class) return Boolean;
   --  Return a terminal operation's retained outcome.
   --  @param Item Terminal operation to inspect
   --  @return Provider terminal outcome
   function Outcome (Item : Operation'Class) return Terminal_Outcome
     with Pre => Is_Terminal (Item);

   --  Count operations that remain pending.
   --  @param Set Completion set to inspect
   --  @return Number of pending operations
   function Pending_Count (Set : Completion_Set) return Natural;
   --  Count operations that retain terminal outcomes.
   --  @param Set Completion set to inspect
   --  @return Number of terminal operations
   function Terminal_Count (Set : Completion_Set) return Natural;

   --  Construct a gate that succeeds after Required member operations become
   --  terminal, regardless of their individual outcomes. Remaining members
   --  continue independently. The gate consumes one completion-set slot.
   --  @param Set Completion set shared by the gate and every member
   --  @param Members Nonempty fixed member snapshot
   --  @param Required Required number of terminal members
   --  @return Started gate operation
   function Wait_Some
     (Set      : not null access Completion_Set'Class;
      Members  : Operation_Reference_Array;
      Required : Positive := 1) return Gate_Operation;

   --  Construct a gate that succeeds when every member is terminal. Member
   --  failures and cancellations count as terminal outcomes.
   --  @param Set Completion set shared by the gate and every member
   --  @param Members Nonempty fixed member snapshot
   --  @return Started gate operation
   function Wait_All
     (Set     : not null access Completion_Set'Class;
      Members : Operation_Reference_Array) return Gate_Operation;

   --  Construct a gate that succeeds when one member succeeds and fails when
   --  every member is terminal without a success.
   --  @param Set Completion set shared by the gate and every member
   --  @param Members Nonempty fixed member snapshot
   --  @return Started gate operation
   function Wait_For_Success
     (Set     : not null access Completion_Set'Class;
      Members : Operation_Reference_Array) return Gate_Operation;

   --  Construct a gate that succeeds after Required member successes and
   --  fails as soon as that threshold becomes impossible.
   --  @param Set Completion set shared by the gate and every member
   --  @param Members Nonempty fixed member snapshot
   --  @param Required Required number of successful members
   --  @return Started gate operation
   function Wait_For_Successes
     (Set      : not null access Completion_Set'Class;
      Members  : Operation_Reference_Array;
      Required : Positive) return Gate_Operation;

   --  Consume a terminal gate and return every member outcome observed at the
   --  gate's scheduler snapshot. Inspect Outcome before Finish to distinguish
   --  a satisfied gate from an impossible success threshold. Cancellation
   --  raises Operation_Cancelled after consuming the gate; Matched is then
   --  undefined because Ada does not copy out on exceptional return.
   --  @param Item Terminal gate operation
   --  @param Matched Member identities observed terminal by the gate
   procedure Finish
     (Item    : in out Gate_Operation;
      Matched : out Completion_Batch);

   --  Return every unreported terminal operation. If none is terminal, wait
   --  until descriptor readiness or a monotonic deadline terminalizes at
   --  least one operation. The set and its operations are single-owner and
   --  must be used by one task.
   --  @param Set Completion set to wait on
   --  @param Completed Newly published terminal identities
   procedure Wait_Some
     (Set       : in out Completion_Set;
      Completed : out Completion_Batch)
     with Pre => Completed.Capacity = Set.Capacity;

   --  Wait until at least Required previously unreported operations are
   --  terminal, then return the complete terminal batch observed at that
   --  point. If fewer than Required operations can remain pending, return the
   --  remaining batch when the set becomes quiescent instead of deadlocking.
   --  @param Set Completion set to wait on
   --  @param Required Minimum number of newly terminal operations
   --  @param Completed Newly published terminal identities
   procedure Wait_At_Least
     (Set       : in out Completion_Set;
      Required  : Positive;
      Completed : out Completion_Batch)
     with Pre =>
       Required <= Set.Capacity
       and then Completed.Capacity = Set.Capacity;

   --  Counted spelling of Wait_At_Least. Wait for Required newly terminal
   --  operations, or return the remaining batch when the set becomes
   --  quiescent before that threshold can be reached.
   --  @param Set Completion set to wait on
   --  @param Required Minimum number of newly terminal operations
   --  @param Completed Newly published terminal identities
   procedure Wait_Some
     (Set       : in out Completion_Set;
      Required  : Positive;
      Completed : out Completion_Batch)
     with Pre =>
       Required <= Set.Capacity
       and then Completed.Capacity = Set.Capacity;

   --  Wait for one previously unreported successful operation. Failed and
   --  cancelled operations are returned but do not satisfy the gate.
   --  @param Set Completion set to wait on
   --  @param Completed Newly published identities of every outcome
   procedure Wait_For_Success
     (Set       : in out Completion_Set;
      Completed : out Completion_Batch)
     with Pre => Completed.Capacity = Set.Capacity;

   --  Wait for Required previously unreported successful operations. Failed
   --  and cancelled operations do not count toward the threshold. Return all
   --  unreported terminal outcomes when the threshold is reached or when it
   --  becomes impossible because too few operations remain pending.
   --  @param Set Completion set to wait on
   --  @param Required Minimum number of newly successful operations
   --  @param Completed Newly published terminal identities of every outcome
   procedure Wait_For_Successes
     (Set       : in out Completion_Set;
      Required  : Positive;
      Completed : out Completion_Batch)
     with Pre =>
       Required <= Set.Capacity
       and then Completed.Capacity = Set.Capacity;

   --  Wait until no operation in Set remains pending. Terminal operations are
   --  retained until their provider-specific Finish operation consumes them.
   --  @param Set Completion set to wait on
   procedure Wait_All (Set : in out Completion_Set);

   --  Request terminal cancellation. Readiness and timer operations cancel
   --  immediately. Providers with kernel-owned input may retain Cancelling
   --  state in later extensions until the kernel relinquishes that input.
   --  @param Item Operation to cancel
   procedure Cancel (Item : in out Operation'Class);

   --  Suspend Parent on one Child operation in the same completion set. Child
   --  becomes an internal implementation detail: waits drive its sources but
   --  do not publish its identity in user completion batches. When Child is
   --  terminal, Parent is driven with Dependency_Changed on the owner task's
   --  stack. Parent must call Child's provider-specific Finish and Release
   --  from that drive before continuing. If Child is already terminal, this
   --  procedure may drive Parent before returning.
   --  @param Parent Pending outer provider operation
   --  @param Child Newly pending or terminal child with no other dependents
   procedure Continue_After
     (Parent : in out Operation'Class;
      Child  : in out Operation'Class);

   --  Release one terminal result and make its bounded slot reusable by the
   --  same operation object.
   --  @param Item Terminal operation whose slot becomes reusable
   procedure Consume (Item : in out Operation'Class)
     with Pre => Is_Terminal (Item);

   --  Release a consumed operation's slot for reuse by a different operation
   --  object. Composite providers call this after the child's typed Finish;
   --  ordinary reusable operations normally retain their idle slot instead.
   --  @param Item Consumed, idle operation to detach from its set slot
   procedure Release (Item : in out Operation'Class);

private
   type Slot_State is (Vacant, Idle, Pending, Terminal);
   type Source_Kind is
     (No_Source,
      Descriptor_Source,
      Timer_Source,
      Dependency_Source,
      Immediate_Source);

   subtype Readiness_Source_Index is Positive range
     1 .. Max_Readiness_Sources_Per_Operation;
   type Descriptor_Source_Array is
     array (Readiness_Source_Index) of Interfaces.C.int;
   type Write_Interest_Array is
     array (Readiness_Source_Index) of Boolean;

   type Slot_Record is record
      State       : Slot_State := Vacant;
      Generation  : Interfaces.Unsigned_64 := 0;
      Source      : Source_Kind := No_Source;
      Source_Count : Natural range
        0 .. Max_Readiness_Sources_Per_Operation := 0;
      Descriptors : Descriptor_Source_Array :=
        (others => Interfaces.C.int (-1));
      For_Write   : Write_Interest_Array := (others => False);
      Deadline    : Duration := Duration'Last;
      Result      : Terminal_Outcome := Succeeded;
      Reported    : Boolean := False;
      Owner       : access Operation'Class := null;
      Has_Deadline : Boolean := False;
      Dependents  : Interfaces.Unsigned_32 := 0;
      Internal    : Boolean := False;
      Child       : Natural range 0 .. Max_Operations := 0;
      Child_Generation : Interfaces.Unsigned_64 := 0;
   end record;

   type Slot_Array is array (Operation_Id range <>) of Slot_Record;

   type Completion_Set
     (Capacity : Operation_Capacity) is tagged limited record
      Slots : Slot_Array (1 .. Capacity);
      Wake  : Flyology.Wake_Sources.Source;
      Dirty_Dependents : Interfaces.Unsigned_32 := 0;
      Propagation_Batch_Depth : Natural := 0;
      Stabilizing_Dependents : Boolean := False;
   end record;

   type Operation
     (Set : not null access Completion_Set'Class) is
     abstract new Ada.Finalization.Limited_Controlled with record
      Slot       : Natural range 0 .. Max_Operations := 0;
      Generation : Interfaces.Unsigned_64 := 0;
   end record;

   type Operation_Reference is record
      Set_Address : System.Address := System.Null_Address;
      Slot        : Natural range 0 .. Max_Operations := 0;
      Generation  : Interfaces.Unsigned_64 := 0;
   end record;

   type Gate_Mode is (Terminal_Members, Successful_Members);
   type Member_Generation_Array is
     array (Operation_Id) of Interfaces.Unsigned_64;

   type Gate_Operation is new Operation with record
      Mode        : Gate_Mode := Terminal_Members;
      Required    : Positive := 1;
      Member_Count : Natural range 0 .. Max_Operations := 0;
      Members     : Interfaces.Unsigned_32 := 0;
      Seen        : Interfaces.Unsigned_32 := 0;
      Successful  : Interfaces.Unsigned_32 := 0;
      Generations : Member_Generation_Array := (others => 0);
   end record;

   --  @exclude
   --  @param Item Gate whose dependency snapshot changed
   --  @param Event Dependency transition event
   overriding procedure Drive
     (Item  : in out Gate_Operation;
      Event : Driver_Event);

   --  @exclude
   --  @param Item Gate to detach and terminalize
   overriding procedure Request_Cancellation
     (Item : in out Gate_Operation);

   --  Reserve or reuse one operation slot and publish Pending state.
   --  @param Item Operation whose slot is reserved
   procedure Register (Item : in out Operation'Class);

   --  Publish a terminal result and notify every dependent operation.
   --  @param Item Operation becoming terminal
   --  @param Result Retained terminal outcome
   procedure Publish_Terminal
     (Item   : in out Operation'Class;
      Result : Terminal_Outcome);

   --  @exclude
   --  @return Current monotonic time in seconds
   function Clock return Duration;

end Flyology.Operations;
