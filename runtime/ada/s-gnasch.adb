with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.C_Time;
with System.Gnatevl.Contexts;
with System.Gnatevl.Poller;
with System.Gnatevl.Scheduling_Policy;
with System.OS_Constants;
with System.Storage_Elements;

package body System.Gnatevl.Scheduler is
   package C renames Interfaces.C;
   package Contexts renames System.Gnatevl.Contexts;
   package Pollers renames System.Gnatevl.Poller;
   package Scheduling renames System.Gnatevl.Scheduling_Policy;
   package OSC renames System.OS_Constants;
   package OSI renames System.OS_Interface;
   package SSE renames System.Storage_Elements;

   use type C.int;
   use type C.long_long;
   use type C.size_t;
   use type C.unsigned_long;
   use type Contexts.Context_Access;
   use type OSI.pthread_t;
   use type Pollers.Event_Kind;
   use type Pollers.Interest;
   use type Scheduling.Destruction_Plan;
   use type SSE.Integer_Address;

   Scheduler_Stack_Size : constant C.size_t := 256 * 1_024;
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
   type IO_Bucket_Array is array (IO_Bucket_Index) of Fiber_Access;

   type Fiber is record
      T          : System.Address := System.Null_Address;
      Context    : Contexts.Context_Access;
      Wrapper    : System.Address := System.Null_Address;
      Priority   : C.int := 0;
      Sequence   : C.unsigned_long := 0;
      Deadline   : Duration := No_Deadline;
      Timed_Out  : Boolean := False;
      State      : Fiber_State := Waiting;
      IO_Wait    : Boolean := False;
      IO_Descriptor : C.int := -1;
      IO_Interest : Pollers.Interest := Pollers.Readable;
      IO_Bucket  : IO_Bucket_Index := 0;
      Destroy_Requested : Boolean := False;
      Reaping     : Boolean := False;
      Can_Migrate : Boolean := True;
      Group      : Loop_Group_Access;
      Migration_Target : Loop_Group_Access;
      Reserved_Group : Loop_Group_Access;
      Next_Ready : Fiber_Access;
      Next_Group : Fiber_Access;
      Next_IO    : Fiber_Access;
      Next_Registry : Fiber_Access;
      Registry_Bucket : Registry_Bucket_Index := 0;
   end record;

   type Loop_Group is limited record
      Id          : C.int := -1;
      Dedicated   : Boolean := False;
      Lock        : aliased OSI.pthread_mutex_t;
      Started     : Boolean := False;
      Start_Failed : Boolean := False;
      Event_Thread : aliased OSI.pthread_t;
      Scheduler_Context : Contexts.Context_Access;
      Scheduler_Poller  : Pollers.Poller;
      Current_Fiber     : Fiber_Access;
      Ready_Head        : Fiber_Access;
      Next_Sequence     : C.unsigned_long := 0;
      Fibers            : Fiber_Access;
      IO_Waiters        : IO_Bucket_Array := (others => null);
      Member_Count      : Natural := 0;
      Reserved_For      : System.Address := System.Null_Address;
   end record;

   type Group_Array is array (Group_Index) of Loop_Group_Access;
   type Registry_Bucket_Array is
     array (Registry_Bucket_Index) of Fiber_Access;

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

   --  Registry_Lock protects Groups, Fiber_Registry, group membership counts
   --  and reservations, and each Fiber.Group ownership pointer. A group lock
   --  protects that group's fiber list, ready queue, timers, I/O state, and
   --  current fiber. Code needing both always takes registry then group; the
   --  migration handoff releases its source before taking its target.
   Registry_Lock  : aliased OSI.pthread_mutex_t;
   Initialized    : Boolean := False;
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

   procedure Lock_Registry;
   procedure Unlock_Registry;
   procedure Lock_Group (Group : not null Loop_Group_Access);
   procedure Unlock_Group (Group : not null Loop_Group_Access);
   procedure Fatal;
   pragma No_Return (Fatal);
   function Ensure_Group
     (Id : C.int; Dedicated : Boolean) return Loop_Group_Access;
   --  Registry operations require Registry_Lock after bootstrap publishes
   --  Initialized; Initialize registers the environment task single-threaded.
   function Registry_Bucket_For
     (T : System.Address) return Registry_Bucket_Index;
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
   procedure Enqueue
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access);
   procedure Remove_From_Ready
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access);
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

   procedure Lock_Registry is
      Result : constant C.int :=
        OSI.pthread_mutex_lock (Registry_Lock'Access);
   begin
      if Result /= 0 then
         Fatal;
      end if;
   end Lock_Registry;

   procedure Unlock_Registry is
      Result : constant C.int :=
        OSI.pthread_mutex_unlock (Registry_Lock'Access);
   begin
      if Result /= 0 then
         Fatal;
      end if;
   end Unlock_Registry;

   procedure Lock_Group (Group : not null Loop_Group_Access) is
      Result : constant C.int := OSI.pthread_mutex_lock (Group.Lock'Access);
   begin
      if Result /= 0 then
         Fatal;
      end if;
   end Lock_Group;

   procedure Unlock_Group (Group : not null Loop_Group_Access) is
      Result : constant C.int := OSI.pthread_mutex_unlock (Group.Lock'Access);
   begin
      if Result /= 0 then
         Fatal;
      end if;
   end Unlock_Group;

   function Group_Thread (Argument : System.Address) return System.Address is
      Group : constant Loop_Group_Access := Address_To_Group (Argument);
   begin
      Thread_Group := Group;
      Group.Scheduler_Context := Contexts.Capture;

      Lock_Registry;
      Group.Started := Group.Scheduler_Context /= null;
      Group.Start_Failed := not Group.Started;
      if Group.Start_Failed then
         Unlock_Registry;
         return System.Null_Address;
      end if;

      Unlock_Registry;
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

      Lock_Registry;
      Group := Groups (Group_Index (Id));
      if Group /= null then
         if Group.Dedicated /= Dedicated
           and then Scheduling.Dedicated_Group (Id)
         then
            Unlock_Registry;
            return null;
         end if;
         Unlock_Registry;
      else
         Group := new Loop_Group;
         Group.Id := Id;
         Group.Dedicated := Dedicated;
         Result := OSI.pthread_mutex_init (Group.Lock'Access, null);
         if Result /= 0 then
            Free_Group (Group);
            Unlock_Registry;
            return null;
         end if;
         if not Pollers.Initialize (Group.Scheduler_Poller) then
            Free_Group (Group);
            Unlock_Registry;
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
         --  cannot publish Started until it acquires Registry_Lock, which is
         --  still held here, so readers cannot observe an uninitialized id.
         if Result /= 0 then
            Groups (Group_Index (Id)) := null;
            Pollers.Finalize (Group.Scheduler_Poller);
            Free_Group (Group);
            Unlock_Registry;
            return null;
         end if;
         Unlock_Registry;
      end if;

      --  This is a bounded, first-use-only startup wait. If called by an
      --  evented task, its source loop remains occupied until the new group
      --  thread publishes Started or Start_Failed under Registry_Lock.
      loop
         Lock_Registry;
         Ready := Group.Started;
         Failed := Group.Start_Failed;
         Unlock_Registry;
         exit when Ready or else Failed;
         Result := Sched_Yield;
         if Result /= 0 then
            return null;
         end if;
      end loop;

      return (if Failed then null else Group);
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
      Bucket : constant IO_Bucket_Index := IO_Bucket_For (Descriptor);
   begin
      if Item.IO_Wait
        or else Item.Group /= Group
        or else Item.State /= Waiting
        or else Descriptor < 0
      then
         Fatal;
      end if;
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

   procedure Enqueue
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access)
   is
      Position : Fiber_Access := Group.Ready_Head;
      Previous : Fiber_Access;
   begin
      Item.State := Ready;
      Group.Next_Sequence := Group.Next_Sequence + 1;
      Item.Sequence := Group.Next_Sequence;
      Item.Next_Ready := null;

      while Position /= null
        and then Scheduling.Before
          ((Priority => Position.Priority, Sequence => Position.Sequence),
           (Priority => Item.Priority, Sequence => Item.Sequence))
      loop
         Previous := Position;
         Position := Position.Next_Ready;
      end loop;

      Item.Next_Ready := Position;
      if Previous = null then
         Group.Ready_Head := Item;
      else
         Previous.Next_Ready := Item;
      end if;
   end Enqueue;

   procedure Remove_From_Ready
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access)
   is
      Position : Fiber_Access := Group.Ready_Head;
      Previous : Fiber_Access;
   begin
      while Position /= null loop
         if Position = Item then
            if Previous = null then
               Group.Ready_Head := Position.Next_Ready;
            else
               Previous.Next_Ready := Position.Next_Ready;
            end if;
            Position.Next_Ready := null;
            return;
         end if;
         Previous := Position;
         Position := Position.Next_Ready;
      end loop;
   end Remove_From_Ready;

   procedure Reap_Locked (Item : not null Fiber_Access) is
      Position_Group  : Fiber_Access;
      Previous_Group  : Fiber_Access;
      Victim           : Fiber_Access := Item;
      Group            : constant Loop_Group_Access := Item.Group;
   begin
      if Scheduling.Plan_Destroy (Phase_Of (Item.State)) = Scheduling.Defer
      then
         Fatal;
      end if;

      if Item.State = Ready then
         Remove_From_Ready (Group, Item);
      end if;
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
   begin
      Item.Reaping := True;
      Unlock_Group (Group);
      Lock_Registry;
      Lock_Group (Group);
      Reap_Locked (Item);
      Unlock_Registry;
   end Reap_From_Scheduler;

   procedure Transfer
     (Item   : not null Fiber_Access;
      Source : not null Loop_Group_Access)
   is
      Target : constant Loop_Group_Access := Item.Migration_Target;
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
      Unlock_Group (Source);

      Lock_Registry;
      Lock_Group (Target);
      Source.Member_Count := Source.Member_Count - 1;
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
      Unlock_Registry;

      if Wake_Target and then not Pollers.Wake (Target.Scheduler_Poller) then
         Fatal;
      end if;
      Lock_Group (Source);
   exception
      when others =>
         Fatal;
   end Transfer;

   function Clock return Duration is
      Now    : aliased System.C_Time.timespec;
      Result : C.int;
   begin
      Result :=
        OSI.clock_gettime
          (OSI.clockid_t (OSC.CLOCK_RT_Ada), Now'Access);
      if Result /= 0 then
         Fatal;
      end if;
      return System.C_Time.To_Duration (Now);
   end Clock;

   function Promote_Expired_Timers
     (Group : not null Loop_Group_Access) return Duration
   is
      Now     : constant Duration := Clock;
      Nearest : Duration := No_Deadline;
      Item    : Fiber_Access := Group.Fibers;
   begin
      while Item /= null loop
         if Item.State = Waiting then
            case Scheduling.Classify_Deadline (Item.Deadline, Now) is
               when Scheduling.No_Deadline_Set =>
                  null;
               when Scheduling.Expired =>
                  Item.Timed_Out := True;
                  Remove_IO_Wait_Locked (Group, Item);
                  Enqueue (Group, Item);
               when Scheduling.Pending =>
                  Nearest :=
                    Scheduling.Earlier_Deadline (Nearest, Item.Deadline);
            end case;
         end if;
         Item := Item.Next_Group;
      end loop;

      return Scheduling.Time_Until (Nearest, Now);
   end Promote_Expired_Timers;

   function Initialize (Environment : System.Address) return C.int is
      Environment_Fiber : Fiber_Access;
      Default_Group     : Loop_Group_Access;
      Result            : C.int;
   begin
      if Environment = System.Null_Address or else Initialized then
         return -1;
      end if;

      Result := OSI.pthread_mutex_init (Registry_Lock'Access, null);
      if Result /= 0 then
         return -1;
      end if;

      Default_Group := new Loop_Group;
      Default_Group.Id := Default_Group_Id;
      Result := OSI.pthread_mutex_init (Default_Group.Lock'Access, null);
      if Result /= 0 then
         Free_Group (Default_Group);
         return -1;
      end if;
      if not Pollers.Initialize (Default_Group.Scheduler_Poller) then
         Free_Group (Default_Group);
         return -1;
      end if;

      Environment_Fiber := new Fiber;
      Environment_Fiber.Context := Contexts.Capture;
      Environment_Fiber.Group := Default_Group;
      Environment_Fiber.Can_Migrate := False;
      Default_Group.Scheduler_Context :=
        Contexts.Create
          (Scheduler_Stack_Size,
           Scheduler_Main'Address,
           Group_To_Address (Default_Group),
           Environment_Fiber.Context);
      if Default_Group.Scheduler_Context = null then
         Contexts.Destroy (Environment_Fiber.Context);
         Free_Fiber (Environment_Fiber);
         Pollers.Finalize (Default_Group.Scheduler_Poller);
         Free_Group (Default_Group);
         return -1;
      end if;

      Environment_Fiber.T := Environment;
      Environment_Fiber.State := Running;
      Environment_Fiber.Next_Group := null;
      Register_Locked (Environment_Fiber);
      Default_Group.Fibers := Environment_Fiber;
      Default_Group.Current_Fiber := Environment_Fiber;
      Default_Group.Member_Count := 1;
      Default_Group.Event_Thread := OSI.pthread_self;
      Default_Group.Started := True;
      Groups (Group_Index (Default_Group_Id)) := Default_Group;
      Thread_Group := Default_Group;
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

      Lock_Registry;
      if Find (T) /= null then
         Unlock_Registry;
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
      Unlock_Group (Target);
      Unlock_Registry;
      if not Pollers.Wake (Target.Scheduler_Poller) then
         Fatal;
      end if;
      return 0;
   end Create;

   function Is_Event_Task (T : System.Address) return C.int is
      Result : C.int;
   begin
      if not Initialized or else T = System.Null_Address then
         return 0;
      end if;
      Lock_Registry;
      Result := (if Find (T) = null then 0 else 1);
      Unlock_Registry;
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
   begin
      Lock_Registry;
      Item := Find (T);
      Result :=
        (if Item = null then OSI.pthread_self else Item.Group.Event_Thread);
      Unlock_Registry;
      return Result;
   end Task_Thread;

   function Current_Group return C.int is
     (if Current_Task = System.Null_Address then -1 else Thread_Group.Id);

   function Create_Dedicated_Group return C.int is
      Id      : C.int;
      Group   : Loop_Group_Access;
      Item    : Fiber_Access;
      Current : constant System.Address := Current_Task;
   begin
      if not Initialized or else Current = System.Null_Address then
         return -1;
      end if;

      for Attempt in 1 .. Natural (Maximum_Group_Id - Dedicated_First_Id + 1)
      loop
         Lock_Registry;
         Item := Find (Current);
         if Item = null or else not Item.Can_Migrate
           or else Item.Reserved_Group /= null
         then
            Unlock_Registry;
            return -1;
         end if;

         Id := Dedicated_First_Id;
         Group := null;
         while Id <= Maximum_Group_Id loop
            Group := Groups (Group_Index (Id));
            exit when Group = null
              or else
                (Group.Dedicated
                 and then
                   Scheduling.Dedicated_Available
                     (Group.Member_Count,
                      Group.Reserved_For /= System.Null_Address));
            Id := Id + 1;
         end loop;
         if Id > Maximum_Group_Id then
            Unlock_Registry;
            return -1;
         elsif Group /= null then
            Group.Reserved_For := Current;
            Item.Reserved_Group := Group;
            Unlock_Registry;
            return Id;
         end if;
         Unlock_Registry;

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
      Lock_Registry;
      Item := Groups (Group_Index (Group));
      Result := (if Item /= null and then Item.Dedicated then 1 else 0);
      Unlock_Registry;
      return Result;
   end Is_Dedicated_Group;

   function Migrate (Group : C.int) return C.int is
      Item   : Fiber_Access;
      Source : Loop_Group_Access;
      Target : Loop_Group_Access;
   begin
      if Current_Task = System.Null_Address
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
         Lock_Registry;
         Target := Groups (Group_Index (Group));
         Unlock_Registry;
      end if;
      if Target = null then
         return -1;
      end if;

      Lock_Registry;
      Lock_Group (Source);
      Item := Source.Current_Fiber;
      if Item = null
        or else Item.Group /= Source
        or else
          not Scheduling.Migration_Allowed
            (Can_Migrate         => Item.Can_Migrate,
             Target_Dedicated    => Target.Dedicated,
             Target_Member_Count => Target.Member_Count,
             Reservation_Matches =>
               Target.Reserved_For = Item.T
               and then Item.Reserved_Group = Target)
      then
         Unlock_Group (Source);
         Unlock_Registry;
         return -1;
      end if;

      Item.Migration_Target := Target;
      Item.State := Migrating;
      Unlock_Registry;
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
      if not Pollers.Watch (Group.Scheduler_Poller, Descriptor, Condition) then
         Unlock_Group (Group);
         return -1;
      end if;

      Item := Group.Current_Fiber;
      Item.Deadline :=
        (if Timeout < 0.0 then No_Deadline else Clock + Timeout);
      Item.Timed_Out := False;
      Item.State := Waiting;
      Register_IO_Wait_Locked (Group, Item, Descriptor, Condition);
      Contexts.Switch (Item.Context, Group.Scheduler_Context);

      return (if Item.Timed_Out then 1 else 0);
   end Wait_IO;

   function Set_Priority
     (T : System.Address; Priority : C.int) return C.int
   is
      Item : Fiber_Access;
   begin
      Lock_Registry;
      Item := Find (T);
      if Item = null then
         Unlock_Registry;
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
      Unlock_Registry;
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

      if Task_Lock /= System.Null_Address then
         Result := Mutex_Unlock (Task_Lock);
         if Result /= 0 then
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
   begin
      Lock_Registry;
      Item := Find (T);
      if Item = null then
         Unlock_Registry;
         return -1;
      end if;

      Group := Item.Group;
      Lock_Group (Group);
      if Item.State = Waiting then
         Item.Deadline := No_Deadline;
         Item.Timed_Out := False;
         Remove_IO_Wait_Locked (Group, Item);
         Enqueue (Group, Item);
         Made_Ready := True;
      end if;
      Unlock_Group (Group);
      Unlock_Registry;

      if Made_Ready and then not Pollers.Wake (Group.Scheduler_Poller) then
         Fatal;
      end if;
      return 0;
   end Wake;

   function Destroy (T : System.Address) return C.int is
      Item : Fiber_Access;
   begin
      if not Initialized or else T = System.Null_Address then
         return -1;
      end if;

      Lock_Registry;
      Item := Find (T);
      if Item = null then
         Unlock_Registry;
         return -1;
      end if;
      Lock_Group (Item.Group);

      if Item.Reaping then
         Unlock_Group (Item.Group);
         Unlock_Registry;
         return 0;
      end if;

      Item.T := System.Null_Address;
      Item.Destroy_Requested := True;

      case Scheduling.Plan_Destroy (Phase_Of (Item.State)) is
         when Scheduling.Defer =>
            Unlock_Group (Item.Group);
            Unlock_Registry;
            return 0;
         when Scheduling.Reap_Now =>
            declare
               Group : constant Loop_Group_Access := Item.Group;
            begin
               Reap_Locked (Item);
               Unlock_Group (Group);
            end;
            Unlock_Registry;
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
            Item.Deadline := No_Deadline;
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
           (Group.Ready_Head /= null, Dispatches_Until_Timer_Check)
         then
            Timeout := Promote_Expired_Timers (Group);
            Dispatches_Until_Timer_Check := Timer_Check_Interval;
            if Group.Ready_Head /= null then
               Poll_Ready_Events (Group);
            end if;
         end if;

         if Group.Ready_Head /= null then
            Next := Group.Ready_Head;
            Group.Ready_Head := Next.Next_Ready;
            Next.Next_Ready := null;
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
