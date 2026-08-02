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
