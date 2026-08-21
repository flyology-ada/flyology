with Interfaces.C;

--  Supplies the source-neutral protocol used by scoped operation providers.
--  A provider starts one caller-owned operation, advances it on the owner
--  task's stack, and either arms its next source or publishes a terminal
--  outcome. These calls create no task, stack, callback thread, or heap
--  object.
package Flyology.Operations.Drivers with Preelaborate is

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
     (Item       : in out Operation'Class;
      Descriptor : Interfaces.C.int;
      For_Write  : Boolean);

   --  Set or replace one operation deadline. A nonpositive interval is due on
   --  the next completion-set drive. A deadline can coexist with readiness.
   --  @param Item Pending operation whose deadline changes
   --  @param Interval Relative monotonic interval in seconds
   --  @exception Operation_Error Item is stale or terminal
   procedure Arm_Deadline
     (Item     : in out Operation'Class;
      Interval : Duration);

   --  Remove one pending operation's deadline.
   --  @param Item Pending operation whose deadline is removed
   --  @exception Operation_Error Item is stale or terminal
   procedure Clear_Deadline (Item : in out Operation'Class);

   --  Lazily create and return the shared completion wake descriptors for an
   --  externally completed provider such as positional file I/O.
   --  @param Item Pending operation whose set owns the wake source
   --  @param Read_Descriptor Descriptor armed by the completion set
   --  @param Signal_Descriptor Descriptor passed to the completion producer
   procedure Completion_Source
     (Item              : in out Operation'Class;
      Read_Descriptor   : out Interfaces.C.int;
      Signal_Descriptor : out Interfaces.C.int);

   --  Publish one terminal outcome. The provider must release every runtime,
   --  kernel, descriptor, and buffer reference before this call.
   --  @param Item Pending operation to terminalize
   --  @param Result Retained outcome interpreted by provider-specific Finish
   --  @exception Operation_Error Item is stale or not pending
   procedure Complete
     (Item   : in out Operation'Class;
      Result : Terminal_Outcome);

end Flyology.Operations.Drivers;
