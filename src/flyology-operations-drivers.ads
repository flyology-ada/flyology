with Interfaces.C;

--  Supplies the source-neutral protocol used by scoped operation providers.
--  A provider starts one caller-owned operation, advances it on the owner
--  task's stack, and either arms its next source or publishes a terminal
--  outcome. These calls create no task, stack, callback thread, or heap
--  object.

package Flyology.Operations.Drivers
  with Preelaborate
is

   --  One descriptor interest retained by an operation while it is pending.
   --  @field Descriptor Valid borrowed operating-system descriptor
   --  @field For_Write True for write readiness; False for read readiness
   type Readiness_Source is record
      Descriptor : Interfaces.C.int;
      For_Write  : Boolean;
   end record;

   --  Bounded descriptor set armed as one operation source.
   type Readiness_Source_Array is array (Positive range <>) of Readiness_Source;

   --  Reserve the operation's stable slot and mark it pending. Call this once
   --  before the provider's first Drive event.
   --  @param Item Fresh or previously consumed operation object
   --  @exception Capacity_Error The completion set has no reusable slot
   --  @exception Operation_Error Item already has a pending or terminal value
   procedure Start (Item : in out Operation'Class);

   --  Return a just-started operation to its reusable idle state when provider
   --  preparation fails before any external source or kernel request retains
   --  it. This is the exception rollback path for explicit Rearm operations.
   --  @param Item Pending operation whose initiation did not publish effects
   --  @exception Operation_Error Item is stale or not pending
   procedure Rollback_Start (Item : in out Operation'Class);

   --  Arm one descriptor source. A later readiness event invokes Drive on the
   --  owning task's stack. The descriptor owner must outlive the operation.
   --  @param Item Pending operation to arm
   --  @param Descriptor Valid borrowed operating-system descriptor
   --  @param For_Write True for write readiness; False for read readiness
   --  @exception Operation_Error Item is stale, terminal, or already armed
   procedure Arm_Readiness
     (Item : in out Operation'Class; Descriptor : Interfaces.C.int; For_Write : Boolean);

   --  Arm several descriptor interests for one operation. Readiness of any
   --  source invokes Drive once; the driver must rearm its next complete set.
   --  Duplicate descriptor/direction pairs are accepted and coalesced by the
   --  completion-set wait. Every descriptor owner must outlive the operation.
   --  @param Item Pending operation to arm
   --  @param Sources Nonempty bounded descriptor interests
   --  @exception Operation_Error Item is stale, terminal, already armed, a
   --     descriptor is invalid, or the source bound is exceeded
   procedure Arm_Readiness (Item : in out Operation'Class; Sources : Readiness_Source_Array)
   with Pre => Sources'Length in 1 .. Flyology.Operations.Max_Readiness_Sources_Per_Operation;

   --  Set or replace one operation deadline. A nonpositive interval is due on
   --  the next completion-set drive. A deadline can coexist with readiness.
   --  @param Item Pending operation whose deadline changes
   --  @param Interval Relative monotonic interval in seconds
   --  @exception Operation_Error Item is stale or terminal
   procedure Arm_Deadline (Item : in out Operation'Class; Interval : Duration);

   --  Remove one pending operation's deadline.
   --  @param Item Pending operation whose deadline is removed
   --  @exception Operation_Error Item is stale or terminal
   procedure Clear_Deadline (Item : in out Operation'Class);

   --  Ask the completion set to invoke one further bounded provider step on
   --  the owner task before it blocks for external readiness. This avoids
   --  recursive driving when a provider has buffered progress that needs no
   --  descriptor event, such as a TLS session consuming already-decrypted
   --  input. Each invocation must remain a bounded step.
   --  @param Item Pending operation to reschedule
   --  @exception Operation_Error Item is stale, terminal, or already armed
   procedure Reschedule (Item : in out Operation'Class);

   --  Lazily create and return the shared completion wake descriptors for an
   --  externally completed provider such as positional file I/O.
   --  @param Item Pending operation whose set owns the wake source
   --  @param Read_Descriptor Descriptor armed by the completion set
   --  @param Signal_Descriptor Descriptor passed to the completion producer
   procedure Completion_Source
     (Item              : in out Operation'Class;
      Read_Descriptor   : out Interfaces.C.int;
      Signal_Descriptor : out Interfaces.C.int);

   --  Signal the shared completion source previously established for Item.
   --  This is the producer side of Completion_Source for an Ada provider that
   --  retains a caller-owned operation node rather than a raw descriptor.
   --  The operation and its completion set must still be alive.
   --  @param Item Pending externally completed operation to notify
   procedure Signal_Completion (Item : in out Operation'Class);

   --  Publish one terminal outcome. The provider must release every runtime,
   --  kernel, descriptor, and buffer reference before this call.
   --  @param Item Pending operation to terminalize
   --  @param Result Retained outcome interpreted by provider-specific Finish
   --  @exception Operation_Error Item is stale or not pending
   procedure Complete (Item : in out Operation'Class; Result : Terminal_Outcome);

end Flyology.Operations.Drivers;
