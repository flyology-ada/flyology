with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.C_Time;
with System.Gnatevl.Contexts;
with System.Gnatevl.Poller;
with System.Gnatevl.Scheduling_Policy;
with System.OS_Constants;

package body System.Gnatevl.Scheduler is
   package C renames Interfaces.C;
   package Contexts renames System.Gnatevl.Contexts;
   package Pollers renames System.Gnatevl.Poller;
   package Scheduling renames System.Gnatevl.Scheduling_Policy;
   package OSC renames System.OS_Constants;
   package OSI renames System.OS_Interface;

   use type C.int;
   use type C.long_long;
   use type C.size_t;
   use type C.unsigned_long;
   use type Contexts.Context_Access;
   use type OSI.pthread_t;
   use type Pollers.Event_Kind;
   use type Pollers.Interest;
   use type Scheduling.Destruction_Plan;

   Scheduler_Stack_Size : constant C.size_t := 256 * 1_024;
   Timer_Check_Interval : constant := 64;
   Poll_Event_Budget    : constant := 64;
   No_Deadline          : constant Duration := Scheduling.No_Deadline;

   Default_Group_Id    : constant C.int := 0;
   Dedicated_First_Id  : constant C.int := 128;
   Maximum_Group_Id    : constant C.int := 255;
   subtype Group_Index is Natural range 0 .. Natural (Maximum_Group_Id);

   type Fiber_State is (Running, Ready, Waiting, Finished);

   function Phase_Of
     (State : Fiber_State) return Scheduling.Fiber_Phase
   is
     (case State is
         when Running  => Scheduling.Running,
         when Ready    => Scheduling.Ready,
         when Waiting  => Scheduling.Waiting,
         when Finished => Scheduling.Finished);

   type Fiber;
   type Fiber_Access is access all Fiber;
   type Loop_Group;
   type Loop_Group_Access is access all Loop_Group;

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
      Destroy_Requested : Boolean := False;
      Can_Migrate : Boolean := True;
      Group      : Loop_Group_Access;
      Migration_Target : Loop_Group_Access;
      Reserved_Group : Loop_Group_Access;
      Next_Ready : Fiber_Access;
      Next_All   : Fiber_Access;
   end record;

   type Loop_Group is limited record
      Id          : C.int := -1;
      Dedicated   : Boolean := False;
      Started     : Boolean := False;
      Start_Failed : Boolean := False;
      Event_Thread : aliased OSI.pthread_t;
      Scheduler_Context : Contexts.Context_Access;
      Scheduler_Poller  : Pollers.Poller;
      Current_Fiber     : Fiber_Access;
      Ready_Head        : Fiber_Access;
      Next_Sequence     : C.unsigned_long := 0;
      Member_Count      : Natural := 0;
      Reserved_For      : System.Address := System.Null_Address;
   end record;

   type Group_Array is array (Group_Index) of Loop_Group_Access;

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

   Scheduler_Lock : aliased OSI.pthread_mutex_t;
   Initialized    : Boolean := False;
   Groups         : Group_Array := (others => null);
   All_Fibers     : Fiber_Access;
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

   procedure Lock;
   procedure Unlock;
   function Ensure_Group
     (Id : C.int; Dedicated : Boolean) return Loop_Group_Access;
   function Find (T : System.Address) return Fiber_Access;
   procedure Enqueue
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access);
   procedure Remove_From_Ready
     (Group : not null Loop_Group_Access;
      Item  : not null Fiber_Access);
   procedure Reap (Item : not null Fiber_Access);
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

   procedure Lock is
      Result : constant C.int :=
        OSI.pthread_mutex_lock (Scheduler_Lock'Access);
   begin
      if Result /= 0 then
         raise Program_Error with "GNATEVL scheduler lock failed";
      end if;
   end Lock;

   procedure Unlock is
      Result : constant C.int :=
        OSI.pthread_mutex_unlock (Scheduler_Lock'Access);
   begin
      if Result /= 0 then
         raise Program_Error with "GNATEVL scheduler unlock failed";
      end if;
   end Unlock;

   function Group_Thread (Argument : System.Address) return System.Address is
      Group : constant Loop_Group_Access := Address_To_Group (Argument);
   begin
      Thread_Group := Group;
      Group.Event_Thread := OSI.pthread_self;
      Group.Scheduler_Context := Contexts.Capture;

      Lock;
      Group.Started := Group.Scheduler_Context /= null;
      Group.Start_Failed := not Group.Started;
      if Group.Start_Failed then
         Unlock;
         return System.Null_Address;
      end if;

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
      if not Initialized
        or else Id < Default_Group_Id
        or else Id > Maximum_Group_Id
      then
         return null;
      end if;

      Lock;
      Group := Groups (Group_Index (Id));
      if Group /= null then
         if Group.Dedicated /= Dedicated and then Id >= Dedicated_First_Id then
            Unlock;
            return null;
         end if;
         Unlock;
      else
         Group := new Loop_Group;
         Group.Id := Id;
         Group.Dedicated := Dedicated;
         if not Pollers.Initialize (Group.Scheduler_Poller) then
            Free_Group (Group);
            Unlock;
            return null;
         end if;

         Groups (Group_Index (Id)) := Group;
         Result :=
           OSI.pthread_create
             (Group.Event_Thread'Access,
              null,
              Group_Thread'Access,
              Group_To_Address (Group));
         if Result /= 0 then
            Groups (Group_Index (Id)) := null;
            Pollers.Finalize (Group.Scheduler_Poller);
            Free_Group (Group);
            Unlock;
            return null;
         end if;
         Unlock;
      end if;

      loop
         Lock;
         Ready := Group.Started;
         Failed := Group.Start_Failed;
         Unlock;
         exit when Ready or else Failed;
         Result := Sched_Yield;
         if Result /= 0 then
            return null;
         end if;
      end loop;

      return (if Failed then null else Group);
   end Ensure_Group;

   function Find (T : System.Address) return Fiber_Access is
      Item : Fiber_Access := All_Fibers;
   begin
      while Item /= null and then Item.T /= T loop
         Item := Item.Next_All;
      end loop;
      return Item;
   end Find;

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

   procedure Reap (Item : not null Fiber_Access) is
      Position : Fiber_Access := All_Fibers;
      Previous : Fiber_Access;
      Victim   : Fiber_Access := Item;
      Group    : constant Loop_Group_Access := Item.Group;
   begin
      if Scheduling.Plan_Destroy (Phase_Of (Item.State)) = Scheduling.Defer
      then
         raise Program_Error with "attempt to reap a running GNATEVL task";
      end if;

      if Item.State = Ready then
         Remove_From_Ready (Group, Item);
      end if;

      while Position /= null and then Position /= Item loop
         Previous := Position;
         Position := Position.Next_All;
      end loop;
      if Position = null then
         raise Program_Error with "GNATEVL task missing from scheduler";
      elsif Previous = null then
         All_Fibers := Item.Next_All;
      else
         Previous.Next_All := Item.Next_All;
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
   end Reap;

   procedure Transfer
     (Item   : not null Fiber_Access;
      Source : not null Loop_Group_Access)
   is
      Target : constant Loop_Group_Access := Item.Migration_Target;
   begin
      if Target = null or else Item.Group /= Source then
         raise Program_Error with "GNATEVL migration invariant failed";
      end if;

      Source.Member_Count := Source.Member_Count - 1;
      if Source.Dedicated then
         Source.Reserved_For := System.Null_Address;
         Item.Reserved_Group := null;
      end if;
      Target.Member_Count := Target.Member_Count + 1;
      Item.Group := Target;
      Item.Migration_Target := null;
      Enqueue (Target, Item);
      Source.Current_Fiber := null;

      if not Pollers.Wake (Target.Scheduler_Poller) then
         raise Program_Error with "GNATEVL migration wake failed";
      end if;
   end Transfer;

   function Clock return Duration is
      Now    : aliased System.C_Time.timespec;
      Result : C.int;
   begin
      Result :=
        OSI.clock_gettime
          (OSI.clockid_t (OSC.CLOCK_RT_Ada), Now'Access);
      if Result /= 0 then
         raise Program_Error with "GNATEVL monotonic clock failed";
      end if;
      return System.C_Time.To_Duration (Now);
   end Clock;

   function Promote_Expired_Timers
     (Group : not null Loop_Group_Access) return Duration
   is
      Now     : constant Duration := Clock;
      Nearest : Duration := No_Deadline;
      Item    : Fiber_Access := All_Fibers;
   begin
      while Item /= null loop
         if Item.Group = Group and then Item.State = Waiting then
            case Scheduling.Classify_Deadline (Item.Deadline, Now) is
               when Scheduling.No_Deadline_Set =>
                  null;
               when Scheduling.Expired =>
                  Item.Timed_Out := True;
                  Item.IO_Wait := False;
                  Item.IO_Descriptor := -1;
                  Enqueue (Group, Item);
               when Scheduling.Pending =>
                  Nearest :=
                    Scheduling.Earlier_Deadline (Nearest, Item.Deadline);
            end case;
         end if;
         Item := Item.Next_All;
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

      Result := OSI.pthread_mutex_init (Scheduler_Lock'Access, null);
      if Result /= 0 then
         return -1;
      end if;

      Default_Group := new Loop_Group;
      Default_Group.Id := Default_Group_Id;
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
      All_Fibers := Environment_Fiber;
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
        or else Group_Id >= Dedicated_First_Id
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

      Lock;
      if Find (T) /= null then
         Unlock;
         Contexts.Destroy (Item.Context);
         Free_Fiber (Item);
         return -1;
      end if;
      Item.Next_All := All_Fibers;
      All_Fibers := Item;
      Target.Member_Count := Target.Member_Count + 1;
      Enqueue (Target, Item);
      Unlock;
      if not Pollers.Wake (Target.Scheduler_Poller) then
         raise Program_Error with "GNATEVL create wake failed";
      end if;
      return 0;
   end Create;

   function Is_Event_Task (T : System.Address) return C.int is
      Result : C.int;
   begin
      if not Initialized or else T = System.Null_Address then
         return 0;
      end if;
      Lock;
      Result := (if Find (T) = null then 0 else 1);
      Unlock;
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
      Lock;
      Item := Find (T);
      Result :=
        (if Item = null then OSI.pthread_self else Item.Group.Event_Thread);
      Unlock;
      return Result;
   end Task_Thread;

   function Current_Group return C.int is
     (if Current_Task = System.Null_Address then -1 else Thread_Group.Id);

   function Create_Dedicated_Group return C.int is
      Id      : C.int := Dedicated_First_Id;
      Group   : Loop_Group_Access;
      Item    : Fiber_Access;
      Current : constant System.Address := Current_Task;
   begin
      if not Initialized or else Current = System.Null_Address then
         return -1;
      end if;

      Lock;
      Item := Find (Current);
      if Item = null or else not Item.Can_Migrate
        or else Item.Reserved_Group /= null
      then
         Unlock;
         return -1;
      end if;

      while Id <= Maximum_Group_Id loop
         Group := Groups (Group_Index (Id));
         exit when Group = null
           or else
             (Group.Dedicated
              and then Group.Member_Count = 0
              and then Group.Reserved_For = System.Null_Address);
         Id := Id + 1;
      end loop;
      if Id <= Maximum_Group_Id and then Group /= null then
         Group.Reserved_For := Current;
         Item.Reserved_Group := Group;
         Unlock;
         return Id;
      end if;
      Unlock;
      if Id > Maximum_Group_Id then
         return -1;
      end if;

      Group := Ensure_Group (Id, Dedicated => True);
      if Group = null then
         return -1;
      end if;

      Lock;
      Item := Find (Current);
      if Item = null
        or else Item.Reserved_Group /= null
        or else Group.Member_Count /= 0
        or else Group.Reserved_For /= System.Null_Address
      then
         Unlock;
         return Create_Dedicated_Group;
      end if;
      Group.Reserved_For := Current;
      Item.Reserved_Group := Group;
      Unlock;
      return Id;
   end Create_Dedicated_Group;

   function Is_Dedicated_Group (Group : C.int) return C.int is
      Item   : Loop_Group_Access;
      Result : C.int;
   begin
      if not Initialized
        or else Group < Default_Group_Id
        or else Group > Maximum_Group_Id
      then
         return 0;
      end if;
      Lock;
      Item := Groups (Group_Index (Group));
      Result := (if Item /= null and then Item.Dedicated then 1 else 0);
      Unlock;
      return Result;
   end Is_Dedicated_Group;

   function Migrate (Group : C.int) return C.int is
      Item   : Fiber_Access;
      Source : Loop_Group_Access;
      Target : Loop_Group_Access;
   begin
      if Current_Task = System.Null_Address
        or else Group < Default_Group_Id
        or else Group > Maximum_Group_Id
      then
         return -1;
      end if;

      Source := Thread_Group;
      if Source.Id = Group then
         return 0;
      end if;

      if Group < Dedicated_First_Id then
         Target := Ensure_Group (Group, Dedicated => False);
      else
         Lock;
         Target := Groups (Group_Index (Group));
         Unlock;
      end if;
      if Target = null then
         return -1;
      end if;

      Lock;
      Item := Source.Current_Fiber;
      if Item = null
        or else not Item.Can_Migrate
        or else Item.Group /= Source
        or else
          (Target.Dedicated
           and then
             (Target.Member_Count /= 0
              or else Target.Reserved_For /= Item.T
              or else Item.Reserved_Group /= Target))
      then
         Unlock;
         return -1;
      end if;

      Item.Migration_Target := Target;
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

      Lock;
      if not Pollers.Watch (Group.Scheduler_Poller, Descriptor, Condition) then
         Unlock;
         return -1;
      end if;

      Item := Group.Current_Fiber;
      Item.Deadline :=
        (if Timeout < 0.0 then No_Deadline else Clock + Timeout);
      Item.Timed_Out := False;
      Item.IO_Wait := True;
      Item.IO_Descriptor := Descriptor;
      Item.IO_Interest := Condition;
      Item.State := Waiting;
      Contexts.Switch (Item.Context, Group.Scheduler_Context);

      return (if Item.Timed_Out then 1 else 0);
   end Wait_IO;

   function Set_Priority
     (T : System.Address; Priority : C.int) return C.int
   is
      Item : Fiber_Access;
   begin
      Lock;
      Item := Find (T);
      if Item = null then
         Unlock;
         return -1;
      end if;

      if Item.State = Ready then
         Remove_From_Ready (Item.Group, Item);
         Item.Priority := Priority;
         Enqueue (Item.Group, Item);
      else
         Item.Priority := Priority;
      end if;
      Unlock;
      return 0;
   end Set_Priority;

   function Yield return C.int is
      Group : constant Loop_Group_Access := Thread_Group;
      Item  : Fiber_Access;
   begin
      if not Is_Event_Thread or else Group.Current_Fiber = null then
         return -1;
      end if;

      Lock;
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
      if not Is_Event_Thread or else Group.Current_Fiber = null then
         return -1;
      end if;

      Lock;
      Item := Group.Current_Fiber;
      Item.Deadline := Deadline;
      Item.Timed_Out := False;
      Item.State := Waiting;

      if Task_Lock /= System.Null_Address then
         Result := Mutex_Unlock (Task_Lock);
         if Result /= 0 then
            raise Program_Error with "GNATEVL task unlock failed";
         end if;
      end if;

      Contexts.Switch (Item.Context, Group.Scheduler_Context);

      if Task_Lock /= System.Null_Address then
         Result := Mutex_Lock (Task_Lock);
         if Result /= 0 then
            raise Program_Error with "GNATEVL task relock failed";
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
      Lock;
      Item := Find (T);
      if Item = null then
         Unlock;
         return -1;
      end if;

      Group := Item.Group;
      if Item.State = Waiting then
         Item.Deadline := No_Deadline;
         Item.Timed_Out := False;
         Item.IO_Wait := False;
         Item.IO_Descriptor := -1;
         Enqueue (Group, Item);
         Made_Ready := True;
      end if;
      Unlock;

      if Made_Ready and then not Pollers.Wake (Group.Scheduler_Poller) then
         raise Program_Error with "GNATEVL task wake failed";
      end if;
      return 0;
   end Wake;

   function Destroy (T : System.Address) return C.int is
      Item : Fiber_Access;
   begin
      if not Initialized or else T = System.Null_Address then
         return -1;
      end if;

      Lock;
      Item := Find (T);
      if Item = null then
         Unlock;
         return -1;
      end if;

      Item.T := System.Null_Address;
      Item.Destroy_Requested := True;

      case Scheduling.Plan_Destroy (Phase_Of (Item.State)) is
         when Scheduling.Defer =>
            Unlock;
            return 0;
         when Scheduling.Reap_Now =>
            Reap (Item);
            Unlock;
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

      Lock;
      Group := Item.Group;
      Item.State := Finished;
      Item.Deadline := No_Deadline;
      Contexts.Switch (Item.Context, Group.Scheduler_Context);
      raise Program_Error;
   end Fiber_Main;

   procedure Handle_Poll_Event
     (Group : not null Loop_Group_Access;
      Event : Pollers.Poll_Event)
   is
      Item    : Fiber_Access := All_Fibers;
      Matches : Boolean;
   begin
      if Event.Kind not in Pollers.Readable_Event | Pollers.Writable_Event then
         return;
      end if;

      while Item /= null loop
         Matches :=
           Item.Group = Group
           and then Item.State = Waiting
           and then Item.IO_Wait
           and then Item.IO_Descriptor = Event.Descriptor
           and then
             ((Event.Kind = Pollers.Readable_Event
               and then Item.IO_Interest = Pollers.Readable)
              or else
                (Event.Kind = Pollers.Writable_Event
                 and then Item.IO_Interest = Pollers.Writable));
         if Matches then
            Item.Deadline := No_Deadline;
            Item.Timed_Out := False;
            Item.IO_Wait := False;
            Item.IO_Descriptor := -1;
            Enqueue (Group, Item);
         end if;
         Item := Item.Next_All;
      end loop;
   end Handle_Poll_Event;

   procedure Poll_Ready_Events (Group : not null Loop_Group_Access) is
      Waited : Boolean;
      Event  : Pollers.Poll_Event;
   begin
      for Count in 1 .. Poll_Event_Budget loop
         Unlock;
         Waited := Pollers.Wait (Group.Scheduler_Poller, 0.0, Event);
         Lock;
         if not Waited then
            raise Program_Error with "GNATEVL readiness poll failed";
         end if;
         exit when Event.Kind = Pollers.Timeout_Event;
         Handle_Poll_Event (Group, Event);
      end loop;
   end Poll_Ready_Events;

   procedure Scheduler_Main (Argument : System.Address) is
      Group : constant Loop_Group_Access := Address_To_Group (Argument);
      Dispatches_Until_Timer_Check : Natural := 0;
      Timeout : Duration;
      Next    : Fiber_Access;
      Waited  : Boolean;
      Event   : Pollers.Poll_Event;
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
               raise Program_Error with
                 "GNATEVL scheduler maintenance counter invariant failed";
            end if;
            Dispatches_Until_Timer_Check :=
              Scheduling.After_Dispatch
                (Positive (Dispatches_Until_Timer_Check));
            Unlock;
            Contexts.Switch (Group.Scheduler_Context, Next.Context);

            if Next.Migration_Target /= null then
               Transfer (Next, Group);
            elsif Scheduling.Should_Reap_After_Switch
              (Phase_Of (Next.State), Next.Destroy_Requested)
            then
               Reap (Next);
            end if;
         else
            Group.Current_Fiber := null;
            Unlock;
            Waited := Pollers.Wait (Group.Scheduler_Poller, Timeout, Event);
            Lock;
            if not Waited then
               raise Program_Error with "GNATEVL readiness wait failed";
            end if;
            Handle_Poll_Event (Group, Event);
         end if;
      end loop;
   end Scheduler_Main;

end System.Gnatevl.Scheduler;
