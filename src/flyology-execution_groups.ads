with Ada.Finalization;
with System.Multiprocessors;

--  Selects and observes event-loop execution groups for lightweight tasks.
--
--  Example:
--
--     Flyology.Execution_Groups.Migrate (1);

package Flyology.Execution_Groups
  with Preelaborate
is

   --  Identifier of one permanent event-loop execution group.
   type Group_Id is range 0 .. 255;
   --  Shared groups selected by CPU aspects and automatic placement.
   subtype Shared_Group_Id is Group_Id range 0 .. 127;
   --  Exclusively reserved groups returned by Create_Dedicated.
   subtype Dedicated_Group_Id is Group_Id range 128 .. Group_Id'Last;

   --  First shared group. Ada reserves CPU 0 as Not_A_Specific_CPU, so no CPU
   --  aspect names this group; reach it through automatic placement, Migrate,
   --  or Topology.Cross_To_Shard.
   Default_Group : constant Shared_Group_Id := 0;

   --  Ada CPU aspect values that name a shared execution group. The reserved
   --  value 0 is excluded because Ada defines it as Not_A_Specific_CPU, which
   --  requests automatic placement rather than Default_Group.
   subtype Group_Selecting_CPU is
     System.Multiprocessors.CPU_Range range 1 .. System.Multiprocessors.CPU_Range (Shared_Group_Id'Last);

   --  Number of shared groups participating in automatic placement.
   subtype Loop_Pool_Size is Positive range 1 .. 128;
   --  Automatic assignment policy for tasks without a CPU aspect.
   --  @enum Round_Robin Select successive groups in the configured pool
   type Automatic_Placement_Policy is (Round_Robin);

   --  Result of a request to lower the automatic-placement ceiling.
   --  @enum Reduction_Started New automatic placements now use Target_Size
   --     and eligible existing tasks will drain cooperatively
   --  @enum Already_At_Or_Below The current ceiling already satisfies the
   --     request
   --  @enum Reduction_In_Progress A previous reduction must finish first
   type Pool_Reduction_Request_Result is (Reduction_Started, Already_At_Or_Below, Reduction_In_Progress);
   --  Lifecycle of the most recent automatic-pool reduction.
   --  @enum No_Reduction No reduction is active or retained for observation
   --  @enum Draining New placement uses Target_Size while eligible tasks move
   --  @enum Drained No automatically managed task remains above Target_Size
   type Pool_Reduction_Phase is (No_Reduction, Draining, Drained);
   --  Progress and blockers for an automatic-pool reduction. Explicit_Tasks
   --  reports tasks outside Target_Size that are not managed by the automatic
   --  pool; they do not prevent Drained. Counts are a momentary snapshot.
   --  @field Phase Current reduction lifecycle
   --  @field Target_Size Current automatic-placement ceiling
   --  @field Automatic_Tasks Automatically managed tasks still above target
   --  @field Pinned_Automatic_Tasks Such tasks currently pinned to a thread
   --  @field Waiting_Automatic_Tasks Such tasks suspended until another event
   --  @field Explicit_Tasks Explicitly placed tasks above the target
   --  @field Placement_Claims Creations that selected an above-target group
   --     before the reduction cutover and have not registered yet
   type Pool_Reduction_Status is record
      Phase                   : Pool_Reduction_Phase := No_Reduction;
      Target_Size             : Loop_Pool_Size := Loop_Pool_Size'First;
      Automatic_Tasks         : Natural := 0;
      Pinned_Automatic_Tasks  : Natural := 0;
      Waiting_Automatic_Tasks : Natural := 0;
      Explicit_Tasks          : Natural := 0;
      Placement_Claims        : Natural := 0;
   end record;

   --  Optional placement of an execution group's scheduler thread. This is
   --  independent from an Ada CPU aspect, which selects an execution group.
   --  @enum No_Placement Do not request host placement
   --  @enum Strict_CPU Bind to one Linux logical CPU; unsupported on Darwin
   --  @enum Advisory_Tag Apply a Darwin cache-locality tag, not a CPU number
   type Loop_Thread_Placement is (No_Placement, Strict_CPU, Advisory_Tag);
   --  Host placement value: zero-based Linux CPU or positive Darwin tag.
   subtype Placement_Value is Natural range 0 .. 2_147_483_647;
   --  Result of a loop-thread configuration request.
   --  @enum Configured New configuration was recorded before startup
   --  @enum Unchanged The identical configuration was already recorded
   --  @enum Unsupported The host does not implement this placement kind
   --  @enum Invalid_Value Value is invalid for Kind or unavailable to process
   --  @enum Group_Already_Started Group entered lazy startup before this
   --     change
   --  @enum Runtime_Unavailable Runtime lifecycle does not permit
   --     configuration
   type Placement_Configuration_Result is
     (Configured, Unchanged, Unsupported, Invalid_Value, Group_Already_Started, Runtime_Unavailable);
   --  Observed application state of a placement request.
   --  @enum Not_Requested No placement was configured
   --  @enum Pending_Startup The request is stored for lazy group startup
   --  @enum Applied The group thread applied the request
   --  @enum Failed The host call failed; inspect Error_Code
   --  @enum Unavailable The requested mechanism is unavailable
   type Placement_State is (Not_Requested, Pending_Startup, Applied, Failed, Unavailable);
   --  Current loop-thread placement status.
   --  @field Kind Requested host placement mechanism
   --  @field Value Requested CPU or advisory tag
   --  @field State Request lifecycle state
   --  @field Error_Code Host error for Failed, otherwise zero
   type Placement_Status is record
      Kind       : Loop_Thread_Placement := No_Placement;
      Value      : Placement_Value := 0;
      State      : Placement_State := Not_Requested;
      Error_Code : Integer := 0;
   end record;

   --  Current_Processor result when no supported stable query exists.
   No_Processor : constant Integer := -1;

   --  Raised when a group query, reservation, or pin operation cannot
   --  complete.
   Group_Error     : exception;
   --  Raised when the calling task cannot migrate to the requested group.
   Migration_Error : exception;

   --  Task-owned scope guard that keeps a lightweight task on its current
   --  scheduler thread. Pins nest and each object releases one level. Declare,
   --  use, and finalize it in the task that acquires it; do not transfer it.
   --  Native tasks accept pins as no-ops because their thread is permanent.
   --  @field Active Whether this object owns one pin level
   --  @field Owner Runtime identity of the acquiring task
   type Thread_Pin is limited private;

   --  Acquire one pin level for the calling task.
   --  @return Task-owned guard that releases the pin during finalization
   --  @exception Group_Error The runtime cannot pin the caller
   function Pin_To_Current_Thread return Thread_Pin;

   --  Report whether the caller is pinned. Native tasks always report True.
   --  @return True for a native task or a lightweight task with a live pin
   function Is_Thread_Pinned return Boolean;

   --  Convert an Ada CPU value in 1 .. 127 to its shared Flyology group.
   --  Constraint_Error reports a value outside that range, including the
   --  reserved Not_A_Specific_CPU, which names no group.
   --  @param CPU Ada CPU aspect value that names a shared group
   --  @return Shared group with the same numeric value
   function For_CPU (CPU : Group_Selecting_CPU) return Shared_Group_Id
   with Post => Integer (For_CPU'Result) = Integer (CPU);

   --  Return the calling lightweight task's current execution group.
   --  @return Current group identifier
   --  @exception Group_Error The caller is native or runtime result is invalid
   function Current return Group_Id;

   --  Return the automatic pool size without starting any group. The value of
   --  FLYOLOGY_LOOP_POOL_SIZE is captured once at process startup, defaults to
   --  one when absent, and establishes the initial size before task
   --  activation.
   --  Runtime growth or reduction may change it later. A lightweight task
   --  without a specific CPU is assigned among groups 0 .. Result - 1.
   --  @return Configured shared-group pool size
   --  @exception Group_Error The runtime reports an invalid size
   function Configured_Pool_Size return Loop_Pool_Size;

   --  Ensure the automatic pool contains at least Minimum_Size shared groups.
   --  Concurrent calls converge on the largest requested value. A request at
   --  or below the current size is an idempotent no-op. Growth is rejected
   --  while a reduction is still draining.
   --  Existing tasks remain on their current groups, while future automatic
   --  placements use the enlarged pool. Newly included groups remain lazy.
   --  Growing changes the modulus used by Topology.Shard_For_Hash.
   --  @param Minimum_Size Minimum automatic pool size after the call
   --  @exception Group_Error The runtime lifecycle does not permit growth
   procedure Grow_Configured_Pool (Minimum_Size : Loop_Pool_Size)
   with Post => Configured_Pool_Size >= Minimum_Size;

   --  Lower the ceiling used by future automatic placements immediately.
   --  Automatically managed tasks in removed groups migrate to Default_Group
   --  when they next become ready at an unpinned cooperative safe point.
   --  Waiting, pinned, or CPU-bound tasks may delay completion indefinitely.
   --  Tasks created with a CPU aspect or moved explicitly with Migrate remain
   --  where the caller put them and are reported as Explicit_Tasks.
   --  If migration is required, this call may synchronously start
   --  Default_Group as its drainage destination and wait for that startup. An
   --  already-drained request starts no group. The call does not wait for
   --  drainage and does not reclaim threads. Use Pool_Reduction to observe
   --  drainage with an application deadline.
   --  @param Maximum_Size New automatic-placement ceiling
   --  @return Whether reduction started, was already satisfied, or is busy
   --  @exception Group_Error The runtime lifecycle rejects the request
   function Request_Pool_Reduction (Maximum_Size : Loop_Pool_Size) return Pool_Reduction_Request_Result;

   --  Return a momentary reduction-progress snapshot without waiting. Calling
   --  this function also recognizes completion after the final task or
   --  pre-cutover placement claim drains.
   --  @return Current reduction lifecycle, target, and blocker counts
   --  @exception Group_Error The runtime cannot provide a valid snapshot
   function Pool_Reduction return Pool_Reduction_Status;

   --  Return the automatic policy without starting any group.
   --  @return Configured placement policy
   --  @exception Group_Error The runtime reports an unknown policy
   function Configured_Placement return Automatic_Placement_Policy;
   --  Test membership in the automatic pool without starting a group.
   --  @param Group Group to test
   --  @return True when Group is below Configured_Pool_Size
   --  @exception Group_Error The runtime reports an invalid pool size
   function In_Configured_Pool (Group : Group_Id) return Boolean;

   --  Configure a scheduler thread before Group starts. The same request is
   --  idempotent after startup; changing or clearing it then reports
   --  Group_Already_Started. Strict_CPU is a Linux OS CPU in the process's
   --  allowed set. Advisory_Tag must be positive. No_Placement requires zero.
   --  @param Group Execution group whose scheduler thread is configured
   --  @param Kind Host placement mechanism
   --  @param Value Linux logical CPU, Darwin advisory tag, or zero
   --  @return Explicit configuration result; this starts no group
   --  @exception Group_Error The runtime returns an unknown result
   function Configure_Loop_Thread
     (Group : Group_Id; Kind : Loop_Thread_Placement; Value : Placement_Value := 0)
      return Placement_Configuration_Result;

   --  Test whether the host supports Kind without starting a group.
   --  @param Kind Placement mechanism to test
   --  @return True when the current host supports Kind
   function Placement_Supported (Kind : Loop_Thread_Placement) return Boolean;
   --  Test a placement value without starting a group. On Linux this may
   --  lazily snapshot the process's inherited affinity allowance.
   --  @param Kind Placement mechanism
   --  @param Value Candidate CPU or advisory tag
   --  @return True when the host can accept the value
   function Placement_Value_Available (Kind : Loop_Thread_Placement; Value : Placement_Value) return Boolean;
   --  Observe Group's placement request without starting it.
   --  @param Group Execution group to inspect
   --  @return Current placement status
   --  @exception Group_Error The runtime query or returned encoding is invalid
   function Loop_Thread_Status (Group : Group_Id) return Placement_Status;

   --  Return the calling thread's current logical processor where the host
   --  provides a stable public query (Linux), otherwise No_Processor.
   --  @return Current zero-based logical CPU or No_Processor
   function Current_Processor return Integer;

   --  Reserve an empty reusable dedicated group for the calling lightweight
   --  task. Migrating out consumes the reservation; call Create_Dedicated
   --  again
   --  before re-entering a dedicated group. The same id is normally reused.
   --  @return Reserved group in 128 .. 255
   --  @exception Group_Error The caller is native or no group can be reserved
   function Create_Dedicated return Dedicated_Group_Id;

   --  Test the numeric group class; this starts no group.
   --  @param Group Group identifier to classify
   --  @return True for groups 128 .. 255
   function Is_Dedicated (Group : Group_Id) return Boolean;

   --  Migrate the calling lightweight task at this cooperative safe point and
   --  return on Group's scheduler thread. A live Thread_Pin prevents movement
   --  to another group. Native tasks cannot migrate because GNARL owns their
   --  stacks and threads. Leaving a dedicated group consumes its reservation.
   --  Migrate is a potentially blocking operation and must not be called
   --  inside a protected action: the protected object's lock belongs to the
   --  source event-loop thread and cannot follow the task. The call is not
   --  syntactically visible to GNAT's check on protected bodies, so a
   --  lightweight caller inside a protected action raises Program_Error
   --  before any movement, whatever Group names, and the normal unwinding
   --  releases the lock on the thread that holds it. A native caller inside
   --  a protected action keeps raising Migration_Error.
   --  @param Group Destination execution group
   --  @exception Migration_Error Caller is native, pinned, or cannot enter
   --     Group
   --  @exception Program_Error Lightweight caller is inside a protected
   --     action
   procedure Migrate (Group : Group_Id);

private
   type Thread_Pin is new Ada.Finalization.Limited_Controlled with record
      Active : Boolean := False;
      Owner  : System.Address := System.Null_Address;
   end record;

   --  Release Object's pin level on its acquiring task.
   --  @param Object Pin guard leaving scope
   overriding
   procedure Finalize (Object : in out Thread_Pin);

end Flyology.Execution_Groups;
