with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.Address_To_Access_Conversions;
with System.Flyology.Contexts;
with System.Flyology.File_Engine;
with System.Flyology.Faults;
with System.Flyology.Poller;
with System.Flyology.Placement_Config;
with System.Flyology.Pool_Config;
with System.Flyology.Scheduling_Policy;
with System.Flyology.Time_ABI;
with System.Storage_Elements;
with System.Tasking;

package body System.Flyology.Scheduler is
   package C renames Interfaces.C;
   package Contexts renames System.Flyology.Contexts;
   package File_Engines renames System.Flyology.File_Engine;
   package Faults renames System.Flyology.Faults;
   package Pollers renames System.Flyology.Poller;
   package Placement_Config renames System.Flyology.Placement_Config;
   package Pool_Config renames System.Flyology.Pool_Config;
   package Scheduling renames System.Flyology.Scheduling_Policy;
   package Time_ABI renames System.Flyology.Time_ABI;
   package OSI renames System.OS_Interface;
   package SSE renames System.Storage_Elements;

   use type C.int;
   use type C.char;
   use type C.long;
   use type C.long_long;
   use type C.size_t;
   use type C.unsigned;
   use type C.unsigned_long_long;
   use type Contexts.Context_Access;
   use type OSI.pthread_t;
   use type Pollers.Event_Kind;
   use type Pollers.Interest;
   use type Scheduling.Destruction_Plan;
   use type Scheduling.File_Cancel_Plan;
   use type Scheduling.Ready_Placement;
   use type Scheduling.Reduction_Phase;
   use type SSE.Integer_Address;
   use type SSE.Storage_Offset;

   Timer_Check_Interval : constant := 64;
   Poll_Event_Budget    : constant := 64;
   No_Deadline          : constant Duration := Scheduling.No_Deadline;
   --  One nanosecond as a Duration. Rendering accumulated loop time for the
   --  observability ABI divides by this, matching Flyology.Time_Math.
   Nanosecond           : constant Duration := 0.000_000_001;
   --  Absent monotonic timestamp. The platform monotonic clock never returns
   --  a negative reading, so this cannot collide with a real one.
   No_Timestamp         : constant Duration := -1.0;

   Dedicated_First_Id : constant C.int := Scheduling.First_Dedicated_Group;
   Maximum_Group_Id   : constant C.int := Scheduling.Last_Group;
   subtype Group_Index is Natural range 0 .. Natural (Maximum_Group_Id);

   No_Placement_Mode : constant C.int := 0;
   Strict_CPU_Mode   : constant C.int := 1;
   Advisory_Tag_Mode : constant C.int := 2;
   subtype Placement_Request is Placement_Config.Placement_Request;
   subtype Placement_Request_Array is Placement_Config.Placement_Request_Array;

   type Runtime_Placement_Status is record
      Mode       : C.int;
      Value      : C.int;
      State      : C.int;
      Error_Code : C.int;
   end record;
   pragma Convention (C, Runtime_Placement_Status);
   type Runtime_Placement_Status_Access is access all Runtime_Placement_Status;
   function To_Runtime_Placement_Status is new
     Ada.Unchecked_Conversion (System.Address, Runtime_Placement_Status_Access);

   type Runtime_Pool_Reduction_Status is record
      Phase                   : C.int;
      Target_Size             : C.int;
      Automatic_Tasks         : C.unsigned_long_long;
      Pinned_Automatic_Tasks  : C.unsigned_long_long;
      Waiting_Automatic_Tasks : C.unsigned_long_long;
      Explicit_Tasks          : C.unsigned_long_long;
      Placement_Claims        : C.unsigned_long_long;
   end record
   with Convention => C;
   type Runtime_Pool_Reduction_Status_Access is access all Runtime_Pool_Reduction_Status;
   function To_Runtime_Pool_Reduction_Status is new
     Ada.Unchecked_Conversion (System.Address, Runtime_Pool_Reduction_Status_Access);

   --  A prime-sized table avoids clustering when aligned ATCB allocations
   --  advance by a regular stride. For the expected task populations,
   --  separate chaining keeps lookup and removal constant-time on average
   --  without introducing resize allocation into wake paths.
   Registry_Bucket_Count  : constant := 16_381;
   subtype Registry_Bucket_Index is Natural range 0 .. Registry_Bucket_Count - 1;
   Registry_Shard_Count   : constant := 64;
   subtype Registry_Shard_Index is Natural range 0 .. Registry_Shard_Count - 1;
   Instance_Shard_Span    : constant C.unsigned_long_long := 2**58;
   Instance_Sequence_Last : constant C.unsigned_long_long := Instance_Shard_Span - 1;
   --  Readiness is local to a loop, so each group owns a smaller prime-sized
   --  descriptor table. Collision chains also represent legitimate fan-out
   --  when several tasks wait on the same descriptor and direction.
   IO_Bucket_Count        : constant := 8_191;
   subtype IO_Bucket_Index is Natural range 0 .. IO_Bucket_Count - 1;
   --  One completion-set operation can arm six transport, protocol, source,
   --  and lifecycle interests. Keep parity with Flyology.IO.Max_Wait_Requests.
   Max_IO_Link_Count      : constant := 192;
   subtype IO_Link_Kind is Positive range 1 .. Max_IO_Link_Count;
   Primary_IO             : constant IO_Link_Kind := 1;

   type Runtime_Wait_Request is record
      Descriptor : C.int;
      For_Write  : C.int;
   end record
   with Convention => C;
   type Runtime_Wait_Request_Array is array (Natural range <>) of Runtime_Wait_Request with Convention => C;
   package C_Char_Conversions is new System.Address_To_Access_Conversions (C.char);
   package Wait_Request_Conversions is new System.Address_To_Access_Conversions (Runtime_Wait_Request);

   type Fiber_State is (Running, Ready, Waiting, Migrating, Finished);
   type Dormancy_Advice is (Prompt_Advice, Cold_Advice, Pageout_Advice);

   function Phase_Of (State : Fiber_State) return Scheduling.Fiber_Phase
   is (case State is
         when Running   => Scheduling.Running,
         when Ready     => Scheduling.Ready,
         when Waiting   => Scheduling.Waiting,
         when Migrating => Scheduling.Migrating,
         when Finished  => Scheduling.Finished);

   type Fiber;
   type Fiber_Access is access all Fiber;

   Async_File_Node_Version : constant C.unsigned := 2;
   Async_File_Unused       : constant C.int := 0;
   Async_File_Submitted    : constant C.int := 1;
   Async_File_Cancelling   : constant C.int := 2;
   Async_File_Terminal     : constant C.int := 3;
   Async_File_Queued       : constant C.int := 4;

   type Async_File_Node is record
      Version          : C.unsigned := Async_File_Node_Version;
      State            : C.int := Async_File_Unused with Atomic;
      Owner            : System.Address := System.Null_Address;
      Descriptor       : C.int := -1;
      Buffer           : System.Address := System.Null_Address;
      Length           : C.size_t := 0;
      Offset           : C.long_long := 0;
      For_Write        : C.int := 0;
      Signal_FD        : C.int := -1;
      Result           : C.long_long := 0;
      Error_Code       : C.int := 0;
      Cancelled        : C.int := 0;
      Cancel_Requested : C.int := 0;
      Next             : System.Address := System.Null_Address;
   end record
   with Convention => C;
   type Async_File_Node_Access is access all Async_File_Node;
   function To_Async_File_Node is new Ada.Unchecked_Conversion (System.Address, Async_File_Node_Access);

   type Loop_Group;
   type Loop_Group_Access is access all Loop_Group;
   subtype Ready_Priority is
     C.int range C.int (System.Any_Priority'First) .. C.int (System.Any_Priority'Last);
   type Ready_Bucket is record
      Head : Fiber_Access;
      Tail : Fiber_Access;
   end record;
   type Ready_Bucket_Array is array (Ready_Priority) of Ready_Bucket;
   type IO_Wait_Link;
   type IO_Wait_Link_Access is access all IO_Wait_Link;
   type IO_Wait_Link is record
      Owner      : Fiber_Access := null;
      Descriptor : C.int := -1;
      Interest   : Pollers.Interest := Pollers.Readable;
      Kind       : IO_Link_Kind := Primary_IO;
      Outcome    : C.int := 0;
      Bucket     : IO_Bucket_Index := 0;
      Registered : Boolean := False;
      Next       : IO_Wait_Link_Access := null;
   end record;
   type IO_Wait_Link_Array is array (IO_Link_Kind range <>) of aliased IO_Wait_Link;
   package IO_Link_Conversions is new System.Address_To_Access_Conversions (IO_Wait_Link);
   function To_IO_Link_Access is new
     Ada.Unchecked_Conversion (IO_Link_Conversions.Object_Pointer, IO_Wait_Link_Access);
   type IO_Bucket_Array is array (IO_Bucket_Index) of IO_Wait_Link_Access;
   type Timer_Heap_Array is array (Positive range <>) of Fiber_Access;
   type Timer_Heap_Access is access Timer_Heap_Array;

   type Runtime_Group_Snapshot is record
      ABI_Version              : C.unsigned;
      Thread_State             : C.int;
      Dedicated                : C.int;
      Reserved                 : C.int;
      Members                  : C.unsigned_long_long;
      Pinned_Members           : C.unsigned_long_long;
      Ready                    : C.unsigned_long_long;
      Waiting                  : C.unsigned_long_long;
      Running                  : C.unsigned_long_long;
      Migrating                : C.unsigned_long_long;
      Finished                 : C.unsigned_long_long;
      Timer_Waits              : C.unsigned_long_long;
      Descriptor_Waits         : C.unsigned_long_long;
      Interrupt_Waits          : C.unsigned_long_long;
      File_Waits               : C.unsigned_long_long;
      Pending_File_Submissions : C.unsigned_long_long;
      Dormancy_Candidates      : C.unsigned_long_long;
      Dormancy_Candidate_Bytes : C.unsigned_long_long;
      Cold_Stacks              : C.unsigned_long_long;
      Cold_Stack_Bytes         : C.unsigned_long_long;
      Cold_Advice_Attempts     : C.unsigned_long_long;
      Cold_Advice_Accepted     : C.unsigned_long_long;
      Cold_Advice_Failures     : C.unsigned_long_long;
      Pageout_Advice_Attempts  : C.unsigned_long_long;
      Pageout_Advice_Accepted  : C.unsigned_long_long;
      Pageout_Advice_Failures  : C.unsigned_long_long;
      Dispatches               : C.unsigned_long_long;
      Poll_Batches             : C.unsigned_long_long;
      Poll_Events              : C.unsigned_long_long;
      Wakeups                  : C.unsigned_long_long;
      Migrations_In            : C.unsigned_long_long;
      Migrations_Out           : C.unsigned_long_long;
      Uptime_Nanoseconds       : C.unsigned_long_long;
      Idle_Nanoseconds         : C.unsigned_long_long;
      Idle_Waits               : C.unsigned_long_long;
   end record;
   pragma Convention (C, Runtime_Group_Snapshot);
   type Runtime_Group_Snapshot_Access is access all Runtime_Group_Snapshot;
   function To_Runtime_Group_Snapshot is new
     Ada.Unchecked_Conversion (System.Address, Runtime_Group_Snapshot_Access);

   Task_Snapshot_ABI_Version : constant C.unsigned := 1;
   type Runtime_Task_Snapshot is record
      Instance           : C.unsigned_long_long;
      State              : C.int;
      Base_Priority      : C.int;
      Flags              : C.unsigned;
      Stack_Usable_Bytes : C.unsigned_long_long;
   end record
   with Convention => C;
   type Runtime_Task_Snapshot_Access is access all Runtime_Task_Snapshot;
   function To_Runtime_Task_Snapshot is new
     Ada.Unchecked_Conversion (System.Address, Runtime_Task_Snapshot_Access);

   type Runtime_Task_Snapshot_Metadata is record
      Version : C.unsigned;
      Written : C.unsigned_long_long;
      Total   : C.unsigned_long_long;
   end record
   with Convention => C;
   type Runtime_Task_Snapshot_Metadata_Access is access all Runtime_Task_Snapshot_Metadata;
   function To_Runtime_Task_Snapshot_Metadata is new
     Ada.Unchecked_Conversion (System.Address, Runtime_Task_Snapshot_Metadata_Access);

   Task_Pinned_Flag            : constant C.unsigned := 2#000001#;
   Task_Timer_Wait_Flag        : constant C.unsigned := 2#000010#;
   Task_Descriptor_Wait_Flag   : constant C.unsigned := 2#000100#;
   Task_File_Wait_Flag         : constant C.unsigned := 2#001000#;
   Task_File_Pending_Flag      : constant C.unsigned := 2#010000#;
   Task_Destroy_Requested_Flag : constant C.unsigned := 2#100000#;

   type Fiber is record
      T                       : System.Address := System.Null_Address;
      Instance                : C.unsigned_long_long := 0;
      --  This fiber's most recent live nested-subprogram trampoline, which
      --  links back through the ones it still holds. The compiler's helper
      --  releases trampolines in stack order, an order that holds within a
      --  fiber but not within an event-loop thread shared by several. The
      --  scheduler releases whatever remains when the fiber is reaped.
      Trampoline_Control      : aliased System.Address := System.Null_Address;
      Context                 : Contexts.Context_Access;
      Wrapper                 : System.Address := System.Null_Address;
      Priority                : C.int := 0;
      Deadline                : Duration := No_Deadline;
      Timer_Index             : Natural := 0;
      Timed_Out               : Boolean := False;
      State                   : Fiber_State := Waiting;
      IO_Wait                 : Boolean := False;
      IO_Interrupt_Wait       : Boolean := False;
      IO_Result               : C.int := 0;
      Descriptor_Cancel_Queued : Boolean := False;
      --  File cancellation needs one descriptor link that outlives the
      --  submission call. Descriptor-set waits keep their bounded link array
      --  on the suspended fiber's stack instead.
      Inline_IO_Links         : aliased IO_Wait_Link_Array (1 .. 1);
      Active_IO_Links         : IO_Wait_Link_Access := null;
      Active_IO_Link_Count    : Natural range 0 .. Max_IO_Link_Count := 0;
      File_Wait               : Boolean := False;
      File_Pending            : Boolean := False;
      File_Result             : C.long_long := 0;
      File_Error              : C.int := 0;
      File_Descriptor         : C.int := -1;
      File_Buffer             : System.Address := System.Null_Address;
      File_Length             : C.size_t := 0;
      File_Offset             : C.long_long := 0;
      File_For_Write          : Boolean := False;
      File_Send_ZC            : Boolean := False;
      File_Cancel_Descriptor  : C.int := -1;
      File_Cancel_Requested   : Boolean := False;
      File_Cancel_Queued      : Boolean := False;
      File_Cancel_Disposition : C.int := 0;
      File_Cancel_Error       : C.int := 0;
      Active_Async_Files      : Natural := 0;
      Destroy_Requested       : Boolean := False;
      Reaping                 : Boolean := False;
      Can_Migrate             : Boolean := True;
      Automatic_Placement     : Boolean := False;
      Thread_Pin_Count        : Natural := 0;
      Dormancy_Policy         : Dormancy_Advice := Prompt_Advice;
      Dormancy_Minimum_Wait   : Duration := 1.0;
      Stack_Cold              : Boolean := False;
      --  RM D.2.2(9) puts a runnable task at the head of its new priority
      --  queue when it loses inherited priority.  GNARL can report that
      --  transition while this fiber is still running, so remember it until
      --  the next scheduler handoff.
      Enqueue_At_Head         : Boolean := False;
      Group                   : Loop_Group_Access;
      Migration_Target        : Loop_Group_Access;
      Reserved_Group          : Loop_Group_Access;
      Previous_Ready          : Fiber_Access;
      Next_Ready              : Fiber_Access;
      Previous_Group          : Fiber_Access;
      Next_Group              : Fiber_Access;
      Next_File               : Fiber_Access;
      Next_File_Cancel        : Fiber_Access;
      Next_Descriptor_Cancel  : Fiber_Access;
      Next_Registry           : Fiber_Access;
      Registry_Bucket         : Registry_Bucket_Index := 0;
      Registry_Shard          : Registry_Shard_Index := 0;
   end record;

   --  Older Darwin System.OS_Locks representations omit the leading
   --  eight-byte pthread signature. Keep tail storage after every scheduler
   --  mutex so libSystem can use the complete native object on that runtime;
   --  the padding is harmless for runtimes whose binding is already exact.
   type Scheduler_Mutex is limited record
      Value        : aliased OSI.pthread_mutex_t;
      Tail_Padding : SSE.Storage_Array (1 .. 8);
   end record;

   type Loop_Group is limited record
      Id                       : C.int := -1;
      Dedicated                : Boolean := False;
      Lock                     : Scheduler_Mutex;
      Started                  : Boolean := False with Volatile;
      Start_Failed             : Boolean := False with Volatile;
      Event_Thread             : aliased OSI.pthread_t;
      Placement_Mode           : C.int := No_Placement_Mode;
      Placement_Value          : C.int := 0;
      Placement_Result         : C.int := 0;
      Placement_Applied        : Boolean := False;
      Scheduler_Context        : Contexts.Context_Access;
      Scheduler_Poller         : Pollers.Poller;
      Current_Fiber            : Fiber_Access;
      --  The fiber this group's event thread has handed control to. Unlike
      --  Current_Fiber it is cleared the moment the fiber suspends, so
      --  scheduler work is never charged to a fiber's trampoline cursor. Only
      --  the group's own event thread touches it.
      Trampoline_Fiber         : Fiber_Access;
      Ready_Buckets            : Ready_Bucket_Array := (others => (Head => null, Tail => null));
      Ready_Count              : Natural := 0;
      Highest_Ready            : Ready_Priority := Ready_Priority'First;
      Fibers                   : Fiber_Access;
      IO_Waiters               : IO_Bucket_Array := (others => null);
      Pending_File_Head        : Fiber_Access;
      Pending_File_Tail        : Fiber_Access;
      Pending_Async_File_Head  : Async_File_Node_Access;
      Pending_Async_File_Tail  : Async_File_Node_Access;
      Pending_Async_File_Count : Natural := 0;
      File_Cancel_Head         : Fiber_Access;
      File_Cancel_Tail         : Fiber_Access;
      Descriptor_Cancel_Head   : Fiber_Access;
      Descriptor_Cancel_Tail   : Fiber_Access;
      Timers                   : Timer_Heap_Access;
      Timer_Count              : Natural := 0;
      Timer_Capacity           : Natural := 0;
      Member_Count             : Natural := 0;
      Reserved_For             : System.Address := System.Null_Address;
      Dispatches               : C.unsigned_long_long := 0;
      Poll_Batches             : C.unsigned_long_long := 0;
      Poll_Events              : C.unsigned_long_long := 0;
      Wakeups                  : C.unsigned_long_long := 0;
      Migrations_In            : C.unsigned_long_long := 0;
      Migrations_Out           : C.unsigned_long_long := 0;
      Cold_Stacks              : C.unsigned_long_long := 0;
      Cold_Stack_Bytes         : C.unsigned_long_long := 0;
      Cold_Advice_Attempts     : C.unsigned_long_long := 0;
      Cold_Advice_Accepted     : C.unsigned_long_long := 0;
      Cold_Advice_Failures     : C.unsigned_long_long := 0;
      Pageout_Advice_Attempts  : C.unsigned_long_long := 0;
      Pageout_Advice_Accepted  : C.unsigned_long_long := 0;
      Pageout_Advice_Failures  : C.unsigned_long_long := 0;
      --  Loop utilization accounting. The event thread stamps Started_At once
      --  before its first dispatch and accumulates only the intervals it
      --  spends blocked in the poller with no ready fiber to run. A wait that
      --  has not returned yet stays in Idle_Since so an observer can add it
      --  instead of reporting a long block as busy time. The event thread
      --  writes all four under this group's lock, where observers read them.
      Started_At               : Duration := No_Timestamp;
      Idle_Time                : Duration := 0.0;
      Idle_Since               : Duration := No_Timestamp;
      Idle_Waits               : C.unsigned_long_long := 0;
      --  Signal stacks belong to OS threads, not fibers. Keeping one with
      --  each permanent loop prevents Task_Wrapper from reserving and
      --  installing 32 KiB inside every lightweight task stack.
      Signal_Stack             : aliased SSE.Storage_Array (1 .. OSI.Alternate_Stack_Size);
      Stop_Requested           : Boolean := False;
   end record;

   type Group_Array is array (Group_Index) of Loop_Group_Access;
   type Automatic_Claim_Array is array (Group_Index) of Natural;
   type Registry_Bucket_Array is array (Registry_Bucket_Index) of Fiber_Access;
   type Registry_Shard_Lock_Array is array (Registry_Shard_Index) of Scheduler_Mutex;
   type Registry_Instance_Array is array (Registry_Shard_Index) of C.unsigned_long_long;
   type Registry_Creator_Array is array (Registry_Shard_Index) of Natural;

   Placement_Requests              : Placement_Request_Array;
   Placement_Platform_Initialized  : Boolean := False;
   Placement_Initialization_Result : C.int := 0;

   function Fiber_To_Address is new Ada.Unchecked_Conversion (Fiber_Access, System.Address);
   function Address_To_Fiber is new Ada.Unchecked_Conversion (System.Address, Fiber_Access);
   function Group_To_Address is new Ada.Unchecked_Conversion (Loop_Group_Access, System.Address);
   function Address_To_Group is new Ada.Unchecked_Conversion (System.Address, Loop_Group_Access);
   function Address_To_Task_Id is new Ada.Unchecked_Conversion (System.Address, System.Tasking.Task_Id);
   function Async_File_Token (Node : System.Address) return System.Address
   is (Node + SSE.Storage_Offset (1));
   function Async_File_Node_Address (Token : System.Address) return System.Address
   is (Token - SSE.Storage_Offset (1));
   function Is_Async_File_Token (Token : System.Address) return Boolean
   is (SSE.To_Integer (Token) mod 2 = 1);
   procedure Free_Fiber is new Ada.Unchecked_Deallocation (Fiber, Fiber_Access);
   procedure Free_Group is new Ada.Unchecked_Deallocation (Loop_Group, Loop_Group_Access);
   procedure Free_Timer_Heap is new Ada.Unchecked_Deallocation (Timer_Heap_Array, Timer_Heap_Access);

   --  Each registry shard protects its hash chains, fiber lifetime, and the
   --  Fiber.Group ownership pointer. Topology_Lock protects the group table,
   --  startup state, and dedicated reservations. A group lock protects that
   --  group's membership count, fiber list, ready queue, timers, I/O state,
   --  and current fiber. Code needing all three takes shard, topology, group.
   --  Hot Wake and Set_Priority paths take only one shard and one group.
   Topology_Lock              : Scheduler_Mutex;
   Registry_Shard_Locks       : Registry_Shard_Lock_Array;
   Registry_Instances         : Registry_Instance_Array := (others => 0);
   --  Creates that passed the lifecycle guard and may still name, read, or
   --  lock an execution group. Guarded by the matching shard lock, so
   --  Finalize observes every claim while it holds all shards.
   Registry_Creators          : Registry_Creator_Array := (others => 0);
   Initialized                : Boolean := False;
   Event_Runtime_Active       : C.int := 0;
   pragma Atomic (Event_Runtime_Active);
   --  0 dormant, 1 running, 2 finalizing, 3 stopped, 4 cleanup deferred.
   Lifecycle_State            : C.int := 0;
   pragma Atomic (Lifecycle_State);
   Created_Group_Count        : C.int := 0;
   pragma Atomic (Created_Group_Count);
   Fork_Child_State           : C.int := 0;
   pragma Atomic (Fork_Child_State);
   Last_Fatal_Context         : C.int := 0;
   pragma Atomic (Last_Fatal_Context);
   Groups                     : Group_Array := (others => null);
   Fiber_Registry             : Registry_Bucket_Array := (others => null);
   Automatic_Pool_Size        : Positive := Pool_Config.Prepared_Pool_Size;
   pragma Atomic (Automatic_Pool_Size);
   Automatic_Placement_Claims : Automatic_Claim_Array := (others => 0);
   --  Reduction fields are written under Topology_Lock. Event loops read the
   --  atomics only to decide whether a ready fiber should be transferred at
   --  the next cooperative dispatch point.
   Reduction_Phase_Code       : C.int := C.int (Scheduling.Reduction_Phase'Pos (Scheduling.No_Reduction));
   pragma Atomic (Reduction_Phase_Code);
   Reduction_Target           : C.int := C.int (Pool_Config.Prepared_Pool_Size);
   pragma Atomic (Reduction_Target);
   Reduction_Destination      : System.Address := System.Null_Address;
   pragma Atomic (Reduction_Destination);
   Next_Automatic_Group       : C.unsigned_long_long := 0;
   Thread_Group               : Loop_Group_Access := null;
   pragma Thread_Local_Storage (Thread_Group);

   function Mutex_Unlock (Mutex : System.Address) return C.int;
   pragma Import (C, Mutex_Unlock, "pthread_mutex_unlock");
   function Mutex_Lock (Mutex : System.Address) return C.int;
   pragma Import (C, Mutex_Lock, "pthread_mutex_lock");
   function Sched_Yield return C.int;
   pragma Import (C, Sched_Yield, "sched_yield");
   function Micro_Sleep (Microseconds : C.unsigned) return C.int;
   pragma Import (C, Micro_Sleep, "usleep");
   function C_Getenv (Name : System.Address) return System.Address;
   pragma Import (C, C_Getenv, "getenv");

   function Initialize_Thread_Placement return C.int;
   pragma Import (C, Initialize_Thread_Placement, "flyology_thread_placement_initialize");
   function Thread_Placement_Supported (Mode : C.int) return C.int;
   pragma Import (C, Thread_Placement_Supported, "flyology_thread_placement_supported");
   function Validate_Thread_Placement (Mode : C.int; Value : C.int) return C.int;
   pragma Import (C, Validate_Thread_Placement, "flyology_thread_placement_validate");
   function Apply_Thread_Placement (Mode : C.int; Value : C.int) return C.int;
   pragma Import (C, Apply_Thread_Placement, "flyology_thread_placement_apply");
   function Thread_Current_Processor return C.int;
   pragma Import (C, Thread_Current_Processor, "flyology_thread_current_processor");

   --  Return every trampoline a reaped fiber still holds to the pool it came
   --  from. The host bridge owns nothing on platforms where GNAT does not
   --  allocate trampolines off the stack, where this is a no-op.
   procedure Release_Heap_Trampolines (Control : System.Address);
   pragma Import (C, Release_Heap_Trampolines, "flyology_heap_trampoline_release");

   procedure Scheduler_Main (Argument : System.Address);
   pragma Convention (C, Scheduler_Main);

   function Group_Thread (Argument : System.Address) return System.Address;
   pragma Convention (C, Group_Thread);

   procedure Fiber_Main (Argument : System.Address);
   pragma Convention (C, Fiber_Main);
   pragma No_Return (Fiber_Main);

   procedure Lock_Topology;
   procedure Unlock_Topology;
   procedure Lock_Registry_Shard (Shard : Registry_Shard_Index);
   procedure Unlock_Registry_Shard (Shard : Registry_Shard_Index);
   procedure Lock_Group (Group : not null Loop_Group_Access);
   procedure Unlock_Group (Group : not null Loop_Group_Access);
   function Outstanding_Create_Claims return Natural;
   function Drained_Create_Claims return Natural;
   Scheduler_Invariant : constant C.int := 1;
   Mutex_Failure       : constant C.int := 2;
   Poller_Failure      : constant C.int := 3;
   Context_Failure     : constant C.int := 4;
   Fork_Child_Failure  : constant C.int := 5;

   procedure Fatal (Context : C.int := Scheduler_Invariant);
   pragma No_Return (Fatal);
   function Ensure_Group (Id : C.int; Dedicated : Boolean) return Loop_Group_Access;
   function Ensure_Placement_Platform return C.int;
   function Select_Automatic_Group return C.int;
   procedure Release_Automatic_Placement_Claim (Group : C.int);
   procedure Count_Pool_Reduction_Population_Locked
     (Target_Size      : C.int;
      Automatic_Tasks  : out Natural;
      Pinned_Tasks     : out Natural;
      Waiting_Tasks    : out Natural;
      Explicit_Tasks   : out Natural;
      Placement_Claims : out Natural);
   procedure Collect_Pool_Reduction_Status_Locked (Status : out Runtime_Pool_Reduction_Status);
   function Startup_Pool_Size return C.int;
   --  Registry operations require the bucket's shard lock after bootstrap
   --  publishes Initialized. The environment task is deliberately absent
   --  from this registry: only lightweight tasks become fibers.
   function Registry_Bucket_For (T : System.Address) return Registry_Bucket_Index;
   function Registry_Shard_For (T : System.Address) return Registry_Shard_Index;
   function Find (T : System.Address) return Fiber_Access;
   procedure Register_Locked (Item : not null Fiber_Access);
   procedure Unregister_Locked (Item : not null Fiber_Access);
   function IO_Bucket_For (Descriptor : C.int) return IO_Bucket_Index;
   function Active_IO_Link (Item : not null Fiber_Access; Kind : IO_Link_Kind) return IO_Wait_Link_Access;
   function IO_Interest_Registered_Locked
     (Group : not null Loop_Group_Access; Descriptor : C.int; Interest : Pollers.Interest) return Boolean;
   procedure Register_IO_Wait_Locked
     (Group      : not null Loop_Group_Access;
      Item       : not null Fiber_Access;
      Descriptor : C.int;
      Interest   : Pollers.Interest;
      Kind       : IO_Link_Kind;
      Outcome    : C.int);
   procedure Remove_IO_Waits_Locked
     (Group               : not null Loop_Group_Access;
      Item                : not null Fiber_Access;
      Consumed_Descriptor : C.int := -1;
      Read_Consumed       : Boolean := False;
      Write_Consumed      : Boolean := False);
   procedure Queue_Descriptor_Cancel_Locked
     (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   procedure Process_Descriptor_Cancellations_Locked (Group : not null Loop_Group_Access);
   procedure Queue_Pending_File_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   procedure Remove_Pending_File_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   procedure Queue_File_Cancel_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   procedure Remove_File_Cancel_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   procedure Complete_File_Locked
     (Group     : not null Loop_Group_Access;
      Item      : not null Fiber_Access;
      Result    : C.long_long;
      Error     : C.int;
      Cancelled : Boolean);
   function Request_File_Cancel_Locked
     (Group : not null Loop_Group_Access; Item : not null Fiber_Access) return Boolean;
   procedure Process_File_Cancellations_Locked (Group : not null Loop_Group_Access);
   procedure Submit_Pending_Files_Locked (Group : not null Loop_Group_Access);
   procedure Submit_Pending_Async_Files_Locked (Group : not null Loop_Group_Access);
   function Is_Event_Thread return Boolean;
   procedure Signal_Async_File (Node : not null Async_File_Node_Access);
   procedure Complete_Async_File_Locked
     (Group     : not null Loop_Group_Access;
      Node      : not null Async_File_Node_Access;
      Result    : C.long_long;
      Error     : C.int;
      Cancelled : Boolean);
   function Start_Async_File
     (Node       : System.Address;
      Node_Size  : C.size_t;
      Descriptor : C.int;
      Buffer     : System.Address;
      Length     : C.size_t;
      Offset     : C.long_long;
      For_Write  : C.int;
      Signal_FD  : C.int) return C.int
   is
      Group : constant Loop_Group_Access := Thread_Group;
      Item  : Fiber_Access;
      Value : Async_File_Node_Access;
      Error : C.int := 0;
   begin
      if not Is_Event_Thread
        or else Group = null
        or else Group.Current_Fiber = null
        or else Node = System.Null_Address
        or else Node_Size /= C.size_t (Async_File_Node'Size / System.Storage_Unit)
        or else SSE.To_Integer (Node) mod Async_File_Node'Alignment /= 0
        or else Descriptor < 0
        or else Buffer = System.Null_Address
        or else Length = 0
        or else Signal_FD < 0
      then
         return -1;
      end if;
      Value := To_Async_File_Node (Node);
      if Value = null
        or else Value.Version /= Async_File_Node_Version
        or else Value.State /= Async_File_Unused
      then
         return -1;
      end if;

      Lock_Group (Group);
      Item := Group.Current_Fiber;
      if Item = null or else Item.State /= Running then
         Unlock_Group (Group);
         return -1;
      end if;
      Value.Owner := Fiber_To_Address (Item);
      Value.Descriptor := Descriptor;
      Value.Buffer := Buffer;
      Value.Length := Length;
      Value.Offset := Offset;
      Value.For_Write := For_Write;
      Value.Signal_FD := Signal_FD;
      Value.Result := 0;
      Value.Error_Code := 0;
      Value.Cancelled := 0;
      Value.Cancel_Requested := 0;
      Value.Next := System.Null_Address;
      Value.State := Async_File_Submitted;
      if not Pollers.Submit_File
               (Group.Scheduler_Poller,
                Descriptor,
                Buffer,
                Length,
                Offset,
                For_Write /= 0,
                Async_File_Token (Node),
                Error)
      then
         if Error = C.int (OSI.EAGAIN) then
            Value.State := Async_File_Queued;
            if Group.Pending_Async_File_Tail = null then
               Group.Pending_Async_File_Head := Value;
            else
               Group.Pending_Async_File_Tail.Next := Node;
            end if;
            Group.Pending_Async_File_Tail := Value;
            Group.Pending_Async_File_Count := Group.Pending_Async_File_Count + 1;
         else
            Value.Error_Code := Error;
            Value.Descriptor := -1;
            Value.Buffer := System.Null_Address;
            Value.Length := 0;
            Value.State := Async_File_Terminal;
            Unlock_Group (Group);
            return -1;
         end if;
      end if;
      Item.Active_Async_Files := Item.Active_Async_Files + 1;
      Unlock_Group (Group);
      return 0;
   end Start_Async_File;

   function Cancel_Async_File (Node : System.Address; Node_Size : C.size_t) return C.int is
      Group          : constant Loop_Group_Access := Thread_Group;
      Item           : Fiber_Access;
      Value          : Async_File_Node_Access;
      Completion     : File_Engines.Completion;
      Has_Completion : Boolean;
      Error          : C.int;
      Disposition    : File_Engines.Cancellation_Disposition;
      pragma Unreferenced (Disposition);
   begin
      if not Is_Event_Thread
        or else Group = null
        or else Group.Current_Fiber = null
        or else Node = System.Null_Address
        or else Node_Size /= C.size_t (Async_File_Node'Size / System.Storage_Unit)
        or else SSE.To_Integer (Node) mod Async_File_Node'Alignment /= 0
      then
         return -1;
      end if;
      Value := To_Async_File_Node (Node);
      if Value = null or else Value.Version /= Async_File_Node_Version then
         return -1;
      elsif Value.State = Async_File_Terminal then
         return 0;
      elsif Value.State = Async_File_Cancelling then
         return 0;
      elsif Value.State not in Async_File_Submitted | Async_File_Queued then
         return -1;
      end if;

      Lock_Group (Group);
      Item := Group.Current_Fiber;
      if Item = null or else Value.Owner /= Fiber_To_Address (Item) or else Item.Active_Async_Files = 0 then
         Unlock_Group (Group);
         return -1;
      end if;
      Value.Cancel_Requested := 1;
      if Value.State = Async_File_Queued then
         declare
            Position : Async_File_Node_Access := Group.Pending_Async_File_Head;
            Previous : Async_File_Node_Access := null;
         begin
            while Position /= null and then Position /= Value loop
               Previous := Position;
               Position := To_Async_File_Node (Position.Next);
            end loop;
            if Position = null or else Group.Pending_Async_File_Count = 0 then
               Fatal;
            elsif Previous = null then
               Group.Pending_Async_File_Head := To_Async_File_Node (Value.Next);
            else
               Previous.Next := Value.Next;
            end if;
            if Group.Pending_Async_File_Tail = Value then
               Group.Pending_Async_File_Tail := Previous;
            end if;
            Group.Pending_Async_File_Count := Group.Pending_Async_File_Count - 1;
            Value.Next := System.Null_Address;
         end;
         Complete_Async_File_Locked (Group, Value, 0, 0, True);
         Unlock_Group (Group);
         return 0;
      end if;
      Value.State := Async_File_Cancelling;
      Disposition :=
        Pollers.Cancel_File
          (Group.Scheduler_Poller,
           Value.Descriptor,
           Async_File_Token (Node),
           Completion,
           Has_Completion,
           Error);
      if Has_Completion then
         Complete_Async_File_Locked (Group, Value, Completion.Result, Completion.Error_Code, True);
         Submit_Pending_Async_Files_Locked (Group);
      end if;
      Unlock_Group (Group);
      return 0;
   end Cancel_Async_File;

   function File_Operation
     (Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : C.int;
      For_Send_ZC : Boolean;
      Cancel_FD   : C.int;
      Task_Lock   : System.Address;
      Transferred : access C.long_long;
      Error_Code  : access C.int;
      Cancelled   : access C.int) return C.int;
   function Ensure_Timer_Capacity (Group : not null Loop_Group_Access) return Boolean;
   function Register_Timer_Locked
     (Group : not null Loop_Group_Access; Item : not null Fiber_Access) return Boolean;
   procedure Remove_Timer_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   procedure Enqueue (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   procedure Clear_Stack_Advice (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   procedure Remove_From_Ready (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   function Ready_Present (Group : not null Loop_Group_Access) return Boolean;
   function Dequeue (Group : not null Loop_Group_Access) return Fiber_Access;
   procedure Reap_Locked (Item : not null Fiber_Access);
   procedure Link_Group_Head_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   procedure Unlink_Group_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   procedure Reap_From_Scheduler (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   procedure Transfer (Item : not null Fiber_Access; Source : not null Loop_Group_Access);
   function Clock return Duration;
   function To_Nanoseconds (Value : Duration) return C.unsigned_long_long;
   procedure Begin_Idle_Wait_Locked (Group : not null Loop_Group_Access);
   procedure End_Idle_Wait_Locked (Group : not null Loop_Group_Access);
   procedure Read_Utilization_Locked
     (Group : not null Loop_Group_Access; Uptime : out Duration; Idle : out Duration);
   procedure Consider_Dormant_Stack (Group : not null Loop_Group_Access; Item : not null Fiber_Access);
   function Promote_Expired_Timers (Group : not null Loop_Group_Access) return Duration;
   procedure Handle_Poll_Event (Group : not null Loop_Group_Access; Event : Pollers.Poll_Event);
   procedure Poll_Ready_Events (Group : not null Loop_Group_Access);
   function In_Fork_Child return Boolean;
   function Group_Quiescent_Locked (Group : not null Loop_Group_Access) return Boolean;

   procedure C_Abort;
   pragma Import (C, C_Abort, "abort");
   pragma No_Return (C_Abort);

   function C_Write (FD : C.int; Buffer : System.Address; Count : C.size_t) return C.long;
   pragma Import (C, C_Write, "write");

   function Install_Fork_Guard (Flag : System.Address) return C.int;
   pragma Import (C, Install_Fork_Guard, "flyology_install_fork_guard");

   function Pthread_Join (Thread : OSI.pthread_t; Value : System.Address) return C.int;
   pragma Import (C, Pthread_Join, "pthread_join");

   function In_Fork_Child return Boolean
   is (Fork_Child_State /= 0);

   function Startup_Pool_Size return C.int is
      Name    : aliased constant C.char_array := C.To_C ("FLYOLOGY_LOOP_POOL_SIZE");
      Text    : constant System.Address := C_Getenv (Name'Address);
      Maximum : constant Natural := Natural (Dedicated_First_Id);
      Value   : Natural := 0;
      Offset  : Natural := 0;
      Item    : C.char;
      Digit   : Natural;
   begin
      if Text = System.Null_Address then
         return C.int (Pool_Config.Prepared_Pool_Size);
      end if;

      loop
         Item := C_Char_Conversions.To_Pointer (Text + SSE.Storage_Offset (Offset)).all;
         exit when Item = C.nul;
         if C.char'Pos (Item) < Character'Pos ('0') or else C.char'Pos (Item) > Character'Pos ('9') then
            return -1;
         end if;
         Digit := C.char'Pos (Item) - Character'Pos ('0');
         if Value > (Maximum - Digit) / 10 then
            return -1;
         end if;
         Value := Value * 10 + Digit;
         Offset := Offset + 1;
      end loop;

      if Offset = 0 or else Value = 0 or else Value > Maximum then
         return -1;
      end if;
      return C.int (Value);
   end Startup_Pool_Size;

   function Group_Quiescent_Locked (Group : not null Loop_Group_Access) return Boolean
   is (Group.Member_Count = 0
       and then Group.Fibers = null
       and then Group.Current_Fiber = null
       and then Group.Ready_Count = 0
       and then Group.Timer_Count = 0
       and then Group.Pending_File_Head = null
       and then Group.Pending_File_Tail = null
       and then Group.Pending_Async_File_Head = null
       and then Group.Pending_Async_File_Tail = null
       and then Group.Pending_Async_File_Count = 0
       and then Group.File_Cancel_Head = null
       and then Group.File_Cancel_Tail = null
       and then Group.Descriptor_Cancel_Head = null
       and then Group.Descriptor_Cancel_Tail = null
       and then Pollers.File_Quiescent (Group.Scheduler_Poller));

   procedure Fatal (Context : C.int := Scheduler_Invariant) is
      Invariant_Message : aliased constant String := "Flyology fatal: scheduler invariant" & ASCII.LF;
      Mutex_Message     : aliased constant String := "Flyology fatal: scheduler mutex" & ASCII.LF;
      Poller_Message    : aliased constant String := "Flyology fatal: event poller" & ASCII.LF;
      Context_Message   : aliased constant String := "Flyology fatal: context switch" & ASCII.LF;
      Fork_Message      : aliased constant String :=
        "Flyology fatal: event runtime used after fork" & ASCII.LF;
      Written           : C.long;
   begin
      Last_Fatal_Context := Context;
      if Context = Mutex_Failure then
         Written := C_Write (2, Mutex_Message'Address, Mutex_Message'Length);
      elsif Context = Poller_Failure then
         Written := C_Write (2, Poller_Message'Address, Poller_Message'Length);
      elsif Context = Context_Failure then
         Written := C_Write (2, Context_Message'Address, Context_Message'Length);
      elsif Context = Fork_Child_Failure then
         Written := C_Write (2, Fork_Message'Address, Fork_Message'Length);
      else
         Written := C_Write (2, Invariant_Message'Address, Invariant_Message'Length);
      end if;
      pragma Unreferenced (Written);
      C_Abort;
   end Fatal;

   procedure Lock_Topology is
      Result : C.int;
   begin
      if In_Fork_Child then
         Fatal (Fork_Child_Failure);
      end if;
      Result := OSI.pthread_mutex_lock (Topology_Lock.Value'Access);
      if Result /= 0 then
         Fatal (Mutex_Failure);
      end if;
   end Lock_Topology;

   procedure Unlock_Topology is
      Result : constant C.int := OSI.pthread_mutex_unlock (Topology_Lock.Value'Access);
   begin
      if Result /= 0 then
         Fatal (Mutex_Failure);
      end if;
   end Unlock_Topology;

   procedure Lock_Registry_Shard (Shard : Registry_Shard_Index) is
      Result : C.int;
   begin
      if In_Fork_Child then
         Fatal (Fork_Child_Failure);
      end if;
      Result := OSI.pthread_mutex_lock (Registry_Shard_Locks (Shard).Value'Access);
      if Result /= 0 then
         Fatal (Mutex_Failure);
      end if;
   end Lock_Registry_Shard;

   procedure Unlock_Registry_Shard (Shard : Registry_Shard_Index) is
      Result : constant C.int := OSI.pthread_mutex_unlock (Registry_Shard_Locks (Shard).Value'Access);
   begin
      if Result /= 0 then
         Fatal (Mutex_Failure);
      end if;
   end Unlock_Registry_Shard;

   procedure Lock_Group (Group : not null Loop_Group_Access) is
      Result : C.int;
   begin
      if In_Fork_Child then
         Fatal (Fork_Child_Failure);
      end if;
      Result := OSI.pthread_mutex_lock (Group.Lock.Value'Access);
      if Result /= 0 then
         Fatal (Mutex_Failure);
      end if;
   end Lock_Group;

   procedure Unlock_Group (Group : not null Loop_Group_Access) is
      Result : constant C.int := OSI.pthread_mutex_unlock (Group.Lock.Value'Access);
   begin
      if Result /= 0 then
         Fatal (Mutex_Failure);
      end if;
   end Unlock_Group;

   function Ensure_Placement_Platform return C.int is
   begin
      --  Callers serialize this lazy initialization with Topology_Lock, except
      --  for Initialize itself before the runtime is published. Keeping the
      --  call lazy preserves a syscall-free native-only/default path.
      if not Placement_Platform_Initialized then
         Placement_Initialization_Result := Initialize_Thread_Placement;
         Placement_Platform_Initialized := True;
      end if;
      return Placement_Initialization_Result;
   end Ensure_Placement_Platform;

   function Group_Thread (Argument : System.Address) return System.Address is
      Group  : constant Loop_Group_Access := Address_To_Group (Argument);
      Stack  : aliased OSI.stack_t :=
        (ss_sp => Group.Signal_Stack'Address, ss_size => OSI.Alternate_Stack_Size, ss_flags => 0);
      Result : C.int;
   begin
      Thread_Group := Group;
      Lock_Topology;
      if Group.Placement_Mode /= No_Placement_Mode then
         Result := Apply_Thread_Placement (Group.Placement_Mode, Group.Placement_Value);
         Group.Placement_Result := Result;
         Group.Placement_Applied := Result = 0;
      else
         Result := 0;
      end if;
      if Result = 0 then
         Result := OSI.sigaltstack (Stack'Access, null);
      end if;
      Group.Scheduler_Context := (if Result = 0 then Contexts.Capture else null);
      Group.Started := Group.Scheduler_Context /= null;
      Group.Start_Failed := not Group.Started;
      if Group.Start_Failed then
         Unlock_Topology;
         return System.Null_Address;
      end if;

      Unlock_Topology;
      Lock_Group (Group);
      Scheduler_Main (Argument);
      return System.Null_Address;
   end Group_Thread;

   function Ensure_Group (Id : C.int; Dedicated : Boolean) return Loop_Group_Access is
      Group  : Loop_Group_Access;
      Result : C.int;
      Ready  : Boolean;
      Failed : Boolean;
   begin
      if not Initialized or else not Scheduling.Valid_Group (Id) then
         return null;
      elsif not Scheduling.Creation_Admitted (Lifecycle_State) then
         return null;
      end if;

      Lock_Topology;
      --  Revalidate under the lock Finalize holds while it inspects and stops
      --  the group table, so finalization cannot be restarted into by a
      --  caller that passed the unlocked guard above.
      if not Scheduling.Creation_Admitted (Lifecycle_State) then
         Unlock_Topology;
         return null;
      end if;
      Group := Groups (Group_Index (Id));
      if Group /= null then
         if Group.Dedicated /= Dedicated and then Scheduling.Dedicated_Group (Id) then
            Unlock_Topology;
            return null;
         end if;
         Unlock_Topology;
      else
         if Faults.Enabled and then Faults.Fail (Faults.Group_Startup) then
            Unlock_Topology;
            return null;
         end if;
         Group := new Loop_Group;
         Group.Id := Id;
         Group.Dedicated := Dedicated;
         Group.Placement_Mode := Placement_Requests (Group_Index (Id)).Mode;
         Group.Placement_Value := Placement_Requests (Group_Index (Id)).Value;
         if Group.Placement_Mode /= No_Placement_Mode and then Ensure_Placement_Platform /= 0 then
            Free_Group (Group);
            Unlock_Topology;
            return null;
         end if;
         Result := OSI.pthread_mutex_init (Group.Lock.Value'Access, null);
         if Result /= 0 then
            Free_Group (Group);
            Unlock_Topology;
            return null;
         end if;
         if not Pollers.Initialize (Group.Scheduler_Poller) then
            Free_Group (Group);
            Unlock_Topology;
            return null;
         end if;

         Groups (Group_Index (Id)) := Group;
         Created_Group_Count := Created_Group_Count + 1;
         Lifecycle_State := 1;
         Result :=
           OSI.pthread_create
             (Group.Event_Thread'Access, null, Group_Thread'Access, Group_To_Address (Group));
         --  pthread_create is the sole writer of Event_Thread. The new thread
         --  cannot publish Started until it acquires Topology_Lock, which is
         --  still held here, so readers cannot observe an uninitialized id.
         if Result /= 0 then
            Groups (Group_Index (Id)) := null;
            Created_Group_Count := Created_Group_Count - 1;
            if Created_Group_Count = 0 then
               Lifecycle_State := 0;
            end if;
            Pollers.Finalize (Group.Scheduler_Poller);
            Free_Group (Group);
            Unlock_Topology;
            return null;
         end if;
         Unlock_Topology;
      end if;

      --  This is a bounded, first-use-only startup wait. If called by an
      --  lightweight task, its source loop remains occupied until the new
      --  group thread publishes Started or Start_Failed under Topology_Lock.
      loop
         Lock_Topology;
         Ready := Group.Started;
         Failed := Group.Start_Failed;
         Unlock_Topology;
         exit when Ready or else Failed;
         Result := Sched_Yield;
         if Result /= 0 then
            return null;
         end if;
      end loop;

      if Failed then
         return null;
      end if;
      return Group;
   end Ensure_Group;

   function Select_Automatic_Group return C.int is
      Selected : C.int;
   begin
      --  Serialize only the ticket allocation.  Group construction remains
      --  lazy, and Ensure_Group takes the topology lock independently after
      --  this function returns.  The modular counter can wrap indefinitely
      --  without changing the round-robin sequence.
      Lock_Topology;
      Selected := C.int (Next_Automatic_Group mod C.unsigned_long_long (Automatic_Pool_Size));
      Next_Automatic_Group := Next_Automatic_Group + 1;
      if Automatic_Placement_Claims (Group_Index (Selected)) = Natural'Last then
         Fatal;
      end if;
      Automatic_Placement_Claims (Group_Index (Selected)) :=
        Automatic_Placement_Claims (Group_Index (Selected)) + 1;
      if Faults.Enabled then
         Faults.Note_Automatic_Placement_Claim (Selected);
      end if;
      Unlock_Topology;
      return Selected;
   exception
      when others =>
         Fatal;
   end Select_Automatic_Group;

   procedure Release_Automatic_Placement_Claim (Group : C.int) is
   begin
      if not Scheduling.Shared_Group (Group) then
         Fatal;
      end if;
      Lock_Topology;
      if Automatic_Placement_Claims (Group_Index (Group)) = 0 then
         Fatal;
      end if;
      Automatic_Placement_Claims (Group_Index (Group)) :=
        Automatic_Placement_Claims (Group_Index (Group)) - 1;
      Unlock_Topology;
   exception
      when others =>
         Fatal;
   end Release_Automatic_Placement_Claim;

   function Registry_Bucket_For (T : System.Address) return Registry_Bucket_Index is
      --  Express the address in 16-byte allocation quanta before taking the
      --  prime modulus; sub-quantum variation merely shares a collision chain.
      Value : constant SSE.Integer_Address := SSE.To_Integer (T) / 16;
   begin
      return Registry_Bucket_Index (Value mod SSE.Integer_Address (Registry_Bucket_Count));
   end Registry_Bucket_For;

   function Registry_Shard_For (T : System.Address) return Registry_Shard_Index is
   begin
      return Registry_Shard_Index (Registry_Bucket_For (T) mod Registry_Shard_Count);
   end Registry_Shard_For;

   function Find (T : System.Address) return Fiber_Access is
      Item : Fiber_Access;
   begin
      if T = System.Null_Address then
         return null;
      end if;

      Item := Fiber_Registry (Registry_Bucket_For (T));
      while Item /= null and then Item.T /= T loop
         Item := Item.Next_Registry;
      end loop;
      return Item;
   end Find;

   procedure Register_Locked (Item : not null Fiber_Access) is
      Bucket : constant Registry_Bucket_Index := Registry_Bucket_For (Item.T);
   begin
      Item.Registry_Bucket := Bucket;
      Item.Registry_Shard := Registry_Shard_Index (Bucket mod Registry_Shard_Count);
      Item.Next_Registry := Fiber_Registry (Bucket);
      Fiber_Registry (Bucket) := Item;
   end Register_Locked;

   procedure Unregister_Locked (Item : not null Fiber_Access) is
      Bucket   : constant Registry_Bucket_Index := Item.Registry_Bucket;
      Position : Fiber_Access := Fiber_Registry (Bucket);
      Previous : Fiber_Access;
   begin
      while Position /= null and then Position /= Item loop
         Previous := Position;
         Position := Position.Next_Registry;
      end loop;

      if Position = null then
         Fatal;
      elsif Previous = null then
         Fiber_Registry (Bucket) := Item.Next_Registry;
      else
         Previous.Next_Registry := Item.Next_Registry;
      end if;
      Item.Next_Registry := null;
   end Unregister_Locked;

   function IO_Bucket_For (Descriptor : C.int) return IO_Bucket_Index
   is (IO_Bucket_Index (Scheduling.Descriptor_Bucket (Natural (Descriptor), IO_Bucket_Count)));

   function Active_IO_Link (Item : not null Fiber_Access; Kind : IO_Link_Kind) return IO_Wait_Link_Access is
      Bytes : constant SSE.Storage_Offset :=
        SSE.Storage_Offset ((Kind - 1) * (IO_Wait_Link_Array'Component_Size / System.Storage_Unit));
   begin
      if Item.Active_IO_Links = null or else Kind > Item.Active_IO_Link_Count then
         Fatal;
      end if;
      return To_IO_Link_Access (IO_Link_Conversions.To_Pointer (Item.Active_IO_Links.all'Address + Bytes));
   end Active_IO_Link;

   function IO_Interest_Registered_Locked
     (Group : not null Loop_Group_Access; Descriptor : C.int; Interest : Pollers.Interest) return Boolean
   is
      Position : IO_Wait_Link_Access := Group.IO_Waiters (IO_Bucket_For (Descriptor));
   begin
      while Position /= null loop
         if Position.Registered
           and then Position.Descriptor = Descriptor
           and then Position.Interest = Interest
         then
            return True;
         end if;
         Position := Position.Next;
      end loop;
      return False;
   end IO_Interest_Registered_Locked;

   procedure Register_IO_Wait_Locked
     (Group      : not null Loop_Group_Access;
      Item       : not null Fiber_Access;
      Descriptor : C.int;
      Interest   : Pollers.Interest;
      Kind       : IO_Link_Kind;
      Outcome    : C.int)
   is
      Bucket : IO_Bucket_Index;
      Link   : IO_Wait_Link_Access;
   begin
      if Item.Group /= Group
        or else Item.State /= Waiting
        or else Descriptor < 0
        or else Item.Active_IO_Links = null
        or else Kind > Item.Active_IO_Link_Count
        or else Active_IO_Link (Item, Kind).Registered
      then
         Fatal;
      end if;
      Bucket := IO_Bucket_For (Descriptor);
      Link := Active_IO_Link (Item, Kind);
      Item.IO_Wait := True;
      Link.Owner := Item;
      Link.Descriptor := Descriptor;
      Link.Interest := Interest;
      Link.Kind := Kind;
      Link.Outcome := Outcome;
      Link.Bucket := Bucket;
      Link.Registered := True;
      Link.Next := Group.IO_Waiters (Bucket);
      Group.IO_Waiters (Bucket) := Link;
   end Register_IO_Wait_Locked;

   procedure Remove_IO_Waits_Locked
     (Group               : not null Loop_Group_Access;
      Item                : not null Fiber_Access;
      Consumed_Descriptor : C.int := -1;
      Read_Consumed       : Boolean := False;
      Write_Consumed      : Boolean := False)
   is
      Position           : IO_Wait_Link_Access;
      Previous           : IO_Wait_Link_Access;
      Link               : IO_Wait_Link_Access;
      Cancellations      : Pollers.Interest_Request_Array (1 .. Item.Active_IO_Link_Count);
      Cancellation_Count : Natural := 0;

      function Already_Listed (Descriptor : C.int; Interest : Pollers.Interest) return Boolean;

      function Already_Listed (Descriptor : C.int; Interest : Pollers.Interest) return Boolean is
      begin
         for Index in 1 .. Cancellation_Count loop
            if Cancellations (Index).Descriptor = Descriptor
              and then Cancellations (Index).Condition = Interest
            then
               return True;
            end if;
         end loop;
         return False;
      end Already_Listed;
   begin
      if not Item.IO_Wait then
         return;
      elsif Item.Group /= Group then
         Fatal;
      end if;

      if Item.Active_IO_Links = null then
         Fatal;
      end if;
      for Kind in 1 .. Item.Active_IO_Link_Count loop
         Link := Active_IO_Link (Item, Kind);
         if Link.Registered then
            Position := Group.IO_Waiters (Link.Bucket);
            Previous := null;
            while Position /= null and then Position /= Link loop
               Previous := Position;
               Position := Position.Next;
            end loop;
            if Position = null then
               Fatal;
            elsif Previous = null then
               Group.IO_Waiters (Link.Bucket) := Link.Next;
            else
               Previous.Next := Link.Next;
            end if;
            Link.Next := null;
            Link.Registered := False;
         end if;
      end loop;

      --  Removing one fiber can orphan several one-shot kernel interests.
      --  The direction delivered by the poller was consumed atomically with
      --  that event and needs no delete. Darwin can safely retain every other
      --  one-shot knote until it fires once or its descriptor closes; an event
      --  arriving without a waiter is only a discarded readiness hint. Linux
      --  still clears orphans because its poller owns one process-side record
      --  per epoll registration. A raw wait does not own its descriptor, so
      --  cancellation accepts a source closed concurrently by its owner as
      --  already removed.
      for Kind in 1 .. Item.Active_IO_Link_Count loop
         Link := Active_IO_Link (Item, Kind);
         if Link.Descriptor >= 0
           and then not (Link.Descriptor = Consumed_Descriptor
                         and then ((Link.Interest = Pollers.Readable and then Read_Consumed)
                                   or else (Link.Interest = Pollers.Writable and then Write_Consumed)))
           and then not IO_Interest_Registered_Locked (Group, Link.Descriptor, Link.Interest)
           and then not Already_Listed (Link.Descriptor, Link.Interest)
         then
            Cancellation_Count := Cancellation_Count + 1;
            Cancellations (Cancellation_Count) := (Descriptor => Link.Descriptor, Condition => Link.Interest);
         end if;
         Link.Owner := null;
         Link.Descriptor := -1;
         Link.Outcome := 0;
      end loop;
      if Cancellation_Count > 0
        and then not Pollers.Retains_Orphaned_One_Shots
        and then not Pollers.Cancel_Many (Group.Scheduler_Poller, Cancellations (1 .. Cancellation_Count))
      then
         Fatal (Poller_Failure);
      end if;
      Item.IO_Wait := False;
      Item.IO_Interrupt_Wait := False;
   end Remove_IO_Waits_Locked;

   procedure Queue_Descriptor_Cancel_Locked
     (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
   begin
      if Item.Group /= Group or else Item.State /= Waiting or else not Item.IO_Wait then
         Fatal;
      elsif Item.Descriptor_Cancel_Queued then
         return;
      end if;
      Item.Descriptor_Cancel_Queued := True;
      Item.Next_Descriptor_Cancel := null;
      if Group.Descriptor_Cancel_Tail = null then
         Group.Descriptor_Cancel_Head := Item;
      else
         Group.Descriptor_Cancel_Tail.Next_Descriptor_Cancel := Item;
      end if;
      Group.Descriptor_Cancel_Tail := Item;
      if Faults.Enabled then
         Faults.Note_Descriptor_Cancel_Queued;
      end if;
   end Queue_Descriptor_Cancel_Locked;

   procedure Process_Descriptor_Cancellations_Locked (Group : not null Loop_Group_Access) is
      Descriptor_Cancel_Budget : constant Positive := 64;
      Item                     : Fiber_Access;
      Processed                : Natural := 0;
   begin
      --  Only the loop thread drains this queue. In particular, it cannot
      --  overlap Linux Wait_Batch while that routine translates and removes
      --  records from the poller's process-side registration list.
      while Group.Descriptor_Cancel_Head /= null and then Processed < Descriptor_Cancel_Budget loop
         Item := Group.Descriptor_Cancel_Head;
         if not Item.Descriptor_Cancel_Queued then
            Fatal;
         end if;
         Group.Descriptor_Cancel_Head := Item.Next_Descriptor_Cancel;
         if Group.Descriptor_Cancel_Head = null then
            Group.Descriptor_Cancel_Tail := null;
         end if;
         Item.Next_Descriptor_Cancel := null;
         Item.Descriptor_Cancel_Queued := False;
         Processed := Processed + 1;
         if Item.Group = Group and then Item.State = Waiting and then Item.IO_Wait then
            Remove_Timer_Locked (Group, Item);
            Item.Timed_Out := False;
            Remove_IO_Waits_Locked (Group, Item);
            Enqueue (Group, Item);
            if Faults.Enabled then
               Faults.Note_Descriptor_Cancel_Processed;
            end if;
         end if;
      end loop;
      if Group.Descriptor_Cancel_Head /= null
        and then Faults.Enabled
        and then Faults.Fail (Faults.Descriptor_Cancel_Budget_Pause)
      then
         Faults.Pause_Descriptor_Cancel_Budget;
      end if;
      if Group.Descriptor_Cancel_Head /= null and then not Pollers.Wake (Group.Scheduler_Poller) then
         Fatal (Poller_Failure);
      end if;
   end Process_Descriptor_Cancellations_Locked;

   procedure Queue_Pending_File_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
   begin
      if not Item.File_Wait or else Item.File_Pending then
         Fatal;
      end if;
      Item.File_Pending := True;
      Item.Next_File := null;
      if Group.Pending_File_Tail = null then
         Group.Pending_File_Head := Item;
      else
         Group.Pending_File_Tail.Next_File := Item;
      end if;
      Group.Pending_File_Tail := Item;
   end Queue_Pending_File_Locked;

   procedure Remove_Pending_File_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
      Position : Fiber_Access := Group.Pending_File_Head;
      Previous : Fiber_Access := null;
   begin
      if not Item.File_Pending then
         return;
      end if;
      while Position /= null and then Position /= Item loop
         Previous := Position;
         Position := Position.Next_File;
      end loop;
      if Position = null then
         Fatal;
      elsif Previous = null then
         Group.Pending_File_Head := Item.Next_File;
      else
         Previous.Next_File := Item.Next_File;
      end if;
      if Group.Pending_File_Tail = Item then
         Group.Pending_File_Tail := Previous;
      end if;
      Item.Next_File := null;
      Item.File_Pending := False;
   end Remove_Pending_File_Locked;

   procedure Queue_File_Cancel_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
   begin
      if Item.Group /= Group or else not Item.File_Wait then
         Fatal;
      elsif Item.File_Cancel_Queued then
         return;
      end if;
      Item.File_Cancel_Requested := True;
      Item.File_Cancel_Queued := True;
      Item.Next_File_Cancel := null;
      if Group.File_Cancel_Tail = null then
         Group.File_Cancel_Head := Item;
      else
         Group.File_Cancel_Tail.Next_File_Cancel := Item;
      end if;
      Group.File_Cancel_Tail := Item;
   end Queue_File_Cancel_Locked;

   procedure Remove_File_Cancel_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
      Position : Fiber_Access := Group.File_Cancel_Head;
      Previous : Fiber_Access := null;
   begin
      if not Item.File_Cancel_Queued then
         return;
      end if;
      while Position /= null and then Position /= Item loop
         Previous := Position;
         Position := Position.Next_File_Cancel;
      end loop;
      if Position = null then
         Fatal;
      elsif Previous = null then
         Group.File_Cancel_Head := Item.Next_File_Cancel;
      else
         Previous.Next_File_Cancel := Item.Next_File_Cancel;
      end if;
      if Group.File_Cancel_Tail = Item then
         Group.File_Cancel_Tail := Previous;
      end if;
      Item.Next_File_Cancel := null;
      Item.File_Cancel_Queued := False;
   end Remove_File_Cancel_Locked;

   procedure Complete_File_Locked
     (Group     : not null Loop_Group_Access;
      Item      : not null Fiber_Access;
      Result    : C.long_long;
      Error     : C.int;
      Cancelled : Boolean) is
   begin
      if Item.Group /= Group or else Item.State /= Waiting or else not Item.File_Wait then
         Fatal;
      end if;
      Remove_File_Cancel_Locked (Group, Item);
      Remove_Pending_File_Locked (Group, Item);
      Remove_IO_Waits_Locked (Group, Item);
      Item.File_Result := Result;
      Item.File_Error := Error;
      Item.File_Wait := False;
      Item.File_Descriptor := -1;
      Item.File_Buffer := System.Null_Address;
      Item.File_Length := 0;
      Item.File_Offset := 0;
      Item.File_For_Write := False;
      Item.File_Send_ZC := False;
      Item.File_Cancel_Descriptor := -1;
      Item.File_Cancel_Requested := Cancelled;
      Enqueue (Group, Item);
   end Complete_File_Locked;

   procedure Signal_Async_File (Node : not null Async_File_Node_Access) is
      Byte    : aliased C.unsigned_char := 1;
      Written : C.long;
   begin
      loop
         Written := C_Write (Node.Signal_FD, Byte'Address, 1);
         exit when Written = 1 or else (Written < 0 and then C.int (OSI.errno) = C.int (OSI.EAGAIN));
         if Written >= 0 or else C.int (OSI.errno) /= C.int (OSI.EINTR) then
            Fatal (Poller_Failure);
         end if;
      end loop;
   end Signal_Async_File;

   procedure Complete_Async_File_Locked
     (Group     : not null Loop_Group_Access;
      Node      : not null Async_File_Node_Access;
      Result    : C.long_long;
      Error     : C.int;
      Cancelled : Boolean)
   is
      Owner : constant Fiber_Access := Address_To_Fiber (Node.Owner);
   begin
      if Owner = null
        or else Owner.Group /= Group
        or else Owner.Active_Async_Files = 0
        or else Node.State not in Async_File_Submitted | Async_File_Cancelling | Async_File_Queued
      then
         Fatal;
      end if;
      Node.Result := Result;
      Node.Error_Code := Error;
      Node.Cancelled := Boolean'Pos (Cancelled);
      Node.Descriptor := -1;
      Node.Buffer := System.Null_Address;
      Node.Length := 0;
      Node.State := Async_File_Terminal;
      Owner.Active_Async_Files := Owner.Active_Async_Files - 1;
      Signal_Async_File (Node);
   end Complete_Async_File_Locked;

   function Request_File_Cancel_Locked
     (Group : not null Loop_Group_Access; Item : not null Fiber_Access) return Boolean
   is
      Completion     : File_Engines.Completion;
      Has_Completion : Boolean;
      Error          : C.int;
      Disposition    : File_Engines.Cancellation_Disposition;
   begin
      if Item.Group /= Group then
         return False;
      end if;
      Remove_File_Cancel_Locked (Group, Item);
      case Scheduling.Plan_File_Cancel (Item.File_Wait, Item.File_Pending, Item.File_Cancel_Disposition /= 0)
      is
         when Scheduling.Ignore_Cancel         =>
            return False;

         when Scheduling.Complete_Pending      =>
            Item.File_Cancel_Requested := True;
            Remove_IO_Waits_Locked (Group, Item);
            Item.File_Cancel_Descriptor := -1;
            Complete_File_Locked (Group, Item, 0, 0, True);
            return True;

         when Scheduling.Request_Kernel_Cancel =>
            Item.File_Cancel_Requested := True;
            Remove_IO_Waits_Locked (Group, Item);
            Item.File_Cancel_Descriptor := -1;
      end case;

      Disposition :=
        Pollers.Cancel_File
          (Group.Scheduler_Poller,
           Item.File_Descriptor,
           Fiber_To_Address (Item),
           Completion,
           Has_Completion,
           Error);
      Item.File_Cancel_Disposition := C.int (File_Engines.Cancellation_Disposition'Pos (Disposition) + 1);
      Item.File_Cancel_Error := Error;
      if Has_Completion then
         Complete_File_Locked (Group, Item, Completion.Result, Completion.Error_Code, True);
         Submit_Pending_Files_Locked (Group);
         return True;
      end if;

      --  Submitted, already completing, and not-cancelable requests all keep
      --  ownership of the caller buffer until their ordinary completion. A
      --  cancellation transport failure has the same safe fallback.
      return False;
   end Request_File_Cancel_Locked;

   procedure Process_File_Cancellations_Locked (Group : not null Loop_Group_Access) is
      File_Cancel_Budget : constant Positive := 64;
      Item               : Fiber_Access;
      Made_Ready         : Boolean;
      Processed          : Natural := 0;
   begin
      --  Bound abort/token work per scheduler turn so a cancellation burst
      --  cannot indefinitely postpone ready tasks or completion delivery.
      while Group.File_Cancel_Head /= null and then Processed < File_Cancel_Budget loop
         Item := Group.File_Cancel_Head;
         Remove_File_Cancel_Locked (Group, Item);
         Processed := Processed + 1;
         if Item.Group = Group and then Item.State = Waiting and then Item.File_Wait then
            Made_Ready := Request_File_Cancel_Locked (Group, Item);
            if Made_Ready then
               Group.Wakeups := Group.Wakeups + 1;
            end if;
         end if;
      end loop;
      Submit_Pending_Files_Locked (Group);
      if Group.File_Cancel_Head /= null and then not Pollers.Wake (Group.Scheduler_Poller) then
         Fatal (Poller_Failure);
      end if;
   end Process_File_Cancellations_Locked;

   procedure Submit_Pending_Files_Locked (Group : not null Loop_Group_Access) is
      Item  : Fiber_Access;
      Error : C.int;
   begin
      while Group.Pending_File_Head /= null loop
         Item := Group.Pending_File_Head;
         if not Item.File_Wait or else not Item.File_Pending then
            Fatal;
         end if;

         if (if Item.File_Send_ZC
             then
               Pollers.Submit_Send_ZC
                 (Group.Scheduler_Poller,
                  Item.File_Descriptor,
                  Item.File_Buffer,
                  Item.File_Length,
                  Fiber_To_Address (Item),
                  Error)
             else
               Pollers.Submit_File
                 (Group.Scheduler_Poller,
                  Item.File_Descriptor,
                  Item.File_Buffer,
                  Item.File_Length,
                  Item.File_Offset,
                  Item.File_For_Write,
                  Fiber_To_Address (Item),
                  Error))
         then
            Group.Pending_File_Head := Item.Next_File;
            if Group.Pending_File_Head = null then
               Group.Pending_File_Tail := null;
            end if;
            Item.Next_File := null;
            Item.File_Pending := False;
         elsif Error = C.int (OSI.EAGAIN) then
            return;
         else
            Group.Pending_File_Head := Item.Next_File;
            if Group.Pending_File_Head = null then
               Group.Pending_File_Tail := null;
            end if;
            Item.Next_File := null;
            Item.File_Pending := False;
            Complete_File_Locked (Group, Item, 0, Error, False);
         end if;
      end loop;
   end Submit_Pending_Files_Locked;

   procedure Submit_Pending_Async_Files_Locked (Group : not null Loop_Group_Access) is
      Node  : Async_File_Node_Access;
      Error : C.int;
   begin
      while Group.Pending_Async_File_Head /= null loop
         Node := Group.Pending_Async_File_Head;
         if Node.State /= Async_File_Queued
           or else Node.Owner = System.Null_Address
           or else Node.Buffer = System.Null_Address
           or else Group.Pending_Async_File_Count = 0
         then
            Fatal;
         end if;

         if Pollers.Submit_File
              (Group.Scheduler_Poller,
               Node.Descriptor,
               Node.Buffer,
               Node.Length,
               Node.Offset,
               Node.For_Write /= 0,
               Async_File_Token (Node.all'Address),
               Error)
         then
            Group.Pending_Async_File_Head := To_Async_File_Node (Node.Next);
            if Group.Pending_Async_File_Head = null then
               Group.Pending_Async_File_Tail := null;
            end if;
            Group.Pending_Async_File_Count := Group.Pending_Async_File_Count - 1;
            Node.Next := System.Null_Address;
            Node.State := Async_File_Submitted;
         elsif Error = C.int (OSI.EAGAIN) then
            return;
         else
            Group.Pending_Async_File_Head := To_Async_File_Node (Node.Next);
            if Group.Pending_Async_File_Head = null then
               Group.Pending_Async_File_Tail := null;
            end if;
            Group.Pending_Async_File_Count := Group.Pending_Async_File_Count - 1;
            Node.Next := System.Null_Address;
            Complete_Async_File_Locked (Group, Node, 0, Error, False);
         end if;
      end loop;
   end Submit_Pending_Async_Files_Locked;

   function Ensure_Timer_Capacity (Group : not null Loop_Group_Access) return Boolean is
      New_Capacity : Natural;
      Replacement  : Timer_Heap_Access;
      Previous     : Timer_Heap_Access;
   begin
      if Group.Timer_Count < Group.Timer_Capacity then
         return True;
      elsif Group.Timer_Capacity = 0 then
         New_Capacity := 16;
      elsif Group.Timer_Capacity > Natural'Last / 2 then
         return False;
      else
         New_Capacity := Group.Timer_Capacity * 2;
      end if;

      Replacement := new Timer_Heap_Array (1 .. New_Capacity);
      for Index in 1 .. Group.Timer_Count loop
         Replacement (Index) := Group.Timers (Index);
      end loop;
      Previous := Group.Timers;
      Group.Timers := Replacement;
      Group.Timer_Capacity := New_Capacity;
      if Previous /= null then
         Free_Timer_Heap (Previous);
      end if;
      return True;
   exception
      when Storage_Error =>
         return False;
   end Ensure_Timer_Capacity;

   function Register_Timer_Locked
     (Group : not null Loop_Group_Access; Item : not null Fiber_Access) return Boolean
   is
      Position    : Natural;
      Parent      : Natural;
      Parent_Item : Fiber_Access;
   begin
      if Item.Deadline < 0.0 then
         return True;
      elsif Item.Group /= Group or else Item.Timer_Index /= 0 then
         Fatal;
      elsif not Ensure_Timer_Capacity (Group) then
         return False;
      end if;

      Group.Timer_Count := Group.Timer_Count + 1;
      Position := Group.Timer_Count;
      while Position > 1 loop
         Parent := Natural (Scheduling.Heap_Parent (Positive (Position)));
         Parent_Item := Group.Timers (Parent);
         exit when Parent_Item.Deadline <= Item.Deadline;
         Group.Timers (Position) := Parent_Item;
         Parent_Item.Timer_Index := Position;
         Position := Parent;
      end loop;
      Group.Timers (Position) := Item;
      Item.Timer_Index := Position;
      return True;
   end Register_Timer_Locked;

   procedure Remove_Timer_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
      Position : Natural := Item.Timer_Index;
      Parent   : Natural;
      Child    : Natural;
      Last     : Fiber_Access;
   begin
      if Position = 0 then
         return;
      elsif Item.Group /= Group or else Position > Group.Timer_Count or else Group.Timers (Position) /= Item
      then
         Fatal;
      end if;

      Last := Group.Timers (Group.Timer_Count);
      Group.Timers (Group.Timer_Count) := null;
      Group.Timer_Count := Group.Timer_Count - 1;
      Item.Timer_Index := 0;
      Item.Deadline := No_Deadline;
      if Position > Group.Timer_Count then
         return;
      end if;

      Group.Timers (Position) := Last;
      Last.Timer_Index := Position;
      if Position > 1 then
         Parent := Natural (Scheduling.Heap_Parent (Positive (Position)));
      end if;
      if Position > 1 and then Last.Deadline < Group.Timers (Parent).Deadline then
         while Position > 1 loop
            Parent := Natural (Scheduling.Heap_Parent (Positive (Position)));
            exit when Group.Timers (Parent).Deadline <= Last.Deadline;
            Group.Timers (Position) := Group.Timers (Parent);
            Group.Timers (Position).Timer_Index := Position;
            Position := Parent;
         end loop;
         Group.Timers (Position) := Last;
         Last.Timer_Index := Position;
      else
         loop
            exit when not Scheduling.Heap_Has_Child (Positive (Position), Group.Timer_Count);
            Child := Natural (Scheduling.Heap_First_Child (Positive (Position), Group.Timer_Count));
            if Child < Group.Timer_Count
              and then Group.Timers (Child + 1).Deadline < Group.Timers (Child).Deadline
            then
               Child := Child + 1;
            end if;
            exit when Last.Deadline <= Group.Timers (Child).Deadline;
            Group.Timers (Position) := Group.Timers (Child);
            Group.Timers (Position).Timer_Index := Position;
            Position := Child;
         end loop;
         Group.Timers (Position) := Last;
         Last.Timer_Index := Position;
      end if;
   end Remove_Timer_Locked;

   procedure Clear_Stack_Advice (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
   begin
      if Item.Stack_Cold then
         if Group.Cold_Stacks = 0
           or else Group.Cold_Stack_Bytes < C.unsigned_long_long (Contexts.Stack_Size (Item.Context))
         then
            Fatal;
         end if;
         Group.Cold_Stacks := Group.Cold_Stacks - 1;
         Group.Cold_Stack_Bytes :=
           Group.Cold_Stack_Bytes - C.unsigned_long_long (Contexts.Stack_Size (Item.Context));
         Item.Stack_Cold := False;
      end if;
   end Clear_Stack_Advice;

   procedure Enqueue (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
      Priority : constant Ready_Priority := Ready_Priority (Item.Priority);
      Bucket   : Ready_Bucket renames Group.Ready_Buckets (Priority);
      At_Head  : constant Boolean := Item.Enqueue_At_Head;
   begin
      if Item.Descriptor_Cancel_Queued then
         Fatal;
      end if;
      Clear_Stack_Advice (Group, Item);
      Item.State := Ready;
      Item.Enqueue_At_Head := False;

      if At_Head then
         Item.Previous_Ready := null;
         Item.Next_Ready := Bucket.Head;
         if Bucket.Head = null then
            Bucket.Tail := Item;
         else
            Bucket.Head.Previous_Ready := Item;
         end if;
         Bucket.Head := Item;
      else
         Item.Previous_Ready := Bucket.Tail;
         Item.Next_Ready := null;
         if Bucket.Tail = null then
            Bucket.Head := Item;
         else
            Bucket.Tail.Next_Ready := Item;
         end if;
         Bucket.Tail := Item;
      end if;

      if Group.Ready_Count = 0 or else Priority > Group.Highest_Ready then
         Group.Highest_Ready := Priority;
      end if;
      Group.Ready_Count := Group.Ready_Count + 1;
   end Enqueue;

   procedure Remove_From_Ready (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
      Priority : constant Ready_Priority := Ready_Priority (Item.Priority);
      Bucket   : Ready_Bucket renames Group.Ready_Buckets (Priority);
   begin
      if Item.Previous_Ready = null then
         if Bucket.Head /= Item then
            Fatal;
         end if;
         Bucket.Head := Item.Next_Ready;
      else
         Item.Previous_Ready.Next_Ready := Item.Next_Ready;
      end if;

      if Item.Next_Ready = null then
         if Bucket.Tail /= Item then
            Fatal;
         end if;
         Bucket.Tail := Item.Previous_Ready;
      else
         Item.Next_Ready.Previous_Ready := Item.Previous_Ready;
      end if;

      Item.Previous_Ready := null;
      Item.Next_Ready := null;
      if Group.Ready_Count = 0 then
         Fatal;
      end if;
      Group.Ready_Count := Group.Ready_Count - 1;

      if Group.Ready_Count = 0 then
         Group.Highest_Ready := Ready_Priority'First;
      elsif Priority = Group.Highest_Ready and then Bucket.Head = null then
         while Group.Highest_Ready > Ready_Priority'First
           and then Group.Ready_Buckets (Group.Highest_Ready).Head = null
         loop
            Group.Highest_Ready := Ready_Priority'Pred (Group.Highest_Ready);
         end loop;
         if Group.Ready_Buckets (Group.Highest_Ready).Head = null then
            Fatal;
         end if;
      end if;
   end Remove_From_Ready;

   function Ready_Present (Group : not null Loop_Group_Access) return Boolean
   is (Group.Ready_Count /= 0);

   function Dequeue (Group : not null Loop_Group_Access) return Fiber_Access is
      Item : Fiber_Access;
   begin
      if not Ready_Present (Group) then
         return null;
      end if;

      Item := Group.Ready_Buckets (Group.Highest_Ready).Head;
      if Item = null or else Item.Descriptor_Cancel_Queued then
         Fatal;
      end if;
      Remove_From_Ready (Group, Item);
      return Item;
   end Dequeue;

   procedure Link_Group_Head_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
   begin
      if Item.Previous_Group /= null or else Item.Next_Group /= null then
         Fatal;
      end if;
      Item.Next_Group := Group.Fibers;
      if Group.Fibers /= null then
         Group.Fibers.Previous_Group := Item;
      end if;
      Group.Fibers := Item;
   end Link_Group_Head_Locked;

   procedure Unlink_Group_Locked (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
      Previous : constant Fiber_Access := Item.Previous_Group;
      Next     : constant Fiber_Access := Item.Next_Group;
   begin
      if Previous = null then
         if Group.Fibers /= Item then
            Fatal;
         end if;
         Group.Fibers := Next;
      else
         if Previous.Next_Group /= Item then
            Fatal;
         end if;
         Previous.Next_Group := Next;
      end if;
      if Next /= null then
         if Next.Previous_Group /= Item then
            Fatal;
         end if;
         Next.Previous_Group := Previous;
      end if;
      Item.Previous_Group := null;
      Item.Next_Group := null;
   end Unlink_Group_Locked;

   procedure Reap_Locked (Item : not null Fiber_Access) is
      Victim : Fiber_Access := Item;
      Group  : constant Loop_Group_Access := Item.Group;
   begin
      if Scheduling.Plan_Destroy (Phase_Of (Item.State)) = Scheduling.Defer
        or else Item.File_Wait
        or else Item.Active_Async_Files /= 0
        or else Item.Descriptor_Cancel_Queued
      then
         Fatal;
      end if;

      if Item.State = Ready then
         Remove_From_Ready (Group, Item);
      end if;
      Remove_Timer_Locked (Group, Item);
      Remove_IO_Waits_Locked (Group, Item);

      Unregister_Locked (Item);

      Unlink_Group_Locked (Group, Item);

      if Group.Current_Fiber = Item then
         Group.Current_Fiber := null;
      end if;
      Clear_Stack_Advice (Group, Item);
      Group.Member_Count := Group.Member_Count - 1;
      if Item.Reserved_Group /= null then
         Item.Reserved_Group.Reserved_For := System.Null_Address;
         Item.Reserved_Group := null;
      end if;
      --  Execution left this fiber's stack before the scheduler reached its
      --  final reap, so no trampoline it owns can still be in use.
      Release_Heap_Trampolines (Item.Trampoline_Control);
      Item.Trampoline_Control := System.Null_Address;
      Contexts.Destroy (Item.Context);
      Free_Fiber (Victim);
   exception
      when others =>
         Fatal;
   end Reap_Locked;

   procedure Reap_From_Scheduler (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
      Shard : constant Registry_Shard_Index := Item.Registry_Shard;
   begin
      Item.Reaping := True;
      Unlock_Group (Group);
      if Faults.Enabled and then Faults.Fail (Faults.Final_Reap_Window) and then not Faults.Pause_Final_Reaper
      then
         Fatal;
      end if;
      Lock_Registry_Shard (Shard);
      Lock_Topology;
      Lock_Group (Group);
      Reap_Locked (Item);
      Unlock_Topology;
      Unlock_Registry_Shard (Shard);
   end Reap_From_Scheduler;

   procedure Transfer (Item : not null Fiber_Access; Source : not null Loop_Group_Access) is
      Target      : constant Loop_Group_Access := Item.Migration_Target;
      Shard       : constant Registry_Shard_Index := Item.Registry_Shard;
      Wake_Target : Boolean := True;
   begin
      if Target = null or else Item.Group /= Source then
         Fatal;
      end if;

      --  Migration has its own target-loop enqueue operation. A queue-head
      --  designation caused by a prior loss of inherited priority applies
      --  only to yielding on the current loop and must not cross groups.
      Item.Enqueue_At_Head := False;
      Item.State := Migrating;
      Unlink_Group_Locked (Source, Item);
      Source.Current_Fiber := null;
      Source.Member_Count := Source.Member_Count - 1;
      Source.Migrations_Out := Source.Migrations_Out + 1;
      Unlock_Group (Source);

      Lock_Registry_Shard (Shard);
      Lock_Topology;
      Lock_Group (Target);
      if Source.Dedicated then
         Source.Reserved_For := System.Null_Address;
         Item.Reserved_Group := null;
      end if;
      Target.Member_Count := Target.Member_Count + 1;
      Target.Migrations_In := Target.Migrations_In + 1;
      Item.Group := Target;
      Item.Migration_Target := null;
      Link_Group_Head_Locked (Target, Item);
      if Item.Destroy_Requested then
         Item.Enqueue_At_Head := False;
         Item.State := Finished;
         Reap_Locked (Item);
         Wake_Target := False;
      else
         Enqueue (Target, Item);
      end if;
      Unlock_Group (Target);
      Unlock_Topology;
      Unlock_Registry_Shard (Shard);

      if Wake_Target and then not Pollers.Wake (Target.Scheduler_Poller) then
         Fatal (Poller_Failure);
      end if;
      Lock_Group (Source);
   exception
      when others =>
         Fatal;
   end Transfer;

   function Clock return Duration is
      Now    : aliased Time_ABI.Timespec;
      Result : C.int;
   begin
      Result := Time_ABI.Read_Monotonic (Now'Access);
      if Result /= 0 then
         Fatal;
      end if;
      return Time_ABI.To_Duration (Now);
   end Clock;

   function To_Nanoseconds (Value : Duration) return C.unsigned_long_long is
   begin
      if Value <= 0.0 then
         return 0;
      end if;
      return C.unsigned_long_long (Value / Nanosecond);
   end To_Nanoseconds;

   --  Open an idle interval just before the event thread releases this
   --  group's lock and blocks in its poller. Only the group's own event
   --  thread calls this, and only with no ready fiber left to dispatch, so
   --  the interval measures exactly the time the loop had nothing to run.
   procedure Begin_Idle_Wait_Locked (Group : not null Loop_Group_Access) is
   begin
      Group.Idle_Since := Clock;
      Group.Idle_Waits := Group.Idle_Waits + 1;
   end Begin_Idle_Wait_Locked;

   --  Close the interval opened above once the poller has returned and the
   --  lock is held again. A clock that did not advance leaves the total
   --  unchanged rather than subtracting from it.
   procedure End_Idle_Wait_Locked (Group : not null Loop_Group_Access) is
      Now : Duration;
   begin
      if Group.Idle_Since = No_Timestamp then
         return;
      end if;
      Now := Clock;
      if Now > Group.Idle_Since then
         Group.Idle_Time := Group.Idle_Time + (Now - Group.Idle_Since);
      end if;
      Group.Idle_Since := No_Timestamp;
   end End_Idle_Wait_Locked;

   --  Report Group's elapsed and idle time at one instant, including a poller
   --  wait that has not returned yet. Both results come from a single clock
   --  reading, and Idle is clamped so a caller can always divide by Uptime.
   --  The caller holds Group's lock.
   procedure Read_Utilization_Locked
     (Group : not null Loop_Group_Access; Uptime : out Duration; Idle : out Duration)
   is
      Now : Duration;
   begin
      Uptime := 0.0;
      Idle := Group.Idle_Time;
      if Group.Started_At = No_Timestamp then
         Idle := 0.0;
         return;
      end if;

      Now := Clock;
      if Now > Group.Started_At then
         Uptime := Now - Group.Started_At;
      end if;
      if Group.Idle_Since /= No_Timestamp and then Now > Group.Idle_Since then
         Idle := Idle + (Now - Group.Idle_Since);
      end if;
      if Idle > Uptime then
         Idle := Uptime;
      end if;
   end Read_Utilization_Locked;

   procedure Consider_Dormant_Stack (Group : not null Loop_Group_Access; Item : not null Fiber_Access) is
      Result : C.int;
   begin
      if Item.Dormancy_Policy = Prompt_Advice
        or else Item.Stack_Cold
        or else Item.State /= Waiting
        or else Item.Timer_Index = 0
        or else Item.IO_Wait
        or else Item.File_Wait
        or else Item.Deadline - Clock < Item.Dormancy_Minimum_Wait
      then
         return;
      end if;

      case Item.Dormancy_Policy is
         when Prompt_Advice  =>
            return;

         when Cold_Advice    =>
            if not Contexts.Cold_Advice_Supported then
               return;
            end if;
            Group.Cold_Advice_Attempts := Group.Cold_Advice_Attempts + 1;
            Result := Contexts.Advise_Stack_Cold (Item.Context);

         when Pageout_Advice =>
            if not Contexts.Pageout_Advice_Supported then
               return;
            end if;
            Group.Pageout_Advice_Attempts := Group.Pageout_Advice_Attempts + 1;
            Result := Contexts.Advise_Stack_Pageout (Item.Context);
      end case;
      if Result = 1 then
         Item.Stack_Cold := True;
         Group.Cold_Stacks := Group.Cold_Stacks + 1;
         Group.Cold_Stack_Bytes :=
           Group.Cold_Stack_Bytes + C.unsigned_long_long (Contexts.Stack_Size (Item.Context));
         if Item.Dormancy_Policy = Cold_Advice then
            Group.Cold_Advice_Accepted := Group.Cold_Advice_Accepted + 1;
         else
            Group.Pageout_Advice_Accepted := Group.Pageout_Advice_Accepted + 1;
         end if;
      elsif Result < 0 then
         if Item.Dormancy_Policy = Cold_Advice then
            Group.Cold_Advice_Failures := Group.Cold_Advice_Failures + 1;
         else
            Group.Pageout_Advice_Failures := Group.Pageout_Advice_Failures + 1;
         end if;
      end if;
   end Consider_Dormant_Stack;

   function Promote_Expired_Timers (Group : not null Loop_Group_Access) return Duration is
      Now  : constant Duration := Clock;
      Item : Fiber_Access;
   begin
      while Group.Timer_Count > 0 loop
         Item := Group.Timers (1);
         if Item.State /= Waiting or else Item.Timer_Index /= 1 then
            Fatal;
         end if;
         case Scheduling.Classify_Deadline (Item.Deadline, Now) is
            when Scheduling.No_Deadline_Set =>
               Fatal;

            when Scheduling.Expired         =>
               --  A queued descriptor cancellation owns every way out of the
               --  original wait. The next scheduler turn drains it before
               --  timer promotion can make the fiber runnable or reusable.
               if Item.Descriptor_Cancel_Queued then
                  return 0.0;
               end if;
               Remove_Timer_Locked (Group, Item);
               Item.Timed_Out := True;
               if Item.IO_Wait then
                  Item.IO_Result := 0;
               end if;
               Remove_IO_Waits_Locked (Group, Item);
               Enqueue (Group, Item);

            when Scheduling.Pending         =>
               return Scheduling.Time_Until (Item.Deadline, Now);
         end case;
      end loop;
      return Scheduling.Time_Until (No_Deadline, Now);
   end Promote_Expired_Timers;

   function Initialize (Environment : System.Address) return C.int is
      Invalid_Pool_Size_Message : aliased constant String :=
        "flyology: FLYOLOGY_LOOP_POOL_SIZE must be an integer from 1 through" & " 128" & ASCII.LF;
      Result                    : C.int;
      Pool_Size                 : C.int;
      Written                   : C.long;
      pragma Unreferenced (Written);
   begin
      if Environment = System.Null_Address or else Initialized then
         return -1;
      end if;

      Pool_Size := Startup_Pool_Size;
      if Pool_Size < 1 or else Pool_Size > Dedicated_First_Id then
         Written := C_Write (2, Invalid_Pool_Size_Message'Address, Invalid_Pool_Size_Message'Length);
         return -1;
      end if;

      Result := OSI.pthread_mutex_init (Topology_Lock.Value'Access, null);
      if Result /= 0 then
         return -1;
      end if;
      for Shard in Registry_Shard_Index loop
         Result := OSI.pthread_mutex_init (Registry_Shard_Locks (Shard).Value'Access, null);
         if Result /= 0 then
            return -1;
         end if;
      end loop;

      Result := Install_Fork_Guard (Fork_Child_State'Address);
      if Result /= 0 then
         return -1;
      end if;

      Placement_Platform_Initialized := False;
      Placement_Initialization_Result := 0;
      Placement_Requests := Placement_Config.Requests;
      if Placement_Config.Any_Request then
         Placement_Initialization_Result := Initialize_Thread_Placement;
         Placement_Platform_Initialized := True;
      end if;

      --  Do not allocate a group, poller, context, stack, or pthread here.
      --  Ensure_Group creates the complete event machinery when the first
      --  designated lightweight task is activated. Until then native programs
      --  stay on the stock GNARL execution path.
      Automatic_Pool_Size := Positive (Pool_Size);
      Automatic_Placement_Claims := (others => 0);
      Reduction_Phase_Code := C.int (Scheduling.Reduction_Phase'Pos (Scheduling.No_Reduction));
      Reduction_Target := Pool_Size;
      Reduction_Destination := System.Null_Address;
      Initialized := True;
      Fork_Child_State := 0;
      Lifecycle_State := 0;
      Created_Group_Count := 0;
      return 0;
   end Initialize;

   --  Count creates that claimed a registry shard and may therefore still
   --  name, read, or lock an execution group. Reading every shard under its
   --  own lock keeps this off the topology lock.
   function Outstanding_Create_Claims return Natural is
      Total : Natural := 0;
   begin
      for Shard in Registry_Shard_Index loop
         Lock_Registry_Shard (Shard);
         Total := Total + Registry_Creators (Shard);
         Unlock_Registry_Shard (Shard);
      end loop;
      return Total;
   end Outstanding_Create_Claims;

   --  Claims are refused once the finalizing state is published, so an
   --  outstanding one only has to reach its revalidated lifecycle check. The
   --  wait is bounded; a claim that never drains leaves cleanup to process
   --  exit instead of destroying a poller or group mutex under a live create.
   function Drained_Create_Claims return Natural is
      Claims : Natural := Outstanding_Create_Claims;
   begin
      for Attempt in 1 .. 1_000 loop
         exit when Claims = 0;
         exit when Micro_Sleep (1_000) /= 0;
         Claims := Outstanding_Create_Claims;
      end loop;
      return Claims;
   end Drained_Create_Claims;

   procedure Finalize is
      Target : Loop_Group_Access;
      Item   : Fiber_Access;
      Next   : Fiber_Access;
      Result : C.int;
      Safe   : Boolean := True;
   begin
      if In_Fork_Child then
         return;
      elsif not Initialized then
         Lifecycle_State := 3;
         return;
      end if;

      --  Prevent creation before inspecting the registry. GNARL calls this
      --  only after global tasks and controlled library objects have been
      --  finalized; taking every shard makes an unexpected live operation
      --  finish before the quiescence decision.
      Lifecycle_State := 2;
      --  A terminating lightweight task notifies its Ada master immediately
      --  before Fiber_Main switches back for its final scheduler-side reap.
      --  Give that already-terminated wrapper a bounded opportunity to make
      --  the registry quiescent. This is not a wait for live application
      --  work: after at most 100 one-millisecond pauses cleanup is deferred
      --  to exit. The pause matters when the environment task outranks its
      --  loop pthread and sched_yield alone would immediately reschedule it.
      for Attempt in 1 .. 100 loop
         Safe := True;
         for Shard in Registry_Shard_Index loop
            Lock_Registry_Shard (Shard);
         end loop;
         Lock_Topology;
         --  Ensure_Group republishes the running state when it starts a group
         --  and can have done so between the store above and this lock.
         --  Restating the finalizing state under the lock that Ensure_Group
         --  revalidates makes finalization impossible to reopen.
         Lifecycle_State := 2;

         --  Static library-level ATCBs are not passed to Finalize_TCB even
         --  after their wrappers finish. At this final GNARL boundary they
         --  cannot run again, so release their Finished fiber records just as
         --  Destroy does for dynamically allocated task objects.
         for Index in Group_Index loop
            Target := Groups (Index);
            if Target /= null then
               Lock_Group (Target);
               Item := Target.Fibers;
               while Item /= null loop
                  Next := Item.Next_Group;
                  if Item.State = Finished then
                     if Item.Reaping then
                        --  Reap_From_Scheduler owns this item even while it
                        --  temporarily drops the group lock to establish the
                        --  registry/topology lock order. Leaving it registered
                        --  keeps this finalization attempt nonquiescent until
                        --  the scheduler completes that exclusive reap.
                        Faults.Release_Final_Reaper;
                     else
                        Reap_Locked (Item);
                     end if;
                  end if;
                  Item := Next;
               end loop;
               Unlock_Group (Target);
            end if;
         end loop;

         for Bucket in Registry_Bucket_Index loop
            if Fiber_Registry (Bucket) /= null then
               Safe := False;
            end if;
         end loop;
         for Index in Group_Index loop
            Target := Groups (Index);
            if Target /= null then
               Lock_Group (Target);
               if not Group_Quiescent_Locked (Target) then
                  Safe := False;
               end if;
               Unlock_Group (Target);
            end if;
         end loop;
         exit when Safe or else Attempt = 100;

         Unlock_Topology;
         for Shard in reverse Registry_Shard_Index loop
            Unlock_Registry_Shard (Shard);
         end loop;
         Result := Micro_Sleep (1_000);
         if Result /= 0 then
            Lifecycle_State := 4;
            return;
         end if;
      end loop;

      if not Safe then
         Lifecycle_State := 4;
         Unlock_Topology;
         for Shard in reverse Registry_Shard_Index loop
            Unlock_Registry_Shard (Shard);
         end loop;
         return;
      end if;

      for Index in Group_Index loop
         Target := Groups (Index);
         if Target /= null then
            Lock_Group (Target);
            Target.Stop_Requested := True;
            Unlock_Group (Target);
         end if;
      end loop;
      Unlock_Topology;
      for Shard in reverse Registry_Shard_Index loop
         Unlock_Registry_Shard (Shard);
      end loop;
      --  Test-only: hand the widened create window to a parked creator now
      --  that the groups are stopped but not yet joined or freed.
      Faults.Release_Create_Registration;

      --  Wake every successful group before joining any one of them. A wake
      --  failure must not turn finalization into an unbounded join.
      for Index in Group_Index loop
         Target := Groups (Index);
         if Target /= null and then Target.Started and then not Pollers.Wake (Target.Scheduler_Poller) then
            Lifecycle_State := 4;
            return;
         end if;
      end loop;

      for Index in Group_Index loop
         Target := Groups (Index);
         if Target /= null then
            Result := Pthread_Join (Target.Event_Thread, System.Null_Address);
            if Result /= 0 then
               Lifecycle_State := 4;
               return;
            end if;
         end if;
      end loop;

      --  Joined threads cannot race their group resources, but a create that
      --  claimed a shard before the finalizing state was stored can still be
      --  holding a group pointer. Destroying group resources is admitted only
      --  once the registry is quiescent and every claim has been released.
      if not Scheduling.Teardown_Admitted (Lifecycle_State, Safe, Drained_Create_Claims) then
         Lifecycle_State := 4;
         return;
      end if;

      --  Cleanup remains a one-shot process-finalization operation; the
      --  runtime is not reset.
      for Index in Group_Index loop
         Target := Groups (Index);
         if Target /= null then
            Pollers.Finalize (Target.Scheduler_Poller);
            Contexts.Destroy (Target.Scheduler_Context);
            Free_Timer_Heap (Target.Timers);
            Result := OSI.pthread_mutex_destroy (Target.Lock.Value'Access);
            if Result /= 0 then
               Lifecycle_State := 4;
               return;
            end if;
            Free_Group (Target);
            Groups (Index) := null;
         end if;
      end loop;
      Created_Group_Count := 0;
      Event_Runtime_Active := 0;

      for Shard in Registry_Shard_Index loop
         Result := OSI.pthread_mutex_destroy (Registry_Shard_Locks (Shard).Value'Access);
         if Result /= 0 then
            Lifecycle_State := 4;
            return;
         end if;
      end loop;
      Result := OSI.pthread_mutex_destroy (Topology_Lock.Value'Access);
      if Result /= 0 then
         Lifecycle_State := 4;
         return;
      end if;

      Initialized := False;
      Lifecycle_State := 3;
   exception
      when others =>
         Lifecycle_State := 4;
   end Finalize;

   function Create
     (T : System.Address; Stack_Size : C.size_t; Priority : C.int; Wrapper : System.Address; Group : C.int)
      return C.int
   is
      Item              : Fiber_Access;
      Target            : Loop_Group_Access;
      Shard             : constant Registry_Shard_Index := Registry_Shard_For (T);
      Group_Id          : C.int := Group;
      Automatic         : constant Boolean := Group < 0;
      Automatic_Claimed : Boolean := False;

      procedure Release_Claim;
      --  Give back the registry-shard creation claim taken below.

      procedure Release_Claim is
      begin
         Lock_Registry_Shard (Shard);
         Registry_Creators (Shard) := Registry_Creators (Shard) - 1;
         Unlock_Registry_Shard (Shard);
      end Release_Claim;

   begin
      if not Initialized
        or else not Scheduling.Creation_Admitted (Lifecycle_State)
        or else T = System.Null_Address
        or else Stack_Size = 0
        or else Wrapper = System.Null_Address
        or else Priority < C.int (System.Any_Priority'First)
        or else Priority > C.int (System.Any_Priority'Last)
      then
         return -1;
      end if;

      if not Automatic and then not Scheduling.Shared_Group (Group_Id) then
         return -1;
      end if;

      --  Claim the registry shard before naming an execution group. The guard
      --  above is an unlocked read, so a creator can pass it and then be
      --  descheduled for the whole of finalization; a claim taken under the
      --  shard lock is instead visible to Finalize, which refuses to destroy
      --  a poller, a group mutex, or a group while any claim is outstanding.
      --  Everything this function reads through Target is therefore live.
      Lock_Registry_Shard (Shard);
      if not Scheduling.Creation_Admitted (Lifecycle_State) then
         Unlock_Registry_Shard (Shard);
         return -1;
      end if;
      Registry_Creators (Shard) := Registry_Creators (Shard) + 1;
      Unlock_Registry_Shard (Shard);

      if Automatic then
         --  Select only after the lifecycle claim is visible. A reduction
         --  that wins before this point changes the modulus; one that wins
         --  afterward observes the per-group placement claim below.
         Group_Id := Select_Automatic_Group;
         Automatic_Claimed := True;
         if Faults.Enabled
           and then Faults.Fail (Faults.Automatic_Placement_Window)
           and then not Faults.Pause_Automatic_Placement
         then
            Release_Automatic_Placement_Claim (Group_Id);
            Release_Claim;
            return -1;
         end if;
      end if;

      Target := Ensure_Group (Group_Id, Dedicated => False);
      if Target = null then
         if Automatic_Claimed then
            Release_Automatic_Placement_Claim (Group_Id);
         end if;
         Release_Claim;
         return -1;
      end if;

      if Faults.Enabled and then Faults.Fail (Faults.Fiber_Allocation) then
         if Automatic_Claimed then
            Release_Automatic_Placement_Claim (Group_Id);
         end if;
         Release_Claim;
         return -1;
      end if;
      Item := new Fiber;
      Item.T := T;
      Item.Wrapper := Wrapper;
      Item.Priority := Priority;
      Item.Group := Target;
      Item.Automatic_Placement := Automatic;
      Item.Context :=
        Contexts.Create (Stack_Size, Fiber_Main'Address, Fiber_To_Address (Item), Target.Scheduler_Context);
      if Item.Context = null then
         Free_Fiber (Item);
         if Automatic_Claimed then
            Release_Automatic_Placement_Claim (Group_Id);
         end if;
         Release_Claim;
         return -1;
      end if;

      --  Test-only widening of the create window. It parks a creator that
      --  holds a claim and a started group so a concurrent finalization
      --  reaches its quiescence decision before this registration.
      if Faults.Enabled
        and then Faults.Fail (Faults.Create_Lifecycle_Window)
        and then not Faults.Pause_Create_Registration
      then
         Contexts.Destroy (Item.Context);
         Free_Fiber (Item);
         if Automatic_Claimed then
            Release_Automatic_Placement_Claim (Group_Id);
         end if;
         Release_Claim;
         return -1;
      end if;

      Lock_Registry_Shard (Shard);
      Faults.Note_Create_Registering;
      Registry_Creators (Shard) := Registry_Creators (Shard) - 1;
      --  Revalidate the lifecycle now that the shard is held. Finalize stores
      --  the finalizing state before it acquires any shard, so a creator that
      --  passed the unlocked guard and then lost the race must refuse rather
      --  than register into a group Finalize has already stopped.
      if not Scheduling.Creation_Admitted (Lifecycle_State) or else Find (T) /= null then
         if Automatic_Claimed then
            Release_Automatic_Placement_Claim (Group_Id);
            Automatic_Claimed := False;
         end if;
         Unlock_Registry_Shard (Shard);
         Contexts.Destroy (Item.Context);
         Free_Fiber (Item);
         return -1;
      end if;
      if Registry_Instances (Shard) = Instance_Sequence_Last then
         Fatal;
      end if;
      Registry_Instances (Shard) := Registry_Instances (Shard) + 1;
      Item.Instance := C.unsigned_long_long (Shard) * Instance_Shard_Span + Registry_Instances (Shard);
      Lock_Group (Target);
      --  Fail closed rather than trust the claim alone. A member added to a
      --  stopped group makes the event loop's stop check an invariant
      --  violation, which aborts the process.
      if Target.Stop_Requested then
         Unlock_Group (Target);
         if Automatic_Claimed then
            Release_Automatic_Placement_Claim (Group_Id);
            Automatic_Claimed := False;
         end if;
         Unlock_Registry_Shard (Shard);
         Contexts.Destroy (Item.Context);
         Free_Fiber (Item);
         return -1;
      end if;
      Register_Locked (Item);
      Link_Group_Head_Locked (Target, Item);
      Target.Member_Count := Target.Member_Count + 1;
      Enqueue (Target, Item);
      Event_Runtime_Active := 1;
      Unlock_Group (Target);
      if Automatic_Claimed then
         --  Keep the claim until membership is visible. Holding the registry
         --  shard prevents finalization from destroying Topology_Lock before
         --  this release.
         Release_Automatic_Placement_Claim (Group_Id);
         Automatic_Claimed := False;
      end if;
      Unlock_Registry_Shard (Shard);
      if not Pollers.Wake (Target.Scheduler_Poller) then
         Fatal (Poller_Failure);
      end if;
      return 0;
   end Create;

   function Is_Lightweight_Task (T : System.Address) return C.int is
      Result : C.int;
      Shard  : Registry_Shard_Index;
   begin
      if Event_Runtime_Active = 0 or else T = System.Null_Address then
         return 0;
      end if;
      Shard := Registry_Shard_For (T);
      Lock_Registry_Shard (Shard);
      Result := (if Find (T) = null then 0 else 1);
      Unlock_Registry_Shard (Shard);
      return Result;
   end Is_Lightweight_Task;

   function Is_Event_Thread return Boolean
   is (Initialized and then Thread_Group /= null and then OSI.pthread_self = Thread_Group.Event_Thread);

   function Current_Task return System.Address
   is (if Is_Event_Thread and then Thread_Group.Current_Fiber /= null
       then Thread_Group.Current_Fiber.T
       else System.Null_Address);

   --  Result of a direct fiber suspension point whose caller is inside a
   --  protected action. The public wrappers turn it into Program_Error with
   --  GNARL's "potentially blocking operation" wording.
   Blocked_In_Protected_Action : constant C.int := -2;

   --  GNARL's Lock and Unlock maintain this counter for a lightweight task
   --  because the patched System.Tasking.Detect_Blocking reports true for
   --  it. Only the task itself changes the counter, and it cannot run
   --  concurrently with a scheduler entry made on its own stack, so the
   --  unlocked read cannot race. The protected object's pthread mutex is
   --  held by the fiber's current event-loop thread for the whole action: a
   --  suspension here would park that thread's group behind the mutex, and
   --  a migration would later release the mutex from a thread that does not
   --  own it.
   function In_Protected_Action (Item : not null Fiber_Access) return Boolean
   is (Address_To_Task_Id (Item.T).Common.Protected_Action_Nesting > 0);

   function Task_Thread (T : System.Address) return OSI.Thread_Id is
      Item   : Fiber_Access;
      Result : OSI.Thread_Id;
      Shard  : constant Registry_Shard_Index := Registry_Shard_For (T);
   begin
      Lock_Registry_Shard (Shard);
      Item := Find (T);
      Result := (if Item = null then OSI.pthread_self else Item.Group.Event_Thread);
      Unlock_Registry_Shard (Shard);
      return Result;
   end Task_Thread;

   function Current_Group return C.int
   is (if Current_Task = System.Null_Address then -1 else Thread_Group.Id);

   function Current_Task_Instance return C.unsigned_long_long
   is (if Is_Event_Thread and then Thread_Group.Current_Fiber /= null
       then Thread_Group.Current_Fiber.Instance
       else 0);

   --  Native tasks and the environment task never set Thread_Group, so they
   --  keep the compiler's ordinary per-thread cursor.
   function Current_Trampoline_Control_Slot return System.Address
   is (if Thread_Group /= null and then Thread_Group.Trampoline_Fiber /= null
       then Thread_Group.Trampoline_Fiber.Trampoline_Control'Address
       else System.Null_Address);

   function Set_Current_Dormancy (Policy : C.int; Minimum_Wait_Nanoseconds : C.long_long) return C.int is
      Group     : constant Loop_Group_Access := Thread_Group;
      Item      : Fiber_Access;
      Whole     : C.long_long;
      Remainder : C.long_long;
   begin
      if not Is_Event_Thread
        or else Group.Current_Fiber = null
        or else Policy not in 0 | 1 | 2
        or else Minimum_Wait_Nanoseconds < 0
      then
         return -1;
      end if;

      Whole := Minimum_Wait_Nanoseconds / 1_000_000_000;
      Remainder := Minimum_Wait_Nanoseconds mod 1_000_000_000;
      Lock_Group (Group);
      Item := Group.Current_Fiber;
      Item.Dormancy_Policy := Dormancy_Advice'Val (Policy);
      Item.Dormancy_Minimum_Wait := Duration (Whole) + Duration (Remainder) / 1_000_000_000;
      Unlock_Group (Group);
      return 0;
   exception
      when others =>
         Fatal;
   end Set_Current_Dormancy;

   function Current_Dormancy return C.int is
      Group  : constant Loop_Group_Access := Thread_Group;
      Item   : Fiber_Access;
      Result : C.int;
   begin
      if not Is_Event_Thread or else Group.Current_Fiber = null then
         return -1;
      end if;
      Lock_Group (Group);
      Item := Group.Current_Fiber;
      Result := C.int (Dormancy_Advice'Pos (Item.Dormancy_Policy));
      Unlock_Group (Group);
      return Result;
   exception
      when others =>
         Fatal;
   end Current_Dormancy;

   function Cold_Advice_Supported return C.int
   is (if Contexts.Cold_Advice_Supported then 1 else 0);

   function Pageout_Advice_Supported return C.int
   is (if Contexts.Pageout_Advice_Supported then 1 else 0);

   function Configured_Pool_Size return C.int
   is (C.int (Automatic_Pool_Size));

   procedure Count_Pool_Reduction_Population_Locked
     (Target_Size      : C.int;
      Automatic_Tasks  : out Natural;
      Pinned_Tasks     : out Natural;
      Waiting_Tasks    : out Natural;
      Explicit_Tasks   : out Natural;
      Placement_Claims : out Natural)
   is
      Group : Loop_Group_Access;
      Item  : Fiber_Access;
   begin
      Automatic_Tasks := 0;
      Pinned_Tasks := 0;
      Waiting_Tasks := 0;
      Explicit_Tasks := 0;
      Placement_Claims := 0;

      for Index in Group_Index range Natural (Target_Size) .. Natural (Dedicated_First_Id - 1) loop
         Placement_Claims := Placement_Claims + Automatic_Placement_Claims (Index);
         Group := Groups (Index);
         if Group /= null then
            Lock_Group (Group);
            Item := Group.Fibers;
            while Item /= null loop
               if Item.Automatic_Placement then
                  Automatic_Tasks := Automatic_Tasks + 1;
                  if Item.Thread_Pin_Count /= 0 then
                     Pinned_Tasks := Pinned_Tasks + 1;
                  end if;
                  if Item.State = Waiting then
                     Waiting_Tasks := Waiting_Tasks + 1;
                  end if;
               else
                  Explicit_Tasks := Explicit_Tasks + 1;
               end if;
               Item := Item.Next_Group;
            end loop;
            Unlock_Group (Group);
         end if;
      end loop;
   end Count_Pool_Reduction_Population_Locked;

   procedure Collect_Pool_Reduction_Status_Locked (Status : out Runtime_Pool_Reduction_Status) is
      Automatic_Tasks : Natural := 0;
      Pinned_Tasks    : Natural := 0;
      Waiting_Tasks   : Natural := 0;
      Explicit_Tasks  : Natural := 0;
      Claims          : Natural := 0;
      Phase           : Scheduling.Reduction_Phase :=
        Scheduling.Reduction_Phase'Val (Integer (Reduction_Phase_Code));
   begin
      Status :=
        (Phase                   => C.int (Scheduling.Reduction_Phase'Pos (Phase)),
         Target_Size             => Reduction_Target,
         Automatic_Tasks         => 0,
         Pinned_Automatic_Tasks  => 0,
         Waiting_Automatic_Tasks => 0,
         Explicit_Tasks          => 0,
         Placement_Claims        => 0);

      if Phase = Scheduling.No_Reduction then
         Status.Target_Size := C.int (Automatic_Pool_Size);
         return;
      end if;

      Count_Pool_Reduction_Population_Locked
        (Target_Size      => Reduction_Target,
         Automatic_Tasks  => Automatic_Tasks,
         Pinned_Tasks     => Pinned_Tasks,
         Waiting_Tasks    => Waiting_Tasks,
         Explicit_Tasks   => Explicit_Tasks,
         Placement_Claims => Claims);

      if Phase = Scheduling.Reduction_Draining and then Scheduling.Reduction_Drained (Automatic_Tasks, Claims)
      then
         Phase := Scheduling.Reduction_Complete;
         Reduction_Phase_Code := C.int (Scheduling.Reduction_Phase'Pos (Phase));
         Reduction_Destination := System.Null_Address;
      end if;

      Status :=
        (Phase                   => C.int (Scheduling.Reduction_Phase'Pos (Phase)),
         Target_Size             => Reduction_Target,
         Automatic_Tasks         => C.unsigned_long_long (Automatic_Tasks),
         Pinned_Automatic_Tasks  => C.unsigned_long_long (Pinned_Tasks),
         Waiting_Automatic_Tasks => C.unsigned_long_long (Waiting_Tasks),
         Explicit_Tasks          => C.unsigned_long_long (Explicit_Tasks),
         Placement_Claims        => C.unsigned_long_long (Claims));
   end Collect_Pool_Reduction_Status_Locked;

   function Grow_Configured_Pool (Minimum_Size : C.int) return C.int is
      Result : C.int := -1;
      Status : Runtime_Pool_Reduction_Status;
   begin
      if In_Fork_Child
        or else not Initialized
        or else Minimum_Size < 1
        or else Minimum_Size > Dedicated_First_Id
      then
         return -1;
      end if;

      Lock_Topology;
      if Initialized and then Scheduling.Creation_Admitted (Lifecycle_State) then
         if Reduction_Phase_Code = C.int (Scheduling.Reduction_Phase'Pos (Scheduling.Reduction_Draining)) then
            Collect_Pool_Reduction_Status_Locked (Status);
         end if;
         if Reduction_Phase_Code /= C.int (Scheduling.Reduction_Phase'Pos (Scheduling.Reduction_Draining))
         then
            Automatic_Pool_Size :=
              Positive
                (Scheduling.Growth_Target
                   (Scheduling.Pool_Size (Automatic_Pool_Size), Scheduling.Pool_Size (Minimum_Size)));
            Reduction_Phase_Code := C.int (Scheduling.Reduction_Phase'Pos (Scheduling.No_Reduction));
            Reduction_Target := C.int (Automatic_Pool_Size);
            Reduction_Destination := System.Null_Address;
            Result := 0;
         end if;
      end if;
      Unlock_Topology;
      return Result;
   exception
      when others =>
         Fatal;
   end Grow_Configured_Pool;

   function Request_Pool_Reduction (Maximum_Size : C.int) return C.int is
      Decision        : Scheduling.Reduction_Decision;
      Status          : Runtime_Pool_Reduction_Status;
      Target          : Loop_Group_Access;
      Start_Phase     : Scheduling.Reduction_Phase;
      Automatic_Tasks : Natural;
      Pinned_Tasks    : Natural;
      Waiting_Tasks   : Natural;
      Explicit_Tasks  : Natural;
      Claims          : Natural;
   begin
      if In_Fork_Child
        or else not Initialized
        or else Maximum_Size < 1
        or else Maximum_Size > Dedicated_First_Id
      then
         return -1;
      end if;

      Lock_Topology;
      if Reduction_Phase_Code = C.int (Scheduling.Reduction_Phase'Pos (Scheduling.Reduction_Draining)) then
         Collect_Pool_Reduction_Status_Locked (Status);
      end if;
      Decision :=
        Scheduling.Plan_Reduction
          (Scheduling.Pool_Size (Automatic_Pool_Size),
           Scheduling.Pool_Size (Maximum_Size),
           Scheduling.Reduction_Phase'Val (Integer (Reduction_Phase_Code)));
      case Decision is
         when Scheduling.Already_At_Or_Below   =>
            Unlock_Topology;
            return 1;

         when Scheduling.Reduction_In_Progress =>
            Unlock_Topology;
            return 2;

         when Scheduling.Start_Reduction       =>
            Count_Pool_Reduction_Population_Locked
              (Target_Size      => Maximum_Size,
               Automatic_Tasks  => Automatic_Tasks,
               Pinned_Tasks     => Pinned_Tasks,
               Waiting_Tasks    => Waiting_Tasks,
               Explicit_Tasks   => Explicit_Tasks,
               Placement_Claims => Claims);
            Start_Phase := Scheduling.Reduction_Start_Phase (Automatic_Tasks, Claims);
            if Start_Phase = Scheduling.Reduction_Complete then
               --  No automatic work or pre-cutover selection needs a drainage
               --  destination. Publish the completed cutover without starting
               --  group 0, preserving the dormant native-only path.
               Reduction_Target := Maximum_Size;
               Automatic_Pool_Size := Positive (Maximum_Size);
               Reduction_Destination := System.Null_Address;
               Reduction_Phase_Code := C.int (Scheduling.Reduction_Phase'Pos (Start_Phase));
               Unlock_Topology;
               return 0;
            end if;
      end case;
      Unlock_Topology;

      --  Establish the destination before publishing the smaller ceiling. A
      --  startup failure therefore leaves the existing configuration intact
      --  instead of creating a reduction that can never make progress.
      Target := Ensure_Group (0, Dedicated => False);
      if Target = null then
         return -1;
      end if;

      Lock_Topology;
      if Reduction_Phase_Code = C.int (Scheduling.Reduction_Phase'Pos (Scheduling.Reduction_Draining)) then
         Collect_Pool_Reduction_Status_Locked (Status);
      end if;
      Decision :=
        Scheduling.Plan_Reduction
          (Scheduling.Pool_Size (Automatic_Pool_Size),
           Scheduling.Pool_Size (Maximum_Size),
           Scheduling.Reduction_Phase'Val (Integer (Reduction_Phase_Code)));
      case Decision is
         when Scheduling.Already_At_Or_Below   =>
            Unlock_Topology;
            return 1;

         when Scheduling.Reduction_In_Progress =>
            Unlock_Topology;
            return 2;

         when Scheduling.Start_Reduction       =>
            Reduction_Destination := Group_To_Address (Target);
            Reduction_Target := Maximum_Size;
            Automatic_Pool_Size := Positive (Maximum_Size);
            Reduction_Phase_Code := C.int (Scheduling.Reduction_Phase'Pos (Scheduling.Reduction_Draining));
            Collect_Pool_Reduction_Status_Locked (Status);
            Unlock_Topology;
            return 0;
      end case;
   exception
      when others =>
         Fatal;
   end Request_Pool_Reduction;

   function Query_Pool_Reduction (Status : System.Address; Status_Size : C.size_t) return C.int is
      Output : constant Runtime_Pool_Reduction_Status_Access := To_Runtime_Pool_Reduction_Status (Status);
   begin
      if In_Fork_Child
        or else not Initialized
        or else Status = System.Null_Address
        or else Status_Size /= Runtime_Pool_Reduction_Status'Size / 8
      then
         return -1;
      end if;
      Lock_Topology;
      Collect_Pool_Reduction_Status_Locked (Output.all);
      Unlock_Topology;
      return 0;
   exception
      when others =>
         Fatal;
   end Query_Pool_Reduction;

   function Configured_Placement return C.int
   is (0);

   function Placement_Supported (Mode : C.int) return C.int is
   begin
      if In_Fork_Child or else not Initialized then
         return 0;
      elsif Mode in Strict_CPU_Mode | Advisory_Tag_Mode then
         return Thread_Placement_Supported (Mode);
      else
         return (if Mode = No_Placement_Mode then 1 else 0);
      end if;
   end Placement_Supported;

   function Placement_Value_Available (Mode : C.int; Value : C.int) return C.int is
      Result : C.int;
   begin
      if Mode = No_Placement_Mode then
         return (if Value = 0 then 1 else 0);
      end if;
      if In_Fork_Child
        or else not Initialized
        or else Mode not in Strict_CPU_Mode | Advisory_Tag_Mode
        or else Thread_Placement_Supported (Mode) = 0
      then
         return 0;
      end if;
      Lock_Topology;
      Result := Ensure_Placement_Platform;
      if Result = 0 then
         Result := Validate_Thread_Placement (Mode, Value);
      end if;
      Unlock_Topology;
      return (if Result = 0 then 1 else 0);
   end Placement_Value_Available;

   function Configure_Group_Placement (Group : C.int; Mode : C.int; Value : C.int) return C.int is
      Target  : Loop_Group_Access;
      Current : Placement_Request;
      Result  : C.int;
   begin
      if In_Fork_Child or else not Initialized then
         return 5;
      elsif not Scheduling.Valid_Group (Group)
        or else Mode not in No_Placement_Mode | Strict_CPU_Mode | Advisory_Tag_Mode
        or else (Mode = No_Placement_Mode and then Value /= 0)
      then
         return 3;
      elsif Mode /= No_Placement_Mode and then Thread_Placement_Supported (Mode) = 0 then
         return 2;
      end if;

      Lock_Topology;
      Current := Placement_Requests (Group_Index (Group));
      Target := Groups (Group_Index (Group));
      if Target /= null then
         if Target.Placement_Mode = Mode and then Target.Placement_Value = Value then
            Result := 1;
         else
            Result := 4;
         end if;
      elsif Current.Mode = Mode and then Current.Value = Value then
         Result := 1;
      elsif Mode /= No_Placement_Mode and then Ensure_Placement_Platform /= 0 then
         Result := 5;
      elsif Mode /= No_Placement_Mode and then Validate_Thread_Placement (Mode, Value) /= 0 then
         Result := 3;
      else
         Placement_Requests (Group_Index (Group)) := (Mode => Mode, Value => Value);
         Result := 0;
      end if;
      Unlock_Topology;
      return Result;
   end Configure_Group_Placement;

   function Query_Group_Placement
     (Group : C.int; Status : System.Address; Status_Size : C.size_t) return C.int
   is
      Output  : Runtime_Placement_Status_Access;
      Target  : Loop_Group_Access;
      Request : Placement_Request;
   begin
      if Status = System.Null_Address
        or else Status_Size /= Runtime_Placement_Status'Size / 8
        or else not Scheduling.Valid_Group (Group)
      then
         return -1;
      end if;
      Output := To_Runtime_Placement_Status (Status);
      if In_Fork_Child or else not Initialized then
         Output.all := (Mode => No_Placement_Mode, Value => 0, State => 4, Error_Code => 0);
         return 0;
      end if;

      Lock_Topology;
      Target := Groups (Group_Index (Group));
      Request := Placement_Requests (Group_Index (Group));
      if Target = null then
         Output.all :=
           (Mode       => Request.Mode,
            Value      => Request.Value,
            State      => (if Request.Mode = No_Placement_Mode then 0 else 1),
            Error_Code => 0);
      else
         Output.all :=
           (Mode       => Target.Placement_Mode,
            Value      => Target.Placement_Value,
            State      =>
              (if Target.Placement_Mode = No_Placement_Mode
               then 0
               elsif Target.Placement_Applied
               then 2
               elsif Target.Placement_Result /= 0
               then 3
               else 1),
            Error_Code => Target.Placement_Result);
      end if;
      Unlock_Topology;
      return 0;
   end Query_Group_Placement;

   function Current_Processor return C.int
   is (Thread_Current_Processor);

   function Create_Dedicated_Group return C.int is
      Id        : C.int;
      Group     : Loop_Group_Access;
      Item      : Fiber_Access;
      Current   : constant System.Address := Current_Task;
      Shard     : constant Registry_Shard_Index := Registry_Shard_For (Current);
      Available : Boolean;
   begin
      if not Initialized or else Current = System.Null_Address then
         return -1;
      end if;

      for Attempt in 1 .. Natural (Maximum_Group_Id - Dedicated_First_Id + 1) loop
         Lock_Registry_Shard (Shard);
         Lock_Topology;
         Item := Find (Current);
         if Item = null or else not Item.Can_Migrate or else Item.Reserved_Group /= null then
            Unlock_Topology;
            Unlock_Registry_Shard (Shard);
            return -1;
         end if;

         Id := Dedicated_First_Id;
         Group := null;
         while Id <= Maximum_Group_Id loop
            Group := Groups (Group_Index (Id));
            exit when Group = null;
            Available := False;
            if Group.Dedicated then
               Lock_Group (Group);
               Available :=
                 Scheduling.Dedicated_Available
                   (Group.Member_Count, Group.Reserved_For /= System.Null_Address);
               Unlock_Group (Group);
            end if;
            exit when Available;
            Id := Id + 1;
         end loop;
         if Id > Maximum_Group_Id then
            Unlock_Topology;
            Unlock_Registry_Shard (Shard);
            return -1;
         elsif Group /= null then
            Group.Reserved_For := Current;
            Item.Reserved_Group := Group;
            Unlock_Topology;
            Unlock_Registry_Shard (Shard);
            return Id;
         end if;
         Unlock_Topology;
         Unlock_Registry_Shard (Shard);

         Group := Ensure_Group (Id, Dedicated => True);
         if Group = null then
            return -1;
         end if;
         --  Another caller can reserve the newly created group before this
         --  task reacquires the registry. The bounded outer loop simply
         --  searches again instead of recursively consuming the Ada stack.
      end loop;
      return -1;
   end Create_Dedicated_Group;

   function Is_Dedicated_Group (Group : C.int) return C.int is
      Item   : Loop_Group_Access;
      Result : C.int;
   begin
      if not Initialized or else not Scheduling.Valid_Group (Group) then
         return 0;
      end if;
      Lock_Topology;
      Item := Groups (Group_Index (Group));
      Result := (if Item /= null and then Item.Dedicated then 1 else 0);
      Unlock_Topology;
      return Result;
   end Is_Dedicated_Group;

   function Observe_Group (Group : C.int; Snapshot : System.Address; Snapshot_Size : C.size_t) return C.int is
      Target : Loop_Group_Access;
      Item   : Fiber_Access;
      Output : Runtime_Group_Snapshot_Access;
      Uptime : Duration := 0.0;
      Idle   : Duration := 0.0;
   begin
      if Snapshot = System.Null_Address
        or else Snapshot_Size /= Runtime_Group_Snapshot'Size / 8
        or else not Scheduling.Valid_Group (Group)
      then
         return -1;
      elsif In_Fork_Child or else not Initialized then
         return 0;
      end if;

      Lock_Topology;
      Target := Groups (Group_Index (Group));
      if Target = null then
         Unlock_Topology;
         return 0;
      end if;

      Lock_Group (Target);
      Read_Utilization_Locked (Target, Uptime, Idle);
      Output := To_Runtime_Group_Snapshot (Snapshot);
      Output.all :=
        (ABI_Version              => 6,
         Thread_State             => (if Target.Start_Failed then 3 elsif Target.Started then 2 else 1),
         Dedicated                => (if Target.Dedicated then 1 else 0),
         Reserved                 => (if Target.Reserved_For = System.Null_Address then 0 else 1),
         Members                  => C.unsigned_long_long (Target.Member_Count),
         Pinned_Members           => 0,
         Ready                    => 0,
         Waiting                  => 0,
         Running                  => 0,
         Migrating                => 0,
         Finished                 => 0,
         Timer_Waits              => C.unsigned_long_long (Target.Timer_Count),
         Descriptor_Waits         => 0,
         Interrupt_Waits          => 0,
         File_Waits               => 0,
         Pending_File_Submissions => 0,
         Dormancy_Candidates      => 0,
         Dormancy_Candidate_Bytes => 0,
         Cold_Stacks              => Target.Cold_Stacks,
         Cold_Stack_Bytes         => Target.Cold_Stack_Bytes,
         Cold_Advice_Attempts     => Target.Cold_Advice_Attempts,
         Cold_Advice_Accepted     => Target.Cold_Advice_Accepted,
         Cold_Advice_Failures     => Target.Cold_Advice_Failures,
         Pageout_Advice_Attempts  => Target.Pageout_Advice_Attempts,
         Pageout_Advice_Accepted  => Target.Pageout_Advice_Accepted,
         Pageout_Advice_Failures  => Target.Pageout_Advice_Failures,
         Dispatches               => Target.Dispatches,
         Poll_Batches             => Target.Poll_Batches,
         Poll_Events              => Target.Poll_Events,
         Wakeups                  => Target.Wakeups,
         Migrations_In            => Target.Migrations_In,
         Migrations_Out           => Target.Migrations_Out,
         Uptime_Nanoseconds       => To_Nanoseconds (Uptime),
         Idle_Nanoseconds         => To_Nanoseconds (Idle),
         Idle_Waits               => Target.Idle_Waits);

      Output.Pending_File_Submissions := C.unsigned_long_long (Target.Pending_Async_File_Count);

      Item := Target.Fibers;
      while Item /= null loop
         case Item.State is
            when Ready     =>
               Output.Ready := Output.Ready + 1;

            when Waiting   =>
               Output.Waiting := Output.Waiting + 1;

            when Running   =>
               Output.Running := Output.Running + 1;

            when Migrating =>
               Output.Migrating := Output.Migrating + 1;

            when Finished  =>
               Output.Finished := Output.Finished + 1;
         end case;
         if Item.IO_Wait then
            Output.Descriptor_Waits := Output.Descriptor_Waits + 1;
            if Item.IO_Interrupt_Wait then
               Output.Interrupt_Waits := Output.Interrupt_Waits + 1;
            end if;
         end if;
         if Item.Thread_Pin_Count /= 0 then
            Output.Pinned_Members := Output.Pinned_Members + 1;
         end if;
         if Item.File_Wait then
            Output.File_Waits := Output.File_Waits + 1;
         end if;
         Output.File_Waits := Output.File_Waits + C.unsigned_long_long (Item.Active_Async_Files);
         if Item.File_Pending then
            Output.Pending_File_Submissions := Output.Pending_File_Submissions + 1;
         end if;
         if Item.State = Waiting
           and then Item.Timer_Index /= 0
           and then not Item.IO_Wait
           and then not Item.File_Wait
         then
            Output.Dormancy_Candidates := Output.Dormancy_Candidates + 1;
            Output.Dormancy_Candidate_Bytes :=
              Output.Dormancy_Candidate_Bytes + C.unsigned_long_long (Contexts.Stack_Size (Item.Context));
         end if;
         Item := Item.Next_Group;
      end loop;

      Unlock_Group (Target);
      Unlock_Topology;
      return 1;
   exception
      when others =>
         Fatal;
   end Observe_Group;

   function Observe_Tasks
     (Group         : C.int;
      Items         : System.Address;
      Capacity      : C.size_t;
      Item_Size     : C.size_t;
      Metadata      : System.Address;
      Metadata_Size : C.size_t) return C.int
   is
      Target   : Loop_Group_Access;
      Item     : Fiber_Access;
      Output   : Runtime_Task_Snapshot_Access;
      Summary  : Runtime_Task_Snapshot_Metadata_Access;
      Written  : Natural := 0;
      Expected : Natural;
      Flags    : C.unsigned;
   begin
      if Items = System.Null_Address
        or else Capacity = 0
        or else Capacity > C.size_t (Natural'Last)
        or else Item_Size /= Runtime_Task_Snapshot'Size / 8
        or else Metadata = System.Null_Address
        or else Metadata_Size /= Runtime_Task_Snapshot_Metadata'Size / 8
        or else not Scheduling.Valid_Group (Group)
      then
         return -1;
      elsif In_Fork_Child or else not Initialized then
         return 0;
      end if;

      Lock_Topology;
      Target := Groups (Group_Index (Group));
      if Target = null then
         Unlock_Topology;
         return 0;
      end if;

      Lock_Group (Target);
      Summary := To_Runtime_Task_Snapshot_Metadata (Metadata);
      Summary.all :=
        (Version => Task_Snapshot_ABI_Version,
         Written => 0,
         Total   => C.unsigned_long_long (Target.Member_Count));
      Expected := Natural'Min (Target.Member_Count, Natural (Capacity));
      Item := Target.Fibers;
      while Item /= null and then Written < Expected loop
         Output :=
           To_Runtime_Task_Snapshot
             (Items + SSE.Storage_Offset (Written) * SSE.Storage_Offset (Runtime_Task_Snapshot'Size / 8));
         Flags := 0;
         if Item.Thread_Pin_Count /= 0 then
            Flags := Flags or Task_Pinned_Flag;
         end if;
         if Item.Timer_Index /= 0 then
            Flags := Flags or Task_Timer_Wait_Flag;
         end if;
         if Item.IO_Wait then
            Flags := Flags or Task_Descriptor_Wait_Flag;
         end if;
         if Item.File_Wait or else Item.Active_Async_Files /= 0 then
            Flags := Flags or Task_File_Wait_Flag;
         end if;
         if Item.File_Pending then
            Flags := Flags or Task_File_Pending_Flag;
         end if;
         if Item.Destroy_Requested then
            Flags := Flags or Task_Destroy_Requested_Flag;
         end if;
         Output.all :=
           (Instance           => Item.Instance,
            State              =>
              (case Item.State is
                 when Ready     => 0,
                 when Waiting   => 1,
                 when Running   => 2,
                 when Migrating => 3,
                 when Finished  => 4),
            Base_Priority      => Item.Priority,
            Flags              => Flags,
            Stack_Usable_Bytes => C.unsigned_long_long (Contexts.Stack_Size (Item.Context)));
         Written := Written + 1;
         Item := Item.Next_Group;
      end loop;
      if Written /= Expected then
         Fatal;
      end if;
      Summary.Written := C.unsigned_long_long (Written);
      Unlock_Group (Target);
      Unlock_Topology;
      return 1;
   exception
      when others =>
         Fatal;
   end Observe_Tasks;

   function Observe_Last_Fatal return C.int
   is (Last_Fatal_Context);

   function Observe_Lifecycle return C.int
   is (if In_Fork_Child then 5 else Lifecycle_State);

   function Observe_Created_Groups return C.int
   is (if In_Fork_Child then 0 else Created_Group_Count);

   function Migrate (Group : C.int) return C.int is
      Item                : Fiber_Access;
      Source              : Loop_Group_Access;
      Target              : Loop_Group_Access;
      Current             : constant System.Address := Current_Task;
      Shard               : constant Registry_Shard_Index := Registry_Shard_For (Current);
      Target_Member_Count : Natural := 0;
      Reservation_Matches : Boolean := False;
   begin
      if Current = System.Null_Address then
         return -1;
      end if;

      --  Refuse before any other outcome, including the same-group no-op:
      --  migration is a potentially blocking operation whatever Group
      --  names, so the refusal must not depend on the current placement.
      Source := Thread_Group;
      if In_Protected_Action (Source.Current_Fiber) then
         return Blocked_In_Protected_Action;
      end if;

      if not Scheduling.Valid_Group (Group) then
         return -1;
      end if;
      if Source.Id = Group then
         return 0;
      end if;

      --  Reject before lazily creating the destination. Only this fiber can
      --  change its pin count, and it cannot run concurrently with this call.
      Lock_Group (Source);
      Item := Source.Current_Fiber;
      if Item = null or else Item.Thread_Pin_Count /= 0 or else Item.Active_Async_Files /= 0 then
         Unlock_Group (Source);
         return -1;
      end if;
      Unlock_Group (Source);

      if Scheduling.Shared_Group (Group) then
         Target := Ensure_Group (Group, Dedicated => False);
      else
         Lock_Topology;
         Target := Groups (Group_Index (Group));
         Unlock_Topology;
      end if;
      if Target = null then
         return -1;
      end if;

      Lock_Registry_Shard (Shard);
      Lock_Topology;
      if Target.Dedicated then
         Lock_Group (Target);
         Target_Member_Count := Target.Member_Count;
         Unlock_Group (Target);
         Reservation_Matches := Target.Reserved_For = Current;
      end if;
      Lock_Group (Source);
      Item := Source.Current_Fiber;
      if Item = null
        or else Item.Group /= Source
        or else Find (Current) /= Item
        or else Item.Thread_Pin_Count /= 0
        or else Item.Active_Async_Files /= 0
        or else not Scheduling.Migration_Allowed
                      (Can_Migrate         => Item.Can_Migrate,
                       Target_Dedicated    => Target.Dedicated,
                       Target_Member_Count => Target_Member_Count,
                       Reservation_Matches => Reservation_Matches and then Item.Reserved_Group = Target)
      then
         Unlock_Group (Source);
         Unlock_Topology;
         Unlock_Registry_Shard (Shard);
         return -1;
      end if;

      Item.Migration_Target := Target;
      --  An explicit migration transfers placement ownership to the caller.
      --  Later automatic-pool reductions must not undo that choice.
      Item.Automatic_Placement := False;
      Item.Enqueue_At_Head := False;
      Item.State := Migrating;
      Unlock_Topology;
      Unlock_Registry_Shard (Shard);
      Contexts.Switch (Item.Context, Source.Scheduler_Context);
      return 0;
   end Migrate;

   function Pin_Current_Thread (Owner : access System.Address) return C.int is
      Group   : constant Loop_Group_Access := Thread_Group;
      Item    : Fiber_Access;
      Current : constant System.Address := Current_Task;
   begin
      if Owner = null then
         return -1;
      end if;
      Owner.all := Current;

      --  Native tasks are already permanently tied to their pthread. Treat
      --  pinning as a successful no-op so code that calls foreign libraries
      --  does not need a lane-specific branch.
      if Current = System.Null_Address then
         return 0;
      end if;

      Lock_Group (Group);
      Item := Group.Current_Fiber;
      if Item = null or else Item.Group /= Group or else Item.Thread_Pin_Count = Natural'Last then
         Unlock_Group (Group);
         return -1;
      end if;
      Item.Thread_Pin_Count := Item.Thread_Pin_Count + 1;
      Unlock_Group (Group);
      return 0;
   exception
      when others =>
         Fatal;
   end Pin_Current_Thread;

   function Unpin_Current_Thread (Owner : System.Address) return C.int is
      Group : constant Loop_Group_Access := Thread_Group;
      Item  : Fiber_Access;
   begin
      if Owner = System.Null_Address then
         return 0;
      elsif Current_Task /= Owner then
         --  A scoped pin belongs to the Ada task that acquired it. Reject a
         --  guard transferred to and finalized by another task instead of
         --  accidentally decrementing that task's pin count.
         return -1;
      end if;

      Lock_Group (Group);
      Item := Group.Current_Fiber;
      if Item = null or else Item.Group /= Group or else Item.Thread_Pin_Count = 0 then
         Unlock_Group (Group);
         return -1;
      end if;
      Item.Thread_Pin_Count := Item.Thread_Pin_Count - 1;
      Unlock_Group (Group);
      return 0;
   exception
      when others =>
         Fatal;
   end Unpin_Current_Thread;

   function Current_Thread_Is_Pinned return C.int is
      Group  : constant Loop_Group_Access := Thread_Group;
      Item   : Fiber_Access;
      Result : C.int;
   begin
      --  A native task cannot migrate, so its pthread identity is inherently
      --  stable even though it has no scheduler pin counter.
      if Current_Task = System.Null_Address then
         return 1;
      end if;

      Lock_Group (Group);
      Item := Group.Current_Fiber;
      Result :=
        (if Item /= null and then Item.Group = Group and then Item.Thread_Pin_Count /= 0 then 1 else 0);
      Unlock_Group (Group);
      return Result;
   exception
      when others =>
         Fatal;
   end Current_Thread_Is_Pinned;

   function In_Lightweight_Task return C.int
   is (if Current_Task = System.Null_Address then 0 else 1);

   function Wait_IO_Many
     (Requests            : System.Address;
      Count               : C.unsigned;
      Timeout_Nanoseconds : C.long_long;
      Interrupt_Wait      : C.int) return C.int
   is
      Group     : constant Loop_Group_Access := Thread_Group;
      Whole     : C.long_long;
      Remainder : C.long_long;
      Timeout   : Duration;

      function Do_Wait (Actual_Count : IO_Link_Kind) return C.int;

      function Do_Wait (Actual_Count : IO_Link_Kind) return C.int is
         Item               : Fiber_Access;
         --  The suspended fiber owns exactly the links needed by this wait.
         --  Raising the heterogeneous-set ceiling therefore does not charge
         --  every ordinary one-descriptor wait for the maximum stack frame.
         Links              : aliased IO_Wait_Link_Array (1 .. Actual_Count);
         Kernel_Watches     : Pollers.Interest_Request_Array (1 .. Actual_Count);
         Kernel_Watch_Count : Natural := 0;

         function Request_At (Index : Positive) return Runtime_Wait_Request;
         function Plan_Arm (Index : Positive) return Boolean;
         procedure Register_Arm (Index : Positive);

         function Request_At (Index : Positive) return Runtime_Wait_Request is
            Bytes : constant SSE.Storage_Offset :=
              SSE.Storage_Offset
                ((Index - 1) * (Runtime_Wait_Request_Array'Component_Size / System.Storage_Unit));
         begin
            return Wait_Request_Conversions.To_Pointer (Requests + Bytes).all;
         end Request_At;

         function Plan_Arm (Index : Positive) return Boolean is
            Request            : constant Runtime_Wait_Request := Request_At (Index);
            Interest           : constant Pollers.Interest :=
              (if Request.For_Write = 0 then Pollers.Readable else Pollers.Writable);
            Needs_Kernel_Watch : Boolean;
         begin
            if Request.Descriptor < 0 or else Request.For_Write not in 0 | 1 then
               return False;
            end if;
            Needs_Kernel_Watch := not IO_Interest_Registered_Locked (Group, Request.Descriptor, Interest);
            if Needs_Kernel_Watch then
               for Planned in 1 .. Kernel_Watch_Count loop
                  if Kernel_Watches (Planned).Descriptor = Request.Descriptor
                    and then Kernel_Watches (Planned).Condition = Interest
                  then
                     Needs_Kernel_Watch := False;
                     exit;
                  end if;
               end loop;
            end if;
            if Needs_Kernel_Watch then
               Kernel_Watch_Count := Kernel_Watch_Count + 1;
               Kernel_Watches (Kernel_Watch_Count) :=
                 (Descriptor => Request.Descriptor, Condition => Interest);
            end if;
            return True;
         end Plan_Arm;

         procedure Register_Arm (Index : Positive) is
            Request  : constant Runtime_Wait_Request := Request_At (Index);
            Interest : constant Pollers.Interest :=
              (if Request.For_Write = 0 then Pollers.Readable else Pollers.Writable);
         begin
            Register_IO_Wait_Locked
              (Group, Item, Request.Descriptor, Interest, IO_Link_Kind (Index), C.int (Index));
         end Register_Arm;
      begin
         Lock_Group (Group);
         Item := Group.Current_Fiber;
         Item.Active_IO_Links := Links (1)'Unchecked_Access;
         Item.Active_IO_Link_Count := Natural (Actual_Count);
         Item.Deadline := (if Timeout < 0.0 then No_Deadline else Clock + Timeout);
         Item.Timed_Out := False;
         Item.IO_Result := 0;
         Item.IO_Interrupt_Wait := Interrupt_Wait /= 0;
         Item.State := Waiting;
         if not Register_Timer_Locked (Group, Item) then
            Item.State := Running;
            Item.Deadline := No_Deadline;
            Item.Active_IO_Links := null;
            Item.Active_IO_Link_Count := 0;
            Unlock_Group (Group);
            return -1;
         end if;

         --  Reverse registration preserves the public rule that the lowest
         --  request index wins when duplicates become ready together.
         for Index in reverse 1 .. Positive (Actual_Count) loop
            if not Plan_Arm (Index) then
               Remove_Timer_Locked (Group, Item);
               Item.State := Running;
               Item.Active_IO_Links := null;
               Item.Active_IO_Link_Count := 0;
               Unlock_Group (Group);
               return -1;
            end if;
         end loop;
         if Kernel_Watch_Count > 0
           and then not Pollers.Watch_Many (Group.Scheduler_Poller, Kernel_Watches (1 .. Kernel_Watch_Count))
         then
            if not Pollers.Cancel_Many (Group.Scheduler_Poller, Kernel_Watches (1 .. Kernel_Watch_Count)) then
               Fatal (Poller_Failure);
            end if;
            Remove_Timer_Locked (Group, Item);
            Item.State := Running;
            Item.Active_IO_Links := null;
            Item.Active_IO_Link_Count := 0;
            Unlock_Group (Group);
            return -1;
         end if;
         for Index in reverse 1 .. Positive (Actual_Count) loop
            Register_Arm (Index);
         end loop;

         Item.Enqueue_At_Head := False;
         Contexts.Switch (Item.Context, Group.Scheduler_Context);
         Item.Active_IO_Links := null;
         Item.Active_IO_Link_Count := 0;
         return Item.IO_Result;
      end Do_Wait;
   begin
      --  Current_Fiber belongs exclusively to this event thread until the
      --  locked state transition below.
      if not Is_Event_Thread
        or else Group.Current_Fiber = null
        or else Requests = System.Null_Address
        or else Count = 0
        or else Count > C.unsigned (Max_IO_Link_Count)
        or else Interrupt_Wait not in 0 | 1
      then
         return -1;
      end if;

      --  A readiness wait parks the fiber while the protected object's mutex
      --  stays held by this event-loop thread, so a same-group peer that
      --  contends for it would park the only thread able to resume the
      --  holder.
      if In_Protected_Action (Group.Current_Fiber) then
         return Blocked_In_Protected_Action;
      end if;

      if Timeout_Nanoseconds < 0 then
         Timeout := No_Deadline;
      else
         Whole := Timeout_Nanoseconds / 1_000_000_000;
         Remainder := Timeout_Nanoseconds mod 1_000_000_000;
         Timeout := Duration (Whole) + Duration (Remainder) / 1_000_000_000;
      end if;

      return Do_Wait (IO_Link_Kind (Count));
   end Wait_IO_Many;

   function File_Operation
     (Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : C.int;
      For_Send_ZC : Boolean;
      Cancel_FD   : C.int;
      Task_Lock   : System.Address;
      Transferred : access C.long_long;
      Error_Code  : access C.int;
      Cancelled   : access C.int) return C.int
   is
      Group       : constant Loop_Group_Access := Thread_Group;
      Item        : Fiber_Access;
      Error       : C.int := 0;
      Lock_Result : C.int;
   begin
      --  The submitted buffer lives on the fiber stack and remains valid
      --  while its context is suspended. File completions, unlike ordinary
      --  GNARL wakes, are the only path that may resume this state.
      if not Is_Event_Thread
        or else Group.Current_Fiber = null
        or else Descriptor < 0
        or else Buffer = System.Null_Address
        or else Transferred = null
        or else Error_Code = null
        or else Cancelled = null
        or else Cancel_FD < -1
        or else Task_Lock = System.Null_Address
      then
         return -1;
      elsif In_Protected_Action (Group.Current_Fiber) then
         --  A completion wait parks the fiber while the protected object's
         --  mutex stays held by this event-loop thread. Refusing before any
         --  submission also keeps the borrowed buffer out of the kernel.
         return Blocked_In_Protected_Action;
      elsif For_Send_ZC and then not Pollers.Supports_Send_ZC (Group.Scheduler_Poller) then
         Transferred.all := 0;
         Error_Code.all := 0;
         Cancelled.all := 0;
         return 1;
      end if;

      --  Test-only gate for the abort race between GNARL's pending-ATC check
      --  and publication of Waiting. The wrapper still holds Task_Lock here,
      --  so Abort_Task cannot pass that boundary until the handoff below.
      while Faults.Enabled and then Faults.Fail (Faults.File_Pre_Park) loop
         Lock_Result := Sched_Yield;
         if Lock_Result /= 0 then
            Fatal (Mutex_Failure);
         end if;
      end loop;

      Lock_Group (Group);
      Item := Group.Current_Fiber;
      Item.State := Waiting;
      Item.File_Wait := True;
      Item.File_Pending := False;
      Item.File_Result := 0;
      Item.File_Error := 0;
      Item.File_Descriptor := Descriptor;
      Item.File_Buffer := Buffer;
      Item.File_Length := Length;
      Item.File_Offset := Offset;
      Item.File_For_Write := For_Write /= 0;
      Item.File_Send_ZC := For_Send_ZC;
      Item.File_Cancel_Descriptor := Cancel_FD;
      Item.File_Cancel_Requested := False;
      Item.File_Cancel_Queued := False;
      Item.File_Cancel_Disposition := 0;
      Item.File_Cancel_Error := 0;
      Item.Active_IO_Links := null;
      Item.Active_IO_Link_Count := 0;
      if Cancel_FD >= 0 then
         Item.Active_IO_Links := Item.Inline_IO_Links (Primary_IO)'Unchecked_Access;
         Item.Active_IO_Link_Count := 1;
         if not IO_Interest_Registered_Locked (Group, Cancel_FD, Pollers.Readable)
           and then not Pollers.Watch (Group.Scheduler_Poller, Cancel_FD, Pollers.Readable)
         then
            Item.File_Wait := False;
            Item.File_Cancel_Descriptor := -1;
            Item.Active_IO_Links := null;
            Item.Active_IO_Link_Count := 0;
            Item.State := Running;
            Unlock_Group (Group);
            return -1;
         end if;
         Register_IO_Wait_Locked (Group, Item, Cancel_FD, Pollers.Readable, Primary_IO, 0);
      end if;
      if not (if For_Send_ZC
              then
                Pollers.Submit_Send_ZC
                  (Group.Scheduler_Poller, Descriptor, Buffer, Length, Fiber_To_Address (Item), Error)
              else
                Pollers.Submit_File
                  (Group.Scheduler_Poller,
                   Descriptor,
                   Buffer,
                   Length,
                   Offset,
                   For_Write /= 0,
                   Fiber_To_Address (Item),
                   Error))
      then
         if Error = C.int (OSI.EAGAIN) then
            Queue_Pending_File_Locked (Group, Item);
         else
            Item.File_Wait := False;
            Item.State := Running;
            Item.File_Descriptor := -1;
            Item.File_Buffer := System.Null_Address;
            Item.File_Length := 0;
            Item.File_Offset := 0;
            Item.File_For_Write := False;
            Item.File_Send_ZC := False;
            Item.File_Cancel_Descriptor := -1;
            Remove_IO_Waits_Locked (Group, Item);
            Item.Active_IO_Links := null;
            Item.Active_IO_Link_Count := 0;
            Unlock_Group (Group);
            Error_Code.all := Error;
            Transferred.all := 0;
            return -1;
         end if;
      end if;

      Item.Enqueue_At_Head := False;
      --  Match GNARL's condition-variable handoff: the wrapper enters with
      --  the task lock held, and Waiting is visible under the group lock
      --  before abort can acquire that task lock and call Wake.
      Lock_Result := Mutex_Unlock (Task_Lock);
      if Lock_Result /= 0 then
         Fatal (Mutex_Failure);
      end if;
      Contexts.Switch (Item.Context, Group.Scheduler_Context);
      Lock_Result := Mutex_Lock (Task_Lock);
      if Lock_Result /= 0 then
         Fatal (Mutex_Failure);
      end if;
      Transferred.all := Item.File_Result;
      Error_Code.all := Item.File_Error;
      Cancelled.all := (if Item.File_Cancel_Requested then 1 else 0);
      Item.File_Cancel_Requested := False;
      Item.File_Cancel_Disposition := 0;
      Item.File_Cancel_Error := 0;
      Item.Active_IO_Links := null;
      Item.Active_IO_Link_Count := 0;
      return 0;
   end File_Operation;

   function File_IO
     (Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : C.int;
      Cancel_FD   : C.int;
      Task_Lock   : System.Address;
      Transferred : access C.long_long;
      Error_Code  : access C.int;
      Cancelled   : access C.int) return C.int is
   begin
      --  Value 2 is an internal extension of the existing GNARL handoff for
      --  a socket SEND_ZC. Reusing this entry point preserves the task-lock
      --  abort boundary without adding another platform patch surface.
      return
        File_Operation
          (Descriptor,
           Buffer,
           Length,
           Offset,
           (if For_Write = 2 then 0 else For_Write),
           For_Write = 2,
           Cancel_FD,
           Task_Lock,
           Transferred,
           Error_Code,
           Cancelled);
   end File_IO;

   function Set_Priority (T : System.Address; Priority : C.int; Loss_Of_Inheritance : C.int) return C.int is
      Item  : Fiber_Access;
      Shard : Registry_Shard_Index;
   begin
      if T = System.Null_Address
        or else Priority < C.int (System.Any_Priority'First)
        or else Priority > C.int (System.Any_Priority'Last)
      then
         return -1;
      end if;

      Shard := Registry_Shard_For (T);
      Lock_Registry_Shard (Shard);
      Item := Find (T);
      if Item = null then
         Unlock_Registry_Shard (Shard);
         return -1;
      end if;
      Lock_Group (Item.Group);

      if Item.State = Ready then
         Remove_From_Ready (Item.Group, Item);
         Item.Priority := Priority;
         Item.Enqueue_At_Head :=
           Scheduling.Placement_After_Priority_Update (Loss_Of_Inheritance /= 0) = Scheduling.Queue_Head;
         Enqueue (Item.Group, Item);
      else
         Item.Priority := Priority;
         Item.Enqueue_At_Head :=
           Scheduling.Placement_After_Priority_Update (Loss_Of_Inheritance /= 0) = Scheduling.Queue_Head;
      end if;
      Unlock_Group (Item.Group);
      Unlock_Registry_Shard (Shard);
      return 0;
   end Set_Priority;

   function Yield return C.int is
      Group : constant Loop_Group_Access := Thread_Group;
      Item  : Fiber_Access;
   begin
      --  Current_Fiber is owned by this event thread while user code runs;
      --  the unlocked test is validation, and the mutation is locked below.
      if not Is_Event_Thread or else Group.Current_Fiber = null then
         return -1;
      end if;

      Lock_Group (Group);
      Item := Group.Current_Fiber;
      Enqueue (Group, Item);
      Contexts.Switch (Item.Context, Group.Scheduler_Context);
      return 0;
   end Yield;

   function Sleep (Task_Lock : System.Address; Deadline : Duration; Timed_Out : access C.int) return C.int is
      Group  : constant Loop_Group_Access := Thread_Group;
      Item   : Fiber_Access;
      Result : C.int;
   begin
      --  Current_Fiber is owned by this event thread while user code runs;
      --  the unlocked test is validation, and the mutation is locked below.
      if not Is_Event_Thread or else Group.Current_Fiber = null then
         return -1;
      end if;

      Lock_Group (Group);
      Item := Group.Current_Fiber;
      Item.Deadline := Deadline;
      Item.Timed_Out := False;
      Item.State := Waiting;

      if not Register_Timer_Locked (Group, Item) then
         Item.Deadline := No_Deadline;
         Item.State := Running;
         Unlock_Group (Group);
         return -1;
      end if;

      if Task_Lock /= System.Null_Address then
         Result := Mutex_Unlock (Task_Lock);
         if Result /= 0 then
            Remove_Timer_Locked (Group, Item);
            Item.State := Running;
            Unlock_Group (Group);
            return -1;
         end if;
      end if;

      Item.Enqueue_At_Head := False;
      Contexts.Switch (Item.Context, Group.Scheduler_Context);

      if Task_Lock /= System.Null_Address then
         Result := Mutex_Lock (Task_Lock);
         if Result /= 0 then
            Fatal;
         end if;
      end if;
      if Timed_Out /= null then
         Timed_Out.all := (if Item.Timed_Out then 1 else 0);
      end if;
      return 0;
   end Sleep;

   function Wake (T : System.Address) return C.int is
      Item      : Fiber_Access;
      Group     : Loop_Group_Access;
      Need_Wake : Boolean := False;
      Shard     : constant Registry_Shard_Index := Registry_Shard_For (T);
   begin
      Lock_Registry_Shard (Shard);
      Item := Find (T);
      if Item = null then
         Unlock_Registry_Shard (Shard);
         return -1;
      end if;

      Group := Item.Group;
      Lock_Group (Group);
      if Item.State = Waiting and then Item.File_Wait then
         --  Wake may run on a foreign native thread while the owning loop is
         --  inside Wait_Batch and mutating its file engine. Record intent
         --  only; the loop thread performs kernel cancellation.
         Queue_File_Cancel_Locked (Group, Item);
         Need_Wake := True;
         Group.Wakeups := Group.Wakeups + 1;
      elsif Item.State = Waiting
        and then Item.IO_Wait
        and then not Pollers.Retains_Orphaned_One_Shots
      then
         --  Linux Wait_Batch is the sole owner of the poller's linked
         --  registration records while the group lock is released. A foreign
         --  abort or ATC therefore queues cancellation for the loop thread.
         Queue_Descriptor_Cancel_Locked (Group, Item);
         Need_Wake := True;
         Group.Wakeups := Group.Wakeups + 1;
      elsif Item.State = Waiting then
         Remove_Timer_Locked (Group, Item);
         Item.Timed_Out := False;
         Remove_IO_Waits_Locked (Group, Item);
         Enqueue (Group, Item);
         Need_Wake := True;
         Group.Wakeups := Group.Wakeups + 1;
      end if;
      Unlock_Group (Group);
      Unlock_Registry_Shard (Shard);

      if Need_Wake and then not Pollers.Wake (Group.Scheduler_Poller) then
         Fatal (Poller_Failure);
      end if;
      return 0;
   end Wake;

   function Destroy (T : System.Address) return C.int is
      Item  : Fiber_Access;
      Shard : Registry_Shard_Index;
   begin
      if not Initialized or else T = System.Null_Address then
         return -1;
      end if;

      Shard := Registry_Shard_For (T);
      Lock_Registry_Shard (Shard);
      Lock_Topology;
      Item := Find (T);
      if Item = null then
         Unlock_Topology;
         Unlock_Registry_Shard (Shard);
         return -1;
      end if;
      Lock_Group (Item.Group);

      if Item.Reaping then
         Unlock_Group (Item.Group);
         Unlock_Topology;
         Unlock_Registry_Shard (Shard);
         return 0;
      end if;

      Item.T := System.Null_Address;
      Item.Destroy_Requested := True;

      case Scheduling.Plan_Destroy (Phase_Of (Item.State)) is
         when Scheduling.Defer    =>
            Unlock_Group (Item.Group);
            Unlock_Topology;
            Unlock_Registry_Shard (Shard);
            return 0;

         when Scheduling.Reap_Now =>
            declare
               Group : constant Loop_Group_Access := Item.Group;
            begin
               Reap_Locked (Item);
               Unlock_Group (Group);
            end;
            Unlock_Topology;
            Unlock_Registry_Shard (Shard);
            return 0;
      end case;
   end Destroy;

   procedure Fiber_Main (Argument : System.Address) is
      Item  : constant Fiber_Access := Address_To_Fiber (Argument);
      Group : Loop_Group_Access;
      type Wrapper_Access is access procedure (T : System.Address);
      pragma Convention (C, Wrapper_Access);
      function To_Wrapper is new Ada.Unchecked_Conversion (System.Address, Wrapper_Access);
   begin
      To_Wrapper (Item.Wrapper).all (Item.T);

      if Faults.Enabled and then Faults.Fail (Faults.Final_Reap_Window) then
         declare
            Destroy_Observed : Boolean := False;
         begin
            --  Test-only ordering control: make the wrapper/master handoff
            --  complete before this fiber publishes Finished. This guarantees
            --  that the scheduler, rather than Destroy, owns the final reap.
            for Attempt in 1 .. 1_000 loop
               Group := Item.Group;
               Lock_Group (Group);
               Destroy_Observed := Item.Destroy_Requested;
               Unlock_Group (Group);
               exit when Destroy_Observed;
               if Micro_Sleep (1_000) /= 0 then
                  Fatal;
               end if;
            end loop;
            if not Destroy_Observed then
               Fatal;
            end if;
         end;
      end if;

      Group := Item.Group;
      Lock_Group (Group);
      Item.Enqueue_At_Head := False;
      Item.State := Finished;
      Item.Deadline := No_Deadline;
      Contexts.Switch (Item.Context, Group.Scheduler_Context);
      Fatal (Context_Failure);
   end Fiber_Main;

   procedure Handle_Poll_Event (Group : not null Loop_Group_Access; Event : Pollers.Poll_Event) is
      Bucket  : IO_Bucket_Index;
      Item    : Fiber_Access;
      Link    : IO_Wait_Link_Access;
      Matches : Boolean;
      Outcome : C.int;
   begin
      if Event.Kind = Pollers.File_Event then
         if Event.Token = System.Null_Address then
            Fatal;
         elsif Is_Async_File_Token (Event.Token) then
            declare
               Node : constant Async_File_Node_Access :=
                 To_Async_File_Node (Async_File_Node_Address (Event.Token));
            begin
               if Node = null or else Node.Version /= Async_File_Node_Version then
                  Fatal;
               end if;
               Complete_Async_File_Locked
                 (Group, Node, Event.Result, Event.Error_Code, Node.Cancel_Requested /= 0);
               Submit_Pending_Async_Files_Locked (Group);
               Submit_Pending_Files_Locked (Group);
               return;
            end;
         end if;
         Item := Address_To_Fiber (Event.Token);
         if Item.Group /= Group
           or else Item.State /= Waiting
           or else not Item.File_Wait
           or else Item.File_Pending
         then
            Fatal;
         end if;
         Complete_File_Locked (Group, Item, Event.Result, Event.Error_Code, Item.File_Cancel_Requested);
         Submit_Pending_Files_Locked (Group);
         return;
      end if;

      if Event.Kind not in Pollers.Readable_Event | Pollers.Writable_Event | Pollers.Read_Write_Event then
         return;
      end if;

      if Event.Descriptor < 0 then
         Fatal;
      end if;
      Bucket := IO_Bucket_For (Event.Descriptor);
      Link := Group.IO_Waiters (Bucket);
      while Link /= null loop
         Item := Link.Owner;
         Matches :=
           Item /= null
           and then Link.Registered
           and then Item.State = Waiting
           and then Item.IO_Wait
           and then Link.Descriptor = Event.Descriptor
           and then ((Event.Kind in Pollers.Readable_Event | Pollers.Read_Write_Event
                      and then Link.Interest = Pollers.Readable)
                     or else (Event.Kind in Pollers.Writable_Event | Pollers.Read_Write_Event
                              and then Link.Interest = Pollers.Writable));
         if Matches then
            if Item.Descriptor_Cancel_Queued then
               --  The bounded cancellation drain may leave this selected
               --  target queued. Its cancellation owns the readiness hint;
               --  retaining the wait prevents dispatch, reuse, and reap until
               --  the loop consumes the queue entry on its next turn.
               Link := Link.Next;
            elsif Item.File_Wait and then Link.Descriptor = Item.File_Cancel_Descriptor then
               if Request_File_Cancel_Locked (Group, Item) then
                  Submit_Pending_Files_Locked (Group);
               end if;
               Link := Group.IO_Waiters (Bucket);
            else
               Outcome := Link.Outcome;
               Remove_Timer_Locked (Group, Item);
               Item.Timed_Out := False;
               Item.IO_Result := Outcome;
               Remove_IO_Waits_Locked
                 (Group,
                  Item,
                  Consumed_Descriptor => Event.Descriptor,
                  Read_Consumed       => Event.Kind in Pollers.Readable_Event | Pollers.Read_Write_Event,
                  Write_Consumed      => Event.Kind in Pollers.Writable_Event | Pollers.Read_Write_Event);
               Enqueue (Group, Item);
               --  Removing all of Item's links may have changed this bucket at
               --  any position, so restart from its head. Each pass wakes one
               --  fiber and therefore makes bounded progress.
               Link := Group.IO_Waiters (Bucket);
            end if;
         else
            Link := Link.Next;
         end if;
      end loop;
   end Handle_Poll_Event;

   procedure Poll_Ready_Events (Group : not null Loop_Group_Access) is
      Waited : Boolean;
      Events : Pollers.Poll_Event_Array (1 .. Poll_Event_Budget);
      Count  : Natural;
   begin
      Unlock_Group (Group);
      Waited := Pollers.Wait_Batch (Group.Scheduler_Poller, 0.0, Events, Count);
      Lock_Group (Group);
      if not Waited then
         Fatal (Poller_Failure);
      end if;
      Group.Poll_Batches := Group.Poll_Batches + 1;
      Group.Poll_Events := Group.Poll_Events + C.unsigned_long_long (Count);
      Process_Descriptor_Cancellations_Locked (Group);
      Process_File_Cancellations_Locked (Group);
      for Index in 1 .. Count loop
         Handle_Poll_Event (Group, Events (Index));
      end loop;
   end Poll_Ready_Events;

   procedure Scheduler_Main (Argument : System.Address) is
      Group                        : constant Loop_Group_Access := Address_To_Group (Argument);
      Dispatches_Until_Timer_Check : Natural := 0;
      Timeout                      : Duration;
      Next                         : Fiber_Access;
      Waited                       : Boolean;
      Events                       : Pollers.Poll_Event_Array (1 .. Poll_Event_Budget);
      Count                        : Natural;
   begin
      --  Group_Thread holds this group's lock across the call, and this is
      --  the loop's first act, so the utilization window starts before any
      --  fiber can be dispatched here.
      Group.Started_At := Clock;
      loop
         if Group.Stop_Requested then
            if not Group_Quiescent_Locked (Group) then
               Fatal;
            end if;
            Group.Current_Fiber := null;
            Unlock_Group (Group);
            return;
         end if;
         Process_Descriptor_Cancellations_Locked (Group);
         Process_File_Cancellations_Locked (Group);
         Timeout := No_Deadline;
         if Scheduling.Maintenance_Due (Ready_Present (Group), Dispatches_Until_Timer_Check) then
            Timeout := Promote_Expired_Timers (Group);
            Dispatches_Until_Timer_Check := Timer_Check_Interval;
            if Ready_Present (Group) then
               Poll_Ready_Events (Group);
            end if;
         end if;

         Submit_Pending_Files_Locked (Group);
         Submit_Pending_Async_Files_Locked (Group);
         if (Group.Pending_File_Head /= null or else Group.Pending_Async_File_Head /= null)
           and then (Timeout < 0.0 or else Timeout > 0.001)
         then
            --  Darwin's AIO limit is process-wide, so a group may need to
            --  retry even when the completion that frees capacity belongs to
            --  another loop. The bounded poll timeout supplies that progress
            --  without a submission worker.
            Timeout := 0.001;
         end if;

         if Ready_Present (Group) then
            Next := Dequeue (Group);
            if Next = null then
               Fatal;
            end if;
            if Scheduling.Should_Drain
                 (Phase                 => Scheduling.Reduction_Phase'Val (Integer (Reduction_Phase_Code)),
                  Source                => Group.Id,
                  Target                => Scheduling.Pool_Size (Reduction_Target),
                  Automatic_Placement   => Next.Automatic_Placement,
                  Pinned                => Next.Thread_Pin_Count /= 0,
                  Can_Migrate           => Next.Can_Migrate and then Next.Active_Async_Files = 0,
                  Destination_Available => Reduction_Destination /= System.Null_Address)
            then
               Next.Migration_Target := Address_To_Group (Reduction_Destination);
               Transfer (Next, Group);
            else
               Next.State := Running;
               Group.Current_Fiber := Next;
               Group.Dispatches := Group.Dispatches + 1;
               if Dispatches_Until_Timer_Check = 0 then
                  Fatal;
               end if;
               Dispatches_Until_Timer_Check :=
                 Scheduling.After_Dispatch (Positive (Dispatches_Until_Timer_Check));
               Unlock_Group (Group);
               --  Own the trampoline cursor only while the fiber holds the
               --  thread. Control returns here from every suspension point,
               --  so scheduler work below runs on the thread's own cursor
               --  again.
               Group.Trampoline_Fiber := Next;
               Contexts.Switch (Group.Scheduler_Context, Next.Context);
               Group.Trampoline_Fiber := null;
               Consider_Dormant_Stack (Group, Next);

               if Next.Migration_Target /= null then
                  Transfer (Next, Group);
               elsif Scheduling.Should_Reap_After_Switch (Phase_Of (Next.State), Next.Destroy_Requested) then
                  Reap_From_Scheduler (Group, Next);
               end if;
            end if;
         else
            Group.Current_Fiber := null;
            --  Reached only when no fiber is ready, so this is the loop's
            --  whole idle path. Poll_Ready_Events polls with a zero timeout
            --  while work remains ready and is deliberately not counted.
            Begin_Idle_Wait_Locked (Group);
            Unlock_Group (Group);
            Waited := Pollers.Wait_Batch (Group.Scheduler_Poller, Timeout, Events, Count);
            Lock_Group (Group);
            End_Idle_Wait_Locked (Group);
            if not Waited then
               Fatal (Poller_Failure);
            end if;
            Group.Poll_Batches := Group.Poll_Batches + 1;
            Group.Poll_Events := Group.Poll_Events + C.unsigned_long_long (Count);
            Process_Descriptor_Cancellations_Locked (Group);
            Process_File_Cancellations_Locked (Group);
            for Index in 1 .. Count loop
               Handle_Poll_Event (Group, Events (Index));
            end loop;
         end if;
      end loop;
   end Scheduler_Main;

end System.Flyology.Scheduler;
