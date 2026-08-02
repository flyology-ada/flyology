with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.Gnatevl.Contexts;
with System.Gnatevl.Poller;
with System.Gnatevl.Scheduling_Policy;
with System.Gnatevl.Time_ABI;
with System.OS_Constants;
with System.Storage_Elements;

package body System.Gnatevl.Scheduler is
   package C renames Interfaces.C;
   package Contexts renames System.Gnatevl.Contexts;
   package Pollers renames System.Gnatevl.Poller;
   package Scheduling renames System.Gnatevl.Scheduling_Policy;
   package Time_ABI renames System.Gnatevl.Time_ABI;
   package OSC renames System.OS_Constants;
   package OSI renames System.OS_Interface;
   package SSE renames System.Storage_Elements;

   use type C.int;
   use type C.long_long;
   use type C.size_t;
   use type Contexts.Context_Access;
   use type OSI.pthread_t;
   use type Pollers.Event_Kind;
   use type Pollers.Interest;
   use type Scheduling.Destruction_Plan;
   use type SSE.Integer_Address;

   Timer_Check_Interval : constant := 64;
   Poll_Event_Budget    : constant := 64;
   No_Deadline          : constant Duration := Scheduling.No_Deadline;

   Default_Group_Id    : constant C.int := Scheduling.First_Shared_Group;
   Dedicated_First_Id  : constant C.int := Scheduling.First_Dedicated_Group;
   Maximum_Group_Id    : constant C.int := Scheduling.Last_Group;
   subtype Group_Index is Natural range 0 .. Natural (Maximum_Group_Id);

   --  A prime-sized table avoids clustering when aligned ATCB allocations
   --  advance by a regular stride. For the expected task populations,
   --  separate chaining keeps lookup and removal constant-time on average
   --  without introducing resize allocation into wake paths.
   Registry_Bucket_Count : constant := 16_381;
   subtype Registry_Bucket_Index is
     Natural range 0 .. Registry_Bucket_Count - 1;
   Registry_Shard_Count : constant := 64;
   subtype Registry_Shard_Index is
     Natural range 0 .. Registry_Shard_Count - 1;
   --  Readiness is local to a loop, so each group owns a smaller prime-sized
   --  descriptor table. Collision chains also represent legitimate fan-out
   --  when several tasks wait on the same descriptor and direction.
   IO_Bucket_Count : constant := 8_191;
   subtype IO_Bucket_Index is Natural range 0 .. IO_Bucket_Count - 1;

   type Fiber_State is (Running, Ready, Waiting, Migrating, Finished);

   function Phase_Of
     (State : Fiber_State) return Scheduling.Fiber_Phase
   is
     (case State is
         when Running  => Scheduling.Running,
         when Ready    => Scheduling.Ready,
         when Waiting  => Scheduling.Waiting,
         when Migrating => Scheduling.Migrating,
         when Finished => Scheduling.Finished);

   type Fiber;
   type Fiber_Access is access all Fiber;
   type Loop_Group;
   type Loop_Group_Access is access all Loop_Group;
   subtype Ready_Priority is C.int range
     C.int (System.Any_Priority'First) ..
     C.int (System.Any_Priority'Last);
   type Ready_Bucket is record
      Head : Fiber_Access;
      Tail : Fiber_Access;
   end record;
   type Ready_Bucket_Array is array (Ready_Priority) of Ready_Bucket;
   type IO_Bucket_Array is array (IO_Bucket_Index) of Fiber_Access;
   type Timer_Heap_Array is array (Positive range <>) of Fiber_Access;
   type Timer_Heap_Access is access Timer_Heap_Array;

   type Fiber is record
      T          : System.Address := System.Null_Address;
      Context    : Contexts.Context_Access;
      Wrapper    : System.Address := System.Null_Address;
      Priority   : C.int := 0;
      Deadline   : Duration := No_Deadline;
      Timer_Index : Natural := 0;
      Timed_Out  : Boolean := False;
      State      : Fiber_State := Waiting;
      IO_Wait    : Boolean := False;
      IO_Descriptor : C.int := -1;
      IO_Interest : Pollers.Interest := Pollers.Readable;
      IO_Bucket  : IO_Bucket_Index := 0;
      File_Wait  : Boolean := False;
      File_Pending : Boolean := False;
      File_Result : C.long_long := 0;
      File_Error  : C.int := 0;
      File_Descriptor : C.int := -1;
      File_Buffer : System.Address := System.Null_Address;
      File_Length : C.size_t := 0;
      File_Offset : C.long_long := 0;
      File_For_Write : Boolean := False;
      Destroy_Requested : Boolean := False;
      Reaping     : Boolean := False;
      Can_Migrate : Boolean := True;
      Group      : Loop_Group_Access;
      Migration_Target : Loop_Group_Access;
      Reserved_Group : Loop_Group_Access;
      Previous_Ready : Fiber_Access;
      Next_Ready : Fiber_Access;
      Next_Group : Fiber_Access;
      Next_IO    : Fiber_Access;
      Next_File  : Fiber_Access;
      Next_Registry : Fiber_Access;
      Registry_Bucket : Registry_Bucket_Index := 0;
      Registry_Shard  : Registry_Shard_Index := 0;
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
      Id          : C.int := -1;
      Dedicated   : Boolean := False;
      Lock        : Scheduler_Mutex;
      Started     : Boolean := False with Volatile;
      Start_Failed : Boolean := False with Volatile;
      Event_Thread : aliased OSI.pthread_t;
      Scheduler_Context : Contexts.Context_Access;
      Scheduler_Poller  : Pollers.Poller;
      Current_Fiber     : Fiber_Access;
      Ready_Buckets     : Ready_Bucket_Array :=
        (others => (Head => null, Tail => null));
      Ready_Count       : Natural := 0;
      Highest_Ready     : Ready_Priority := Ready_Priority'First;
      Fibers            : Fiber_Access;
      IO_Waiters        : IO_Bucket_Array := (others => null);
      Pending_File_Head : Fiber_Access;
      Pending_File_Tail : Fiber_Access;
      Timers            : Timer_Heap_Access;
      Timer_Count       : Natural := 0;
      Timer_Capacity    : Natural := 0;
      Member_Count      : Natural := 0;
      Reserved_For      : System.Address := System.Null_Address;
      --  Signal stacks belong to OS threads, not fibers. Keeping one with
      --  each permanent loop prevents Task_Wrapper from reserving and
      --  installing 32 KiB inside every evented task stack.
      Signal_Stack      : aliased SSE.Storage_Array
        (1 .. OSI.Alternate_Stack_Size);
   end record;

   type Group_Array is array (Group_Index) of Loop_Group_Access;
   type Registry_Bucket_Array is
     array (Registry_Bucket_Index) of Fiber_Access;
   type Registry_Shard_Lock_Array is
     array (Registry_Shard_Index) of Scheduler_Mutex;

   function Fiber_To_Address is new Ada.Unchecked_Conversion
     (Fiber_Access, System.Address);
   function Address_To_Fiber is new Ada.Unchecked_Conversion
     (System.Address, Fiber_Access);
   function Group_To_Address is new Ada.Unchecked_Conversion
     (Loop_Group_Access, System.Address);
   function Address_To_Group is new Ada.Unchecked_Conversion
     (System.Address, Loop_Group_Access);
   procedure Free_Fiber is new Ada.Unchecked_Deallocation
     (Fiber, Fiber_Access);
   procedure Free_Group is new Ada.Unchecked_Deallocation
     (Loop_Group, Loop_Group_Access);
   procedure Free_Timer_Heap is new Ada.Unchecked_Deallocation
     (Timer_Heap_Array, Timer_Heap_Access);

   --  Each registry shard protects its hash chains, fiber lifetime, and the
   --  Fiber.Group ownership pointer. Topology_Lock protects the group table,
   --  startup state, and dedicated reservations. A group lock protects that
   --  group's membership count, fiber list, ready queue, timers, I/O state,
   --  and current fiber. Code needing all three takes shard, topology, group.
   --  Hot Wake and Set_Priority paths take only one shard and one group.
   Topology_Lock  : Scheduler_Mutex;
   Registry_Shard_Locks : Registry_Shard_Lock_Array;
   Initialized    : Boolean := False;
   Event_Runtime_Active : C.int := 0;
   pragma Atomic (Event_Runtime_Active);
   Groups         : Group_Array := (others => null);
   Fiber_Registry : Registry_Bucket_Array := (others => null);
   Thread_Group   : Loop_Group_Access := null;
   pragma Thread_Local_Storage (Thread_Group);

   function Mutex_Unlock (Mutex : System.Address) return C.int;
   pragma Import (C, Mutex_Unlock, "pthread_mutex_unlock");
   function Mutex_Lock (Mutex : System.Address) return C.int;
   pragma Import (C, Mutex_Lock, "pthread_mutex_lock");
   function Sched_Yield return C.int;
   pragma Import (C, Sched_Yield, "sched_yield");

   procedure Scheduler_Main (Argument : System.Address);
   pragma Convention (C, Scheduler_Main);
   pragma No_Return (Scheduler_Main);

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
   procedure Fatal;
   pragma No_Return (Fatal);
   function Ensure_Group
     (Id : C.int; Dedicated : Boolean) return Loop_Group_Access;
   --  Registry operations require the bucket's shard lock after bootstrap
   --  publishes Initialized. The environment task is deliberately absent
   --  from this registry: only evented tasks become fibers.
   function Registry_Bucket_For
     (T : System.Address) return Registry_Bucket_Index;
   function Registry_Shard_For
     (T : System.Address) return Registry_Shard_Index;
   function Find (T : System.Address) return Fiber_Access;
   procedure Register_Locked (Item : not null Fiber_Access);
   procedure Unregister_Locked (Item : not null Fiber_Access);
   function IO_Bucket_For (Descriptor : C.int) return IO_Bucket_Index;
   procedure Register_IO_Wait_Locked
     (Group      : not null Loop_Group_Access;
      Item       : not null Fiber_Access;
      Descriptor : C.int;
      Interest   : Pollers.Interest);
   procedure Remove_IO_Wait_Locked
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access);
   procedure Queue_Pending_File_Locked
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access);
   procedure Submit_Pending_Files_Locked
     (Group : not null Loop_Group_Access);
   function Ensure_Timer_Capacity
     (Group : not null Loop_Group_Access) return Boolean;
   function Register_Timer_Locked
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access) return Boolean;
   procedure Remove_Timer_Locked
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access);
   procedure Enqueue
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access);
   procedure Remove_From_Ready
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access);
   function Ready_Present
     (Group : not null Loop_Group_Access) return Boolean;
   function Dequeue
     (Group : not null Loop_Group_Access) return Fiber_Access;
   procedure Reap_Locked (Item : not null Fiber_Access);
   procedure Reap_From_Scheduler
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access);
   procedure Transfer
     (Item   : not null Fiber_Access;
      Source : not null Loop_Group_Access);
   function Clock return Duration;
   function Promote_Expired_Timers
     (Group : not null Loop_Group_Access) return Duration;
   function Is_Event_Thread return Boolean;
   procedure Handle_Poll_Event
     (Group : not null Loop_Group_Access;
      Event : Pollers.Poll_Event);
   procedure Poll_Ready_Events (Group : not null Loop_Group_Access);

   procedure C_Abort;
   pragma Import (C, C_Abort, "abort");
   pragma No_Return (C_Abort);

   procedure Fatal is
   begin
      C_Abort;
   end Fatal;

   procedure Lock_Topology is
      Result : constant C.int :=
        OSI.pthread_mutex_lock (Topology_Lock.Value'Access);
   begin
      if Result /= 0 then
         Fatal;
      end if;
   end Lock_Topology;

   procedure Unlock_Topology is
      Result : constant C.int :=
        OSI.pthread_mutex_unlock (Topology_Lock.Value'Access);
   begin
      if Result /= 0 then
         Fatal;
      end if;
   end Unlock_Topology;

   procedure Lock_Registry_Shard (Shard : Registry_Shard_Index) is
      Result : constant C.int :=
        OSI.pthread_mutex_lock
          (Registry_Shard_Locks (Shard).Value'Access);
   begin
      if Result /= 0 then
         Fatal;
      end if;
   end Lock_Registry_Shard;

   procedure Unlock_Registry_Shard (Shard : Registry_Shard_Index) is
      Result : constant C.int :=
        OSI.pthread_mutex_unlock
          (Registry_Shard_Locks (Shard).Value'Access);
   begin
      if Result /= 0 then
         Fatal;
      end if;
   end Unlock_Registry_Shard;

   procedure Lock_Group (Group : not null Loop_Group_Access) is
      Result : constant C.int :=
        OSI.pthread_mutex_lock (Group.Lock.Value'Access);
   begin
      if Result /= 0 then
         Fatal;
      end if;
   end Lock_Group;

   procedure Unlock_Group (Group : not null Loop_Group_Access) is
      Result : constant C.int :=
        OSI.pthread_mutex_unlock (Group.Lock.Value'Access);
   begin
      if Result /= 0 then
         Fatal;
      end if;
   end Unlock_Group;

   function Group_Thread (Argument : System.Address) return System.Address is
      Group : constant Loop_Group_Access := Address_To_Group (Argument);
      Stack : aliased OSI.stack_t :=
        (ss_sp    => Group.Signal_Stack'Address,
         ss_size  => OSI.Alternate_Stack_Size,
         ss_flags => 0);
      Result : C.int;
   begin
      Thread_Group := Group;
      Result := OSI.sigaltstack (Stack'Access, null);
      Group.Scheduler_Context :=
        (if Result = 0 then Contexts.Capture else null);

      Lock_Topology;
      Group.Started := Group.Scheduler_Context /= null;
      Group.Start_Failed := not Group.Started;
      if Group.Start_Failed then
         Unlock_Topology;
         return System.Null_Address;
      end if;

      Unlock_Topology;
      Lock_Group (Group);
      Scheduler_Main (Argument);
   end Group_Thread;

   function Ensure_Group
     (Id : C.int; Dedicated : Boolean) return Loop_Group_Access
   is
      Group  : Loop_Group_Access;
      Result : C.int;
      Ready  : Boolean;
      Failed : Boolean;
   begin
      if not Initialized or else not Scheduling.Valid_Group (Id) then
         return null;
      end if;

      Lock_Topology;
      Group := Groups (Group_Index (Id));
      if Group /= null then
         if Group.Dedicated /= Dedicated
           and then Scheduling.Dedicated_Group (Id)
         then
            Unlock_Topology;
            return null;
         end if;
         Unlock_Topology;
      else
         Group := new Loop_Group;
         Group.Id := Id;
         Group.Dedicated := Dedicated;
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
         Result :=
           OSI.pthread_create
             (Group.Event_Thread'Access,
              null,
              Group_Thread'Access,
              Group_To_Address (Group));
         --  pthread_create is the sole writer of Event_Thread. The new thread
         --  cannot publish Started until it acquires Topology_Lock, which is
         --  still held here, so readers cannot observe an uninitialized id.
         if Result /= 0 then
            Groups (Group_Index (Id)) := null;
            Pollers.Finalize (Group.Scheduler_Poller);
            Free_Group (Group);
            Unlock_Topology;
            return null;
         end if;
         Unlock_Topology;
      end if;

      --  This is a bounded, first-use-only startup wait. If called by an
      --  evented task, its source loop remains occupied until the new group
      --  thread publishes Started or Start_Failed under Topology_Lock.
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

   function Registry_Bucket_For
     (T : System.Address) return Registry_Bucket_Index
   is
      --  Express the address in 16-byte allocation quanta before taking the
      --  prime modulus; sub-quantum variation merely shares a collision chain.
      Value : constant SSE.Integer_Address := SSE.To_Integer (T) / 16;
   begin
      return Registry_Bucket_Index
        (Value mod SSE.Integer_Address (Registry_Bucket_Count));
   end Registry_Bucket_For;

   function Registry_Shard_For
     (T : System.Address) return Registry_Shard_Index
   is
   begin
      return Registry_Shard_Index
        (Registry_Bucket_For (T) mod Registry_Shard_Count);
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
      Bucket : constant Registry_Bucket_Index :=
        Registry_Bucket_For (Item.T);
   begin
      Item.Registry_Bucket := Bucket;
      Item.Registry_Shard := Registry_Shard_Index
        (Bucket mod Registry_Shard_Count);
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

   function IO_Bucket_For (Descriptor : C.int) return IO_Bucket_Index is
     (IO_Bucket_Index (Natural (Descriptor) mod IO_Bucket_Count));

   procedure Register_IO_Wait_Locked
     (Group      : not null Loop_Group_Access;
      Item       : not null Fiber_Access;
      Descriptor : C.int;
      Interest   : Pollers.Interest)
   is
      Bucket : IO_Bucket_Index;
   begin
      if Item.IO_Wait
        or else Item.Group /= Group
        or else Item.State /= Waiting
        or else Descriptor < 0
      then
         Fatal;
      end if;
      Bucket := IO_Bucket_For (Descriptor);
      Item.IO_Wait := True;
      Item.IO_Descriptor := Descriptor;
      Item.IO_Interest := Interest;
      Item.IO_Bucket := Bucket;
      Item.Next_IO := Group.IO_Waiters (Bucket);
      Group.IO_Waiters (Bucket) := Item;
   end Register_IO_Wait_Locked;

   procedure Remove_IO_Wait_Locked
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access)
   is
      Position : Fiber_Access;
      Previous : Fiber_Access;
   begin
      if not Item.IO_Wait then
         return;
      elsif Item.Group /= Group then
         Fatal;
      end if;

      Position := Group.IO_Waiters (Item.IO_Bucket);
      while Position /= null and then Position /= Item loop
         Previous := Position;
         Position := Position.Next_IO;
      end loop;
      if Position = null then
         Fatal;
      elsif Previous = null then
         Group.IO_Waiters (Item.IO_Bucket) := Item.Next_IO;
      else
         Previous.Next_IO := Item.Next_IO;
      end if;

      Item.Next_IO := null;
      Item.IO_Wait := False;
      Item.IO_Descriptor := -1;
   end Remove_IO_Wait_Locked;

   procedure Queue_Pending_File_Locked
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access)
   is
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

   procedure Submit_Pending_Files_Locked
     (Group : not null Loop_Group_Access)
   is
      Item  : Fiber_Access;
      Error : C.int;
   begin
      while Group.Pending_File_Head /= null loop
         Item := Group.Pending_File_Head;
         if not Item.File_Wait or else not Item.File_Pending then
            Fatal;
         end if;

         if Pollers.Submit_File
           (Group.Scheduler_Poller,
            Item.File_Descriptor,
            Item.File_Buffer,
            Item.File_Length,
            Item.File_Offset,
            Item.File_For_Write,
            Fiber_To_Address (Item),
            Error)
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
            Item.File_Wait := False;
            Item.File_Result := 0;
            Item.File_Error := Error;
            Item.File_Descriptor := -1;
            Item.File_Buffer := System.Null_Address;
            Item.File_Length := 0;
            Item.File_Offset := 0;
            Item.File_For_Write := False;
            Enqueue (Group, Item);
         end if;
      end loop;
   end Submit_Pending_Files_Locked;

   function Ensure_Timer_Capacity
     (Group : not null Loop_Group_Access) return Boolean
   is
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
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access) return Boolean
   is
      Position : Natural;
      Parent   : Natural;
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
         Parent := Position / 2;
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

   procedure Remove_Timer_Locked
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access)
   is
      Position : Natural := Item.Timer_Index;
      Parent   : Natural;
      Child    : Natural;
      Last     : Fiber_Access;
   begin
      if Position = 0 then
         return;
      elsif Item.Group /= Group
        or else Position > Group.Timer_Count
        or else Group.Timers (Position) /= Item
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
         Parent := Position / 2;
      end if;
      if Position > 1
        and then Last.Deadline < Group.Timers (Parent).Deadline
      then
         while Position > 1 loop
            Parent := Position / 2;
            exit when Group.Timers (Parent).Deadline <= Last.Deadline;
            Group.Timers (Position) := Group.Timers (Parent);
            Group.Timers (Position).Timer_Index := Position;
            Position := Parent;
         end loop;
         Group.Timers (Position) := Last;
         Last.Timer_Index := Position;
      else
         loop
            exit when Position > Group.Timer_Count / 2;
            Child := Position * 2;
            if Child < Group.Timer_Count
              and then Group.Timers (Child + 1).Deadline <
                Group.Timers (Child).Deadline
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

   procedure Enqueue
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access)
   is
      Priority : constant Ready_Priority := Ready_Priority (Item.Priority);
      Bucket   : Ready_Bucket renames Group.Ready_Buckets (Priority);
   begin
      Item.State := Ready;
      Item.Previous_Ready := Bucket.Tail;
      Item.Next_Ready := null;

      if Bucket.Tail = null then
         Bucket.Head := Item;
      else
         Bucket.Tail.Next_Ready := Item;
      end if;
      Bucket.Tail := Item;

      if Group.Ready_Count = 0 or else Priority > Group.Highest_Ready then
         Group.Highest_Ready := Priority;
      end if;
      Group.Ready_Count := Group.Ready_Count + 1;
   end Enqueue;

   procedure Remove_From_Ready
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access)
   is
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
           and then
             Group.Ready_Buckets (Group.Highest_Ready).Head = null
         loop
            Group.Highest_Ready :=
              Ready_Priority'Pred (Group.Highest_Ready);
         end loop;
         if Group.Ready_Buckets (Group.Highest_Ready).Head = null then
            Fatal;
         end if;
      end if;
   end Remove_From_Ready;

   function Ready_Present
     (Group : not null Loop_Group_Access) return Boolean
   is
     (Group.Ready_Count /= 0);

   function Dequeue
     (Group : not null Loop_Group_Access) return Fiber_Access
   is
      Item : Fiber_Access;
   begin
      if not Ready_Present (Group) then
         return null;
      end if;

      Item := Group.Ready_Buckets (Group.Highest_Ready).Head;
      if Item = null then
         Fatal;
      end if;
      Remove_From_Ready (Group, Item);
      return Item;
   end Dequeue;

   procedure Reap_Locked (Item : not null Fiber_Access) is
      Position_Group  : Fiber_Access;
      Previous_Group  : Fiber_Access;
      Victim           : Fiber_Access := Item;
      Group            : constant Loop_Group_Access := Item.Group;
   begin
      if Scheduling.Plan_Destroy (Phase_Of (Item.State)) = Scheduling.Defer
        or else Item.File_Wait
      then
         Fatal;
      end if;

      if Item.State = Ready then
         Remove_From_Ready (Group, Item);
      end if;
      Remove_Timer_Locked (Group, Item);
      Remove_IO_Wait_Locked (Group, Item);

      Unregister_Locked (Item);

      Position_Group := Group.Fibers;
      while Position_Group /= null and then Position_Group /= Item loop
         Previous_Group := Position_Group;
         Position_Group := Position_Group.Next_Group;
      end loop;
      if Position_Group = null then
         Fatal;
      elsif Previous_Group = null then
         Group.Fibers := Item.Next_Group;
      else
         Previous_Group.Next_Group := Item.Next_Group;
      end if;

      if Group.Current_Fiber = Item then
         Group.Current_Fiber := null;
      end if;
      Group.Member_Count := Group.Member_Count - 1;
      if Item.Reserved_Group /= null then
         Item.Reserved_Group.Reserved_For := System.Null_Address;
         Item.Reserved_Group := null;
      end if;
      Contexts.Destroy (Item.Context);
      Free_Fiber (Victim);
   exception
      when others =>
         Fatal;
   end Reap_Locked;

   procedure Reap_From_Scheduler
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access)
   is
      Shard : constant Registry_Shard_Index := Item.Registry_Shard;
   begin
      Item.Reaping := True;
      Unlock_Group (Group);
      Lock_Registry_Shard (Shard);
      Lock_Topology;
      Lock_Group (Group);
      Reap_Locked (Item);
      Unlock_Topology;
      Unlock_Registry_Shard (Shard);
   end Reap_From_Scheduler;

   procedure Transfer
     (Item   : not null Fiber_Access;
      Source : not null Loop_Group_Access)
   is
      Target : constant Loop_Group_Access := Item.Migration_Target;
      Shard : constant Registry_Shard_Index := Item.Registry_Shard;
      Position : Fiber_Access := Source.Fibers;
      Previous : Fiber_Access;
      Wake_Target : Boolean := True;
   begin
      if Target = null or else Item.Group /= Source then
         Fatal;
      end if;

      Item.State := Migrating;
      while Position /= null and then Position /= Item loop
         Previous := Position;
         Position := Position.Next_Group;
      end loop;
      if Position = null then
         Fatal;
      elsif Previous = null then
         Source.Fibers := Item.Next_Group;
      else
         Previous.Next_Group := Item.Next_Group;
      end if;
      Item.Next_Group := null;
      Source.Current_Fiber := null;
      Source.Member_Count := Source.Member_Count - 1;
      Unlock_Group (Source);

      Lock_Registry_Shard (Shard);
      Lock_Topology;
      Lock_Group (Target);
      if Source.Dedicated then
         Source.Reserved_For := System.Null_Address;
         Item.Reserved_Group := null;
      end if;
      Target.Member_Count := Target.Member_Count + 1;
      Item.Group := Target;
      Item.Migration_Target := null;
      Item.Next_Group := Target.Fibers;
      Target.Fibers := Item;
      if Item.Destroy_Requested then
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
         Fatal;
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
      Result :=
        OSI.clock_gettime
          (OSI.clockid_t (OSC.CLOCK_RT_Ada), Now'Access);
      if Result /= 0 then
         Fatal;
      end if;
      return Time_ABI.To_Duration (Now);
   end Clock;

   function Promote_Expired_Timers
     (Group : not null Loop_Group_Access) return Duration
   is
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
            when Scheduling.Expired =>
               Remove_Timer_Locked (Group, Item);
               Item.Timed_Out := True;
               Remove_IO_Wait_Locked (Group, Item);
               Enqueue (Group, Item);
            when Scheduling.Pending =>
               return Scheduling.Time_Until (Item.Deadline, Now);
         end case;
      end loop;
      return Scheduling.Time_Until (No_Deadline, Now);
   end Promote_Expired_Timers;

   function Initialize (Environment : System.Address) return C.int is
      Result : C.int;
   begin
      if Environment = System.Null_Address or else Initialized then
         return -1;
      end if;

      Result := OSI.pthread_mutex_init (Topology_Lock.Value'Access, null);
      if Result /= 0 then
         return -1;
      end if;
      for Shard in Registry_Shard_Index loop
         Result := OSI.pthread_mutex_init
           (Registry_Shard_Locks (Shard).Value'Access, null);
         if Result /= 0 then
            return -1;
         end if;
      end loop;

      --  Do not allocate a group, poller, context, stack, or pthread here.
      --  Ensure_Group creates the complete event machinery when the first
      --  designated evented task is activated. Until then native programs
      --  stay on the stock GNARL execution path.
      Initialized := True;
      return 0;
   end Initialize;

   function Create
     (T          : System.Address;
      Stack_Size : C.size_t;
      Priority   : C.int;
      Wrapper    : System.Address;
      Group      : C.int) return C.int
   is
      Item   : Fiber_Access;
      Target : Loop_Group_Access;
      Shard  : constant Registry_Shard_Index := Registry_Shard_For (T);
      Group_Id : constant C.int :=
        (if Group < 0 then Default_Group_Id else Group);
   begin
      if not Initialized
        or else T = System.Null_Address
        or else Stack_Size = 0
        or else Wrapper = System.Null_Address
        or else not Scheduling.Shared_Group (Group_Id)
      then
         return -1;
      end if;

      Target := Ensure_Group (Group_Id, Dedicated => False);
      if Target = null then
         return -1;
      end if;

      Item := new Fiber;
      Item.T := T;
      Item.Wrapper := Wrapper;
      Item.Priority := Priority;
      Item.Group := Target;
      Item.Context :=
        Contexts.Create
          (Stack_Size,
           Fiber_Main'Address,
           Fiber_To_Address (Item),
           Target.Scheduler_Context);
      if Item.Context = null then
         Free_Fiber (Item);
         return -1;
      end if;

      Lock_Registry_Shard (Shard);
      if Find (T) /= null then
         Unlock_Registry_Shard (Shard);
         Contexts.Destroy (Item.Context);
         Free_Fiber (Item);
         return -1;
      end if;
      Lock_Group (Target);
      Register_Locked (Item);
      Item.Next_Group := Target.Fibers;
      Target.Fibers := Item;
      Target.Member_Count := Target.Member_Count + 1;
      Enqueue (Target, Item);
      Event_Runtime_Active := 1;
      Unlock_Group (Target);
      Unlock_Registry_Shard (Shard);
      if not Pollers.Wake (Target.Scheduler_Poller) then
         Fatal;
      end if;
      return 0;
   end Create;

   function Is_Event_Task (T : System.Address) return C.int is
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
   end Is_Event_Task;

   function Is_Event_Thread return Boolean is
     (Initialized
      and then Thread_Group /= null
      and then OSI.pthread_self = Thread_Group.Event_Thread);

   function Current_Task return System.Address is
     (if Is_Event_Thread and then Thread_Group.Current_Fiber /= null
      then Thread_Group.Current_Fiber.T
      else System.Null_Address);

   function Task_Thread
     (T : System.Address) return OSI.Thread_Id
   is
      Item   : Fiber_Access;
      Result : OSI.Thread_Id;
      Shard  : constant Registry_Shard_Index := Registry_Shard_For (T);
   begin
      Lock_Registry_Shard (Shard);
      Item := Find (T);
      Result :=
        (if Item = null then OSI.pthread_self else Item.Group.Event_Thread);
      Unlock_Registry_Shard (Shard);
      return Result;
   end Task_Thread;

   function Current_Group return C.int is
     (if Current_Task = System.Null_Address then -1 else Thread_Group.Id);

   function Create_Dedicated_Group return C.int is
      Id      : C.int;
      Group   : Loop_Group_Access;
      Item    : Fiber_Access;
      Current : constant System.Address := Current_Task;
      Shard   : constant Registry_Shard_Index :=
        Registry_Shard_For (Current);
      Available : Boolean;
   begin
      if not Initialized or else Current = System.Null_Address then
         return -1;
      end if;

      for Attempt in 1 .. Natural (Maximum_Group_Id - Dedicated_First_Id + 1)
      loop
         Lock_Registry_Shard (Shard);
         Lock_Topology;
         Item := Find (Current);
         if Item = null or else not Item.Can_Migrate
           or else Item.Reserved_Group /= null
         then
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
               Available := Scheduling.Dedicated_Available
                 (Group.Member_Count,
                  Group.Reserved_For /= System.Null_Address);
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

   function Migrate (Group : C.int) return C.int is
      Item   : Fiber_Access;
      Source : Loop_Group_Access;
      Target : Loop_Group_Access;
      Current : constant System.Address := Current_Task;
      Shard : constant Registry_Shard_Index :=
        Registry_Shard_For (Current);
      Target_Member_Count : Natural := 0;
      Reservation_Matches : Boolean := False;
   begin
      if Current = System.Null_Address
        or else not Scheduling.Valid_Group (Group)
      then
         return -1;
      end if;

      Source := Thread_Group;
      if Source.Id = Group then
         return 0;
      end if;

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
         Reservation_Matches :=
           Target.Reserved_For = Current;
      end if;
      Lock_Group (Source);
      Item := Source.Current_Fiber;
      if Item = null
        or else Item.Group /= Source
        or else Find (Current) /= Item
        or else
          not Scheduling.Migration_Allowed
            (Can_Migrate         => Item.Can_Migrate,
             Target_Dedicated    => Target.Dedicated,
             Target_Member_Count => Target_Member_Count,
             Reservation_Matches =>
               Reservation_Matches
               and then Item.Reserved_Group = Target)
      then
         Unlock_Group (Source);
         Unlock_Topology;
         Unlock_Registry_Shard (Shard);
         return -1;
      end if;

      Item.Migration_Target := Target;
      Item.State := Migrating;
      Unlock_Topology;
      Unlock_Registry_Shard (Shard);
      Contexts.Switch (Item.Context, Source.Scheduler_Context);
      return 0;
   end Migrate;

   function In_Event_Task return C.int is
     (if Current_Task = System.Null_Address then 0 else 1);

   function Wait_IO
     (Descriptor          : C.int;
      For_Write           : C.int;
      Timeout_Nanoseconds : C.long_long) return C.int
   is
      Group     : constant Loop_Group_Access := Thread_Group;
      Item      : Fiber_Access;
      Condition : constant Pollers.Interest :=
        (if For_Write = 0 then Pollers.Readable else Pollers.Writable);
      Whole     : C.long_long;
      Remainder : C.long_long;
      Timeout   : Duration;
   begin
      --  Only this group's event thread writes Current_Fiber while a fiber is
      --  running; the unlocked read validates same-thread call context. The
      --  state transition uses the locked read below.
      if not Is_Event_Thread
        or else Group.Current_Fiber = null
        or else Descriptor < 0
      then
         return -1;
      end if;

      if Timeout_Nanoseconds < 0 then
         Timeout := No_Deadline;
      else
         Whole := Timeout_Nanoseconds / 1_000_000_000;
         Remainder := Timeout_Nanoseconds mod 1_000_000_000;
         Timeout := Duration (Whole)
           + Duration (Remainder) / 1_000_000_000;
      end if;

      Lock_Group (Group);
      Item := Group.Current_Fiber;
      Item.Deadline :=
        (if Timeout < 0.0 then No_Deadline else Clock + Timeout);
      Item.Timed_Out := False;
      Item.State := Waiting;
      if not Register_Timer_Locked (Group, Item) then
         Item.State := Running;
         Item.Deadline := No_Deadline;
         Unlock_Group (Group);
         return -1;
      elsif not Pollers.Watch
        (Group.Scheduler_Poller, Descriptor, Condition)
      then
         Remove_Timer_Locked (Group, Item);
         Item.State := Running;
         Unlock_Group (Group);
         return -1;
      end if;
      Register_IO_Wait_Locked (Group, Item, Descriptor, Condition);
      Contexts.Switch (Item.Context, Group.Scheduler_Context);

      return (if Item.Timed_Out then 1 else 0);
   end Wait_IO;

   function File_IO
     (Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : C.int;
      Transferred : access C.long_long;
      Error_Code  : access C.int) return C.int
   is
      Group : constant Loop_Group_Access := Thread_Group;
      Item  : Fiber_Access;
      Error : C.int := 0;
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
      then
         return -1;
      end if;

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
      if not Pollers.Submit_File
        (Group.Scheduler_Poller,
         Descriptor,
         Buffer,
         Length,
         Offset,
         For_Write /= 0,
         Fiber_To_Address (Item),
         Error)
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
            Unlock_Group (Group);
            Error_Code.all := Error;
            Transferred.all := 0;
            return -1;
         end if;
      end if;

      Contexts.Switch (Item.Context, Group.Scheduler_Context);
      Transferred.all := Item.File_Result;
      Error_Code.all := Item.File_Error;
      return 0;
   end File_IO;

   function Set_Priority
     (T : System.Address; Priority : C.int) return C.int
   is
      Item : Fiber_Access;
      Shard : constant Registry_Shard_Index := Registry_Shard_For (T);
   begin
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
         Enqueue (Item.Group, Item);
      else
         Item.Priority := Priority;
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

   function Sleep
     (Task_Lock : System.Address;
      Deadline  : Duration;
      Timed_Out : access C.int) return C.int
   is
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
      Item       : Fiber_Access;
      Group      : Loop_Group_Access;
      Made_Ready : Boolean := False;
      Shard      : constant Registry_Shard_Index := Registry_Shard_For (T);
   begin
      Lock_Registry_Shard (Shard);
      Item := Find (T);
      if Item = null then
         Unlock_Registry_Shard (Shard);
         return -1;
      end if;

      Group := Item.Group;
      Lock_Group (Group);
      if Item.State = Waiting and then not Item.File_Wait then
         Remove_Timer_Locked (Group, Item);
         Item.Timed_Out := False;
         Remove_IO_Wait_Locked (Group, Item);
         Enqueue (Group, Item);
         Made_Ready := True;
      end if;
      Unlock_Group (Group);
      Unlock_Registry_Shard (Shard);

      if Made_Ready and then not Pollers.Wake (Group.Scheduler_Poller) then
         Fatal;
      end if;
      return 0;
   end Wake;

   function Destroy (T : System.Address) return C.int is
      Item : Fiber_Access;
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
         when Scheduling.Defer =>
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
      Item : constant Fiber_Access := Address_To_Fiber (Argument);
      Group : Loop_Group_Access;
      type Wrapper_Access is access procedure (T : System.Address);
      pragma Convention (C, Wrapper_Access);
      function To_Wrapper is new Ada.Unchecked_Conversion
        (System.Address, Wrapper_Access);
   begin
      To_Wrapper (Item.Wrapper).all (Item.T);

      Group := Item.Group;
      Lock_Group (Group);
      Item.State := Finished;
      Item.Deadline := No_Deadline;
      Contexts.Switch (Item.Context, Group.Scheduler_Context);
      Fatal;
   end Fiber_Main;

   procedure Handle_Poll_Event
     (Group : not null Loop_Group_Access;
      Event : Pollers.Poll_Event)
   is
      Bucket  : IO_Bucket_Index;
      Item    : Fiber_Access;
      Next    : Fiber_Access;
      Previous : Fiber_Access;
      Matches : Boolean;
   begin
      if Event.Kind = Pollers.File_Event then
         if Event.Token = System.Null_Address then
            Fatal;
         end if;
         Item := Address_To_Fiber (Event.Token);
         if Item.Group /= Group
           or else Item.State /= Waiting
           or else not Item.File_Wait
           or else Item.File_Pending
         then
            Fatal;
         end if;
         Item.File_Result := Event.Result;
         Item.File_Error := Event.Error_Code;
         Item.File_Wait := False;
         Item.File_Descriptor := -1;
         Item.File_Buffer := System.Null_Address;
         Item.File_Length := 0;
         Item.File_Offset := 0;
         Item.File_For_Write := False;
         Enqueue (Group, Item);
         Submit_Pending_Files_Locked (Group);
         return;
      end if;

      if Event.Kind not in
        Pollers.Readable_Event |
        Pollers.Writable_Event |
        Pollers.Read_Write_Event
      then
         return;
      end if;

      if Event.Descriptor < 0 then
         Fatal;
      end if;
      Bucket := IO_Bucket_For (Event.Descriptor);
      Item := Group.IO_Waiters (Bucket);
      while Item /= null loop
         Next := Item.Next_IO;
         Matches :=
           Item.State = Waiting
           and then Item.IO_Wait
           and then Item.IO_Descriptor = Event.Descriptor
           and then
             ((Event.Kind in Pollers.Readable_Event | Pollers.Read_Write_Event
               and then Item.IO_Interest = Pollers.Readable)
              or else
                (Event.Kind in
                   Pollers.Writable_Event | Pollers.Read_Write_Event
                 and then Item.IO_Interest = Pollers.Writable));
         if Matches then
            if Previous = null then
               Group.IO_Waiters (Bucket) := Next;
            else
               Previous.Next_IO := Next;
            end if;
            Item.Next_IO := null;
            Remove_Timer_Locked (Group, Item);
            Item.Timed_Out := False;
            Item.IO_Wait := False;
            Item.IO_Descriptor := -1;
            Enqueue (Group, Item);
         else
            Previous := Item;
         end if;
         Item := Next;
      end loop;
   end Handle_Poll_Event;

   procedure Poll_Ready_Events (Group : not null Loop_Group_Access) is
      Waited : Boolean;
      Events : Pollers.Poll_Event_Array (1 .. Poll_Event_Budget);
      Count  : Natural;
   begin
      Unlock_Group (Group);
      Waited := Pollers.Wait_Batch
        (Group.Scheduler_Poller, 0.0, Events, Count);
      Lock_Group (Group);
      if not Waited then
         Fatal;
      end if;
      for Index in 1 .. Count loop
         Handle_Poll_Event (Group, Events (Index));
      end loop;
   end Poll_Ready_Events;

   procedure Scheduler_Main (Argument : System.Address) is
      Group : constant Loop_Group_Access := Address_To_Group (Argument);
      Dispatches_Until_Timer_Check : Natural := 0;
      Timeout : Duration;
      Next    : Fiber_Access;
      Waited  : Boolean;
      Events  : Pollers.Poll_Event_Array (1 .. Poll_Event_Budget);
      Count   : Natural;
   begin
      loop
         Timeout := No_Deadline;
         if Scheduling.Maintenance_Due
           (Ready_Present (Group), Dispatches_Until_Timer_Check)
         then
            Timeout := Promote_Expired_Timers (Group);
            Dispatches_Until_Timer_Check := Timer_Check_Interval;
            if Ready_Present (Group) then
               Poll_Ready_Events (Group);
            end if;
         end if;

         Submit_Pending_Files_Locked (Group);
         if Group.Pending_File_Head /= null
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
            Next.State := Running;
            Group.Current_Fiber := Next;
            if Dispatches_Until_Timer_Check = 0 then
               Fatal;
            end if;
            Dispatches_Until_Timer_Check :=
              Scheduling.After_Dispatch
                (Positive (Dispatches_Until_Timer_Check));
            Unlock_Group (Group);
            Contexts.Switch (Group.Scheduler_Context, Next.Context);

            if Next.Migration_Target /= null then
               Transfer (Next, Group);
            elsif Scheduling.Should_Reap_After_Switch
              (Phase_Of (Next.State), Next.Destroy_Requested)
            then
               Reap_From_Scheduler (Group, Next);
            end if;
         else
            Group.Current_Fiber := null;
            Unlock_Group (Group);
            Waited := Pollers.Wait_Batch
              (Group.Scheduler_Poller, Timeout, Events, Count);
            Lock_Group (Group);
            if not Waited then
               Fatal;
            end if;
            for Index in 1 .. Count loop
               Handle_Poll_Event (Group, Events (Index));
            end loop;
         end if;
      end loop;
   end Scheduler_Main;

end System.Gnatevl.Scheduler;
