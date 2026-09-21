private with Ada.Finalization;
with Flyology.Wake_Sources;
with Interfaces.C;

--  Bounds concurrent work without owning or creating tasks. A Gate admits at
--  most Capacity holders. Waiting uses a private protected entry, so
--  lightweight tasks suspend cooperatively while native tasks use GNARL.
--  Shutdown rejects new acquisitions, releases queued callers, and lets
--  existing holders drain.

package Flyology.Capacity is

   --  Result of a nonblocking or timed acquisition.
   --  @enum Permit_Acquired One permit is now held by the caller
   --  @enum Gate_Full A nonblocking attempt found no capacity
   --  @enum Gate_Closed Shutdown rejected the acquisition
   --  @enum Acquire_Timed_Out A timed attempt reached its deadline
   type Acquire_Result is (Permit_Acquired, Gate_Full, Gate_Closed, Acquire_Timed_Out);

   --  Thread-safe bounded admission controller. The Gate must outlive every
   --  holder and every borrowed wake descriptor. Capacity is the maximum
   --  number of active permits. Optional Cleanup_Armed parameters publish a
   --  controlled caller's obligation in the same cut as permit ownership.
   --  Descriptor initialization, signaling, and EINTR retries occur outside
   --  the private protected state lock. These operations must not be called
   --  from another protected action. Borrowers must not close a wake
   --  descriptor. A failed drain after admission does not revoke or hide the
   --  transferred permit; the caller's guard retries before it leaves scope.
   --  @field Capacity Maximum number of active permits
   type Gate (Capacity : Positive) is tagged limited private;

   --  Publish terminal shutdown, then wake descriptor waiters. A wake error
   --  may raise Program_Error after shutdown has committed.
   --  @param Item Gate to shut down
   procedure Request_Shutdown (Item : in out Gate);

   --  Wait for capacity or terminal shutdown. An accepted call transfers one
   --  permit; the caller must Release it.
   --  @param Item Gate from which to acquire one permit
   --  @param Accepted True when a permit was acquired; False on shutdown
   --  @param Cleanup_Armed Optional caller-owned obligation. It must be False
   --     on call and becomes True in the admission state cut on success.
   --  @exception Program_Error Cleanup_Armed is already True
   procedure Acquire (Item : in out Gate; Accepted : out Boolean; Cleanup_Armed : access Boolean := null);

   --  Attempt admission without waiting.
   --  @param Item Gate from which to attempt one acquisition
   --  @param Result Permit_Acquired, Gate_Full, or Gate_Closed
   --  @param Cleanup_Armed Optional caller-owned obligation. It must be False
   --     on call and becomes True in the admission state cut on success.
   --  @exception Program_Error Cleanup_Armed is already True
   procedure Try_Acquire
     (Item : in out Gate; Result : out Acquire_Result; Cleanup_Armed : access Boolean := null);

   --  Release a held permit. A wake error may raise after release commits;
   --  Cleanup_Armed, when supplied, is cleared in the state cut.
   --  @param Item Gate to which the permit is returned
   --  @param Cleanup_Armed Optional caller-owned obligation; it must be True
   --     on call and becomes False when the permit is released.
   --  @exception Program_Error No permit is active, Cleanup_Armed is False,
   --     or an admission wake fails after release
   procedure Release (Item : in out Gate; Cleanup_Armed : access Boolean := null);

   --  Wait until shutdown has begun and all permits have been released.
   --  @param Item Gate whose holders must drain
   procedure Await_Drained (Item : in out Gate);

   --  Report whether terminal shutdown has begun.
   --  @param Item Gate to inspect
   --  @return True once Request_Shutdown records terminal shutdown
   function Shutdown_Requested (Item : Gate) return Boolean;

   --  Return the number of currently held permits.
   --  @param Item Gate to inspect
   --  @return Current active permit count
   function Active (Item : Gate) return Natural;

   --  Return the number of callers queued at Acquire.
   --  @param Item Gate to inspect
   --  @return Current number of queued acquisition callers
   function Waiting (Item : Gate) return Natural;

   --  Borrow a readable descriptor that becomes ready on shutdown. The caller
   --  must not close it and Gate must outlive the wait.
   --  @param Item Gate that owns the borrowed descriptor
   --  @param FD Borrowed descriptor, or -1 after shutdown
   --  @param Already_Requested Whether shutdown already started
   --  @exception Program_Error Wake descriptor creation fails
   procedure Wait_Source (Item : in out Gate; FD : out Interfaces.C.int; Already_Requested : out Boolean);

   --  Borrow a descriptor for composing Try_Acquire with a descriptor wait.
   --  When Can_Acquire is False, FD becomes readable after a release or
   --  shutdown. Otherwise retry Try_Acquire immediately and FD is -1. The
   --  caller must not read or close FD, and Gate must outlive the wait.
   --  @param Item Gate that owns the borrowed descriptor
   --  @param FD Borrowed readiness descriptor, or -1 when retry is ready
   --  @param Can_Acquire Whether Try_Acquire can make progress immediately
   --  @exception Program_Error Wake descriptor creation fails
   procedure Acquire_Wait_Source (Item : in out Gate; FD : out Interfaces.C.int; Can_Acquire : out Boolean);

   --  Acquire within one relative deadline. Negative Timeout waits
   --  indefinitely and zero is an immediate attempt. Once the private entry
   --  accepts the call, acquisition wins over a simultaneous deadline.
   --  Cleanup_Armed is published in the state cut that transfers ownership;
   --  an aborted caller must use that obligation rather than the unavailable
   --  Result to decide whether it owes Release.
   --  @param Item Gate from which to acquire one permit
   --  @param Timeout Relative deadline in seconds
   --  @param Result Permit_Acquired, Gate_Closed, or Acquire_Timed_Out
   --  @param Cleanup_Armed Optional caller-owned obligation. It must be False
   --     on call and becomes True when a permit is acquired.
   --  @exception Program_Error Cleanup_Armed is already True
   procedure Timed_Acquire
     (Item          : in out Gate;
      Timeout       : Duration;
      Result        : out Acquire_Result;
      Cleanup_Armed : access Boolean := null);

