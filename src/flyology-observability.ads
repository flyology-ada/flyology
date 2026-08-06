with Flyology.Execution_Groups;
with Interfaces;

package Flyology.Observability with Preelaborate is

   use type Interfaces.Unsigned_64;

   --  Exposes inert runtime snapshots for diagnostics and monitoring.
   --
   --  Example:
   --
   --     Available := Flyology.Observability.Snapshot (0, Current);

   --  Execution-group identifier used by observability calls.
   subtype Group_Id is Flyology.Execution_Groups.Group_Id;
   --  Unsigned process-lifetime counter; values wrap modulo Counter'Modulus.
   subtype Counter is Interfaces.Unsigned_64;

   --  Process-lifetime identity of one lightweight task instance. The value is
   --  diagnostic only: it is not an Ada Task_Id or a task-control handle.
   type Task_Instance_Id is new Interfaces.Unsigned_64;
   --  Sentinel that is never assigned to a lightweight task instance.
   No_Task_Instance : constant Task_Instance_Id := 0;

   --  Return the calling lightweight task's process-lifetime diagnostic
   --  identity without acquiring a runtime lock. A native task, including
   --  the environment task, receives No_Task_Instance.
   --  @return Calling lightweight task identity or No_Task_Instance
   function Current_Task_Instance return Task_Instance_Id;

   --  Scheduler state copied for one lightweight task.
   --  @enum Task_Ready The task is runnable
   --  @enum Task_Waiting The task is suspended
   --  @enum Task_Running The task is executing on its event loop
   --  @enum Task_Migrating The task is transferring between groups
   --  @enum Task_Finished The task body finished and awaits reap
   type Task_State is
     (Task_Ready,
      Task_Waiting,
      Task_Running,
      Task_Migrating,
      Task_Finished)
     with Convention => C;

   --  Bit set copied with a lightweight task snapshot.
   type Task_Flags is mod 2**32 with Size => 32, Convention => C;
   --  The task holds at least one thread pin.
   Task_Pinned_Flag : constant Task_Flags := 2#000001#;
   --  The task is registered in the group deadline heap.
   Task_Timer_Wait_Flag : constant Task_Flags := 2#000010#;
   --  The task is waiting for descriptor readiness.
   Task_Descriptor_Wait_Flag : constant Task_Flags := 2#000100#;
   --  The task owns an in-flight or queued file request.
   Task_File_Wait_Flag : constant Task_Flags := 2#001000#;
   --  The task's file request is queued for kernel submission.
   Task_File_Pending_Flag : constant Task_Flags := 2#010000#;
   --  Reap was requested while the fiber was still running or migrating.
   Task_Destroy_Requested_Flag : constant Task_Flags := 2#100000#;

   --  Copied diagnostic state for one lightweight task. Instance remains
   --  stable across migration and is never reused during the process lifetime.
   --  @field Instance Process-lifetime lightweight task instance identity
   --  @field State Scheduler state at the group snapshot instant
   --  @field Base_Priority Current GNARL base priority
   --  @field Flags Pinned, wait, pending-file, and deferred-reap flags
   --  @field Stack_Usable_Bytes Usable bytes in the guarded fiber stack
   type Task_Snapshot is record
      Instance           : Task_Instance_Id := No_Task_Instance;
      State              : Task_State := Task_Waiting;
      Base_Priority      : Interfaces.Integer_32 := 0;
      Flags              : Task_Flags := 0;
      Stack_Usable_Bytes : Counter := 0;
   end record with Convention => C;

   --  Caller-owned output buffer for bounded lightweight task enumeration.
   type Task_Snapshot_Array is array (Positive range <>) of Task_Snapshot
     with Convention => C;

   --  Test one flag in a copied task snapshot.
   --  @param Item Snapshot to inspect
   --  @param Flag Flag value to test
   --  @return True when Flag is set in Item
   function Has_Flag
     (Item : Task_Snapshot;
      Flag : Task_Flags) return Boolean
   is ((Item.Flags and Flag) /= 0);

   --  Lifecycle of one event-loop scheduler thread.
   --  @enum Starting The thread is entering scheduler startup
   --  @enum Running The scheduler loop is active
   --  @enum Failed Startup or scheduler execution failed
   type Event_Thread_State is (Starting, Running, Failed);
   --  Classification recorded immediately before a fatal runtime abort.
   --  @enum No_Fatal No fatal path has been recorded
   --  @enum Scheduler_Invariant A scheduler state invariant failed
   --  @enum Mutex_Failure A runtime mutex operation failed
   --  @enum Poller_Failure The host event poller failed
   --  @enum Context_Switch_Failure A fiber context transition failed
   --  @enum Fork_Child_Use Unsupported runtime use occurred after fork
   type Fatal_Context is
     (No_Fatal,
      Scheduler_Invariant,
      Mutex_Failure,
      Poller_Failure,
      Context_Switch_Failure,
      Fork_Child_Use);

   --  Consistent queue state plus cumulative counters for one permanent group.
   --  @field Group Execution group represented by the snapshot
   --  @field Thread_State Current scheduler-thread lifecycle state
   --  @field Dedicated Whether Group is in the dedicated range
   --  @field Reserved Whether a lightweight task currently reserves Group
   --  @field Members Current registered fibers in Group
   --  @field Pinned_Members Current fibers with at least one thread pin
   --  @field Ready Current runnable fibers
   --  @field Waiting Current suspended fibers
   --  @field Running Current executing fibers, normally zero or one
   --  @field Migrating Current fibers transferring to another group
   --  @field Finished Current fibers awaiting reap
   --  @field Timer_Waits Current timer-suspended fibers
   --  @field Descriptor_Waits Current single-descriptor waits
   --  @field Interrupt_Waits Current waits with cancellation descriptors
   --  @field File_Waits Current submitted file operations awaiting completion
   --  @field Pending_File_Submissions Current file requests queued for submit
   --  @field Dormancy_Candidates Timer-only waits safe for stack reclamation
   --  @field Dormancy_Candidate_Bytes Usable stack bytes of those candidates
   --  @field Cold_Stacks Current stacks with accepted cold or page-out advice
   --  @field Cold_Stack_Bytes Usable bytes in those currently advised stacks
   --  @field Cold_Advice_Attempts Cumulative host cold-advice calls
   --  @field Cold_Advice_Accepted Cumulative accepted cold-advice calls
   --  @field Cold_Advice_Failures Cumulative failed cold-advice calls
   --  @field Pageout_Advice_Attempts Cumulative host page-out-advice calls
   --  @field Pageout_Advice_Accepted Cumulative accepted page-out calls
   --  @field Pageout_Advice_Failures Cumulative failed page-out calls
   --  @field Dispatches Cumulative fiber dispatches
   --  @field Poll_Batches Cumulative event-poller batches
   --  @field Poll_Events Cumulative host events delivered
   --  @field Wakeups Cumulative task wake requests
   --  @field Migrations_In Cumulative migrations entering Group
   --  @field Migrations_Out Cumulative migrations leaving Group
   type Group_Snapshot is record
      Group                    : Group_Id;
      Thread_State             : Event_Thread_State;
      Dedicated                : Boolean;
      Reserved                 : Boolean;
      Members                  : Counter;
      Pinned_Members           : Counter;
      Ready                    : Counter;
      Waiting                  : Counter;
      Running                  : Counter;
      Migrating                : Counter;
      Finished                 : Counter;
      Timer_Waits              : Counter;
      Descriptor_Waits         : Counter;
      Interrupt_Waits          : Counter;
      File_Waits               : Counter;
      Pending_File_Submissions : Counter;
      Dormancy_Candidates      : Counter;
      Dormancy_Candidate_Bytes : Counter;
      Cold_Stacks              : Counter;
      Cold_Stack_Bytes         : Counter;
      Cold_Advice_Attempts     : Counter;
      Cold_Advice_Accepted     : Counter;
      Cold_Advice_Failures     : Counter;
      Pageout_Advice_Attempts  : Counter;
      Pageout_Advice_Accepted  : Counter;
      Pageout_Advice_Failures  : Counter;
      Dispatches               : Counter;
      Poll_Batches             : Counter;
      Poll_Events              : Counter;
      Wakeups                  : Counter;
      Migrations_In            : Counter;
      Migrations_Out           : Counter;
   end record;

   --  Process-wide lightweight stack allocator state and cumulative counters.
   --  @field Active_Arenas Current mapped stack arenas
   --  @field Live_Stacks Current allocated fiber stacks
   --  @field Live_Usable_Bytes Current requested usable stack bytes
   --  @field Reserved_Bytes Current virtual bytes reserved for arenas
   --  @field Arena_Mappings Cumulative arena mappings
   --  @field Arena_Unmappings Cumulative arena unmaps
   --  @field Shared_Stacks Cumulative stacks placed in an existing arena
   --  @field Discarded_Stacks Cumulative accepted MADV_DONTNEED releases
   type Stack_Pool_Snapshot is record
      Active_Arenas     : Counter;
      Live_Stacks       : Counter;
      Live_Usable_Bytes : Counter;
      Reserved_Bytes    : Counter;
      Arena_Mappings    : Counter;
      Arena_Unmappings  : Counter;
      Shared_Stacks     : Counter;
      Discarded_Stacks  : Counter;
   end record;

   --  Capture Group while holding its scheduler lock. The query is thread-safe
   --  and inert: it does not start a group or allocate scheduler resources.
   --  @param Group Execution group to observe
   --  @param Result Snapshot written when the group exists
   --  @return True when Group has been created; False otherwise
   --  @exception Program_Error Runtime and library observability ABIs differ
   function Snapshot
     (Group  : Group_Id;
      Result : out Group_Snapshot) return Boolean;

   --  Copy a bounded prefix of Group's lightweight task membership while
   --  holding the topology and selected group scheduler locks. No allocation
   --  or callback occurs while locked. List order is unspecified. Entries are
   --  coherent with one another, but a later call may observe migration,
   --  creation, or reap. Only Items (Items'First .. Items'First + Count - 1)
   --  is overwritten; the remainder retains its incoming value. Total reports
   --  the complete group membership, so Count < Total indicates truncation.
   --  @param Group Execution group to observe
   --  @param Items Caller-owned nonempty output buffer
   --  @param Count Number of entries copied into Items
   --  @param Total Complete group membership at the snapshot instant
   --  @return True when Group exists; False without starting event machinery
   --  @exception Constraint_Error Items is empty
   --  @exception Program_Error Runtime and library task snapshot ABIs differ
   function Snapshot_Tasks
     (Group : Group_Id;
      Items : in out Task_Snapshot_Array;
      Count : out Natural;
      Total : out Counter) return Boolean;

   --  Test whether dispatch or polling counters changed between snapshots.
   --  This avoids adding a clock read to each scheduler dispatch.
   --  @param Earlier Older snapshot of a group
   --  @param Later Newer snapshot of the same group
   --  @return True when dispatches, poll batches, or poll events advanced
   function Made_Progress
     (Earlier : Group_Snapshot;
      Later   : Group_Snapshot) return Boolean
   is (Later.Dispatches /= Earlier.Dispatches
       or else Later.Poll_Batches /= Earlier.Poll_Batches
       or else Later.Poll_Events /= Earlier.Poll_Events);

   --  Read the lock-free fatal classification retained before runtime abort.
   --  @return No_Fatal during normal execution, otherwise the last fatal class
   function Last_Fatal return Fatal_Context;

   --  Capture process-wide stack allocation without creating an event loop.
   --  Adjacent stacks share an inaccessible guard page and remain guarded on
   --  both sides. Empty arenas are unmapped. MADV_DONTNEED is best effort.
   --  The query is thread-safe.
   --  @return Current stack-pool state and cumulative counters
   --  @exception Program_Error Runtime and library stack-pool ABIs differ
   function Stack_Pool return Stack_Pool_Snapshot;

end Flyology.Observability;
