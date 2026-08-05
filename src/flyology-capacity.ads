with Flyology.Wake_Sources;
with Interfaces.C;

--  Bounds concurrent work without owning or creating tasks.
--
--  A Gate admits at most Capacity holders. Waiting on Acquire uses ordinary
--  Ada protected-entry semantics, so lightweight tasks suspend cooperatively
--  while native tasks block through GNARL. Shutdown is terminal: it rejects
--  new acquisitions, releases queued callers, and permits existing holders to
--  drain.
package Flyology.Capacity is

   --  Result of a nonblocking or timed acquisition.
   --  @enum Permit_Acquired One permit is now held by the caller
   --  @enum Gate_Full A nonblocking attempt found no capacity
   --  @enum Gate_Closed Shutdown rejected the acquisition
   --  @enum Acquire_Timed_Out A timed attempt reached its deadline
   type Acquire_Result is
     (Permit_Acquired, Gate_Full, Gate_Closed, Acquire_Timed_Out);

   --  Thread-safe bounded admission controller. The object must outlive every
   --  holder that has successfully acquired a permit. The optional
   --  Cleanup_Armed parameters let a controlled caller publish its cleanup
   --  obligation in the same protected action as permit ownership changes.
   protected type Gate
     (Capacity : Positive)  --  Maximum number of active permits
   is
      --  Idempotently reject new acquisitions and release queued callers.
      --  Borrowed shutdown and admission readiness descriptors are signalled.
      --  Program_Error is raised when a borrowed wake descriptor cannot be
      --  signalled; shutdown remains recorded.
      procedure Request_Shutdown;

      --  Wait until a permit is available or shutdown has been requested.
      --  @param Accepted True when one permit was acquired; False on shutdown
      --  @param Cleanup_Armed Optional caller-owned cleanup obligation. When
      --     non-null it must designate False on call. It remains False when
      --     Accepted is False and becomes True in the protected action that
      --     acquires the permit. The caller must then release or atomically
      --     transfer that obligation.
      --  @exception Program_Error Cleanup_Armed designates True on call, or a
      --     pending admission readiness signal cannot be consumed
      entry Acquire
        (Accepted      : out Boolean;
         Cleanup_Armed : access Boolean := null);

      --  Attempt to acquire without waiting.
      --  @param Result Permit_Acquired, Gate_Full, or Gate_Closed
      --  @param Cleanup_Armed Optional caller-owned cleanup obligation. When
      --     non-null it must designate False on call. It remains False for
      --     Gate_Full or Gate_Closed and becomes True in the protected action
      --     that returns Permit_Acquired. The caller must then release or
      --     atomically transfer that obligation.
      --  @exception Program_Error Cleanup_Armed designates True on call, or a
      --     pending admission readiness signal cannot be consumed
      procedure Try_Acquire
        (Result        : out Acquire_Result;
         Cleanup_Armed : access Boolean := null);

      --  Release one acquired permit. If an Acquire_Wait_Source has been
      --  borrowed, releasing the permit also wakes its waiters.
      --  @param Cleanup_Armed Optional caller-owned cleanup obligation. When
      --     non-null it must designate True on call and becomes False in the
      --     protected action that releases the permit, before any fallible
      --     wake. It remains False if wake signalling then fails.
      --  @exception Program_Error Cleanup_Armed designates False on call, no
      --     permit is active, or the admission readiness source cannot be
      --     signalled. A signalling failure leaves the permit released.
      procedure Release (Cleanup_Armed : access Boolean := null);

      --  Wait until shutdown has been requested and every permit is released.
      entry Await_Drained;

      --  Report whether shutdown has been requested.
      --  @return True after Request_Shutdown
      function Shutdown_Requested return Boolean;

      --  Return the number of active permits.
      --  @return Current active count
      function Active return Natural;

      --  Return the number of callers queued at Acquire.
      --  @return Current Acquire entry count
      function Waiting return Natural;

      --  Borrow a readable descriptor that becomes ready on shutdown. This is
      --  intended for composing a Gate with task-aware descriptor waits; the
      --  caller must not close it and the Gate must outlive the wait.
      --  @param FD Borrowed descriptor, or -1 after shutdown
      --  @param Already_Requested Whether shutdown already started
      --  @exception Program_Error Wake descriptor creation fails
      procedure Wait_Source
        (FD                : out Interfaces.C.int;
         Already_Requested : out Boolean);

      --  Borrow a descriptor for composing nonblocking Try_Acquire with an
      --  interruptible wait. When Can_Acquire is False, FD becomes readable
      --  after a permit is released or shutdown starts. When Can_Acquire is
      --  True, retry Try_Acquire without waiting and FD is -1. The caller must
      --  not read or close FD, and the Gate must outlive the wait.
      --  @param FD Borrowed readiness descriptor, or -1 when a retry is ready
      --  @param Can_Acquire Whether Try_Acquire can make progress immediately
      --  @exception Program_Error Wake descriptor creation fails
      procedure Acquire_Wait_Source
        (FD          : out Interfaces.C.int;
         Can_Acquire : out Boolean);
   private
      Active_Count : Natural := 0;  --  Currently held permits
      Stopping     : Boolean := False;  --  Terminal shutdown state
      Shutdown_Wake : Flyology.Wake_Sources.Source;  --  Terminal wake source
      Acquire_Wake  : Flyology.Wake_Sources.Source;  --  Permit-state wake
      Acquire_Signalled : Boolean := False;  --  Pending permit-state signal
   end Gate;

   --  Acquire within one relative deadline. Negative Timeout waits
   --  indefinitely and zero is an immediate attempt. Once the protected entry
   --  is accepted, acquisition wins over a simultaneous deadline.
   --  @param Item Gate from which to acquire one permit
   --  @param Timeout Deadline interval in seconds
   --  @param Result Permit_Acquired, Gate_Closed, or Acquire_Timed_Out
   --  @exception Program_Error A pending admission readiness signal cannot be
   --     consumed
   procedure Timed_Acquire
     (Item    : in out Gate;
      Timeout : Duration;
      Result  : out Acquire_Result);

end Flyology.Capacity;