private
   type Wake_Action is (No_Action, Signal_Shutdown, Signal_Acquire, Drain_Acquire);
   type Acquire_Wake_Phase is (Wake_Quiet, Wake_Signalling, Wake_Signalled, Wake_Draining);
   type Initialization_Kind is (Shutdown_Source, Acquire_Source);

   type Wake_Claim is record
      Descriptor : Interfaces.C.int := Interfaces.C.int (-1);
      Kind       : aliased Wake_Action := No_Action;
      Armed      : aliased Boolean := False;
   end record;
   type Initialization_Guard;

   protected type Gate_State (Capacity : Positive) is
      entry Take_Permit
        (Accepted : out Boolean;
         Cleanup_Armed : access Boolean;
         Guard : not null access Wake_Claim);
      procedure Try_Acquire
        (Result : out Acquire_Result;
         Cleanup_Armed : access Boolean;
         Guard : not null access Wake_Claim);
      procedure Release (Cleanup_Armed : access Boolean; Guard : not null access Wake_Claim);
      procedure Request_Shutdown
        (Shutdown_Guard, Acquire_Guard : not null access Wake_Claim);
      entry Await_Drained;
      function Shutdown_Requested return Boolean;
      function Active return Natural;
      function Waiting return Natural;
      procedure Begin_Shutdown_Wait
        (Guard : not null access Initialization_Guard;
         FD : out Interfaces.C.int;
         Already_Requested : out Boolean);
      procedure Begin_Acquire_Wait
        (Guard : not null access Initialization_Guard;
         FD : out Interfaces.C.int;
         Can_Acquire, Stable : out Boolean);
      entry Wait_Shutdown_Ready;
      entry Wait_Acquire_Ready;
      procedure Publish_Source (Kind : Initialization_Kind; FD, Signal_FD : Interfaces.C.int);
      procedure Cancel_Initialization (Kind : Initialization_Kind);
      procedure Complete_Signal
        (Kind : not null access Wake_Action; Armed : not null access Boolean);
      procedure Complete_Drain
        (Kind : not null access Wake_Action; Armed : not null access Boolean);
      procedure Fail_Action
        (Kind : not null access Wake_Action; Armed : not null access Boolean);
   private
      Active_Count         : Natural := 0;
      Stopping             : Boolean := False;
      Shutdown_Initializing : Boolean := False;
      Acquire_Initializing : Boolean := False;
      Shutdown_Read_FD     : Interfaces.C.int := Interfaces.C.int (-1);
      Shutdown_Write_FD    : Interfaces.C.int := Interfaces.C.int (-1);
      Acquire_Read_FD      : Interfaces.C.int := Interfaces.C.int (-1);
      Acquire_Write_FD     : Interfaces.C.int := Interfaces.C.int (-1);
      Acquire_Phase        : Acquire_Wake_Phase := Wake_Quiet;
   end Gate_State;

   type State_Access is access all Gate_State;
   type Source_Access is access all Flyology.Wake_Sources.Source;

   type Action_Guard is new Ada.Finalization.Limited_Controlled with record
      State  : State_Access := null;
      Source : Source_Access := null;
      Claim  : aliased Wake_Claim;
   end record;

   --  @exclude Controlled wake-claim finalization hook
   --  @param Guard Wake claim to complete without raising
   overriding
   procedure Finalize (Guard : in out Action_Guard);

   type Initialization_Guard is new Ada.Finalization.Limited_Controlled with record
      State : State_Access := null;
      Kind  : Initialization_Kind := Shutdown_Source;
      Armed : Boolean := False;
   end record;

   --  @exclude Controlled initialization-claim finalization hook
   --  @param Guard Initialization claim to cancel without raising
   overriding
   procedure Finalize (Guard : in out Initialization_Guard);

   type Gate (Capacity : Positive) is tagged limited record
      State         : aliased Gate_State (Capacity);
      Shutdown_Wake : aliased Flyology.Wake_Sources.Source;
      Acquire_Wake  : aliased Flyology.Wake_Sources.Source;
   end record;
end Flyology.Capacity;
