with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.C_Time;
with System.Gnatevl.Contexts;
with System.Gnatevl.Poller;
with System.Gnatevl.Scheduling_Policy;
with System.OS_Constants;
with System.OS_Interface;

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
      Next_Ready : Fiber_Access;
      Next_All   : Fiber_Access;
   end record;

   function To_Address is new Ada.Unchecked_Conversion
     (Fiber_Access, System.Address);
   function To_Fiber is new Ada.Unchecked_Conversion
     (System.Address, Fiber_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Fiber, Fiber_Access);

   Scheduler_Lock    : aliased OSI.pthread_mutex_t;
   Event_Thread      : OSI.pthread_t;
   Initialized       : Boolean := False;
   Scheduler_Context : Contexts.Context_Access;
   Scheduler_Poller  : Pollers.Poller;
   Current_Fiber     : Fiber_Access;
   Ready_Head        : Fiber_Access;
   All_Fibers        : Fiber_Access;
   Next_Sequence     : C.unsigned_long := 0;

   function Mutex_Unlock (Mutex : System.Address) return C.int;
   pragma Import (C, Mutex_Unlock, "pthread_mutex_unlock");
   function Mutex_Lock (Mutex : System.Address) return C.int;
   pragma Import (C, Mutex_Lock, "pthread_mutex_lock");

   procedure Scheduler_Main (Argument : System.Address);
   pragma Convention (C, Scheduler_Main);
   pragma No_Return (Scheduler_Main);

   procedure Fiber_Main (Argument : System.Address);
   pragma Convention (C, Fiber_Main);
   pragma No_Return (Fiber_Main);

   procedure Lock;
   procedure Unlock;
   function Find (T : System.Address) return Fiber_Access;
   procedure Enqueue (Item : not null Fiber_Access);
   procedure Remove_From_Ready (Item : not null Fiber_Access);
   procedure Reap (Item : not null Fiber_Access);
   function Clock return Duration;
   function Promote_Expired_Timers return Duration;
   function Is_Event_Thread return Boolean;
   procedure Handle_Poll_Event (Event : Pollers.Poll_Event);
   procedure Poll_Ready_Events;

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

   function Find (T : System.Address) return Fiber_Access is
      Item : Fiber_Access := All_Fibers;
   begin
      while Item /= null and then Item.T /= T loop
         Item := Item.Next_All;
      end loop;
      return Item;
   end Find;

   procedure Enqueue (Item : not null Fiber_Access) is
      Position : Fiber_Access := Ready_Head;
      Previous : Fiber_Access;
   begin
      Item.State := Ready;
      Next_Sequence := Next_Sequence + 1;
      Item.Sequence := Next_Sequence;
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
         Ready_Head := Item;
      else
         Previous.Next_Ready := Item;
      end if;
   end Enqueue;

   procedure Remove_From_Ready (Item : not null Fiber_Access) is
      Position : Fiber_Access := Ready_Head;
      Previous : Fiber_Access;
   begin
      while Position /= null loop
         if Position = Item then
            if Previous = null then
               Ready_Head := Position.Next_Ready;
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
   begin
      if Scheduling.Plan_Destroy (Phase_Of (Item.State)) = Scheduling.Defer
      then
         raise Program_Error with "attempt to reap a running GNATEVL task";
      end if;

      if Item.State = Ready then
         Remove_From_Ready (Item);
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

      if Current_Fiber = Item then
         Current_Fiber := null;
      end if;
      Contexts.Destroy (Item.Context);
      Free (Victim);
   end Reap;

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

   function Promote_Expired_Timers return Duration is
      Now     : constant Duration := Clock;
      Nearest : Duration := No_Deadline;
      Item    : Fiber_Access := All_Fibers;
   begin
      while Item /= null loop
         if Item.State = Waiting then
            case Scheduling.Classify_Deadline (Item.Deadline, Now) is
               when Scheduling.No_Deadline_Set =>
                  null;
               when Scheduling.Expired =>
                  Item.Timed_Out := True;
                  Item.IO_Wait := False;
                  Item.IO_Descriptor := -1;
                  Enqueue (Item);
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
      Result            : C.int;
   begin
      if Environment = System.Null_Address then
         return -1;
      end if;

      if Initialized then
         return -1;
      end if;

      Result := OSI.pthread_mutex_init (Scheduler_Lock'Access, null);
      if Result /= 0 or else not Pollers.Initialize (Scheduler_Poller) then
         return -1;
      end if;

      Environment_Fiber := new Fiber;
      Environment_Fiber.Context := Contexts.Capture;
      if Environment_Fiber.Context = null then
         Free (Environment_Fiber);
         return -1;
      end if;

      Scheduler_Context :=
        Contexts.Create
          (Scheduler_Stack_Size,
           Scheduler_Main'Address,
           System.Null_Address,
           Environment_Fiber.Context);
      if Scheduler_Context = null then
         Contexts.Destroy (Environment_Fiber.Context);
         Free (Environment_Fiber);
         return -1;
      end if;

      Environment_Fiber.T := Environment;
      Environment_Fiber.State := Running;
      Environment_Fiber.Next_All := null;
      All_Fibers := Environment_Fiber;
      Current_Fiber := Environment_Fiber;
      Event_Thread := OSI.pthread_self;
      Initialized := True;
      return 0;
   end Initialize;

   function Create
     (T          : System.Address;
      Stack_Size : C.size_t;
      Priority   : C.int;
      Wrapper    : System.Address) return C.int
   is
      Item : Fiber_Access;
   begin
      if not Initialized
        or else T = System.Null_Address
        or else Stack_Size = 0
        or else Wrapper = System.Null_Address
      then
         return -1;
      end if;

      Item := new Fiber;
      Item.T := T;
      Item.Wrapper := Wrapper;
      Item.Priority := Priority;
      Item.Context :=
        Contexts.Create
          (Stack_Size,
           Fiber_Main'Address,
           To_Address (Item),
           Scheduler_Context);
      if Item.Context = null then
         Free (Item);
         return -1;
      end if;

      Lock;
      if Find (T) /= null then
         Unlock;
         Contexts.Destroy (Item.Context);
         Free (Item);
         return -1;
      end if;
      Item.Next_All := All_Fibers;
      All_Fibers := Item;
      Enqueue (Item);
      Unlock;
      if not Pollers.Wake (Scheduler_Poller) then
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
     (Initialized and then OSI.pthread_self = Event_Thread);

   function Current_Task return System.Address is
     (if Is_Event_Thread and then Current_Fiber /= null
      then Current_Fiber.T
      else System.Null_Address);

   function In_Event_Task return C.int is
     (if Current_Task = System.Null_Address then 0 else 1);

   function Wait_IO
     (Descriptor          : C.int;
      For_Write           : C.int;
      Timeout_Nanoseconds : C.long_long) return C.int
   is
      Item      : Fiber_Access;
      Condition : constant Pollers.Interest :=
        (if For_Write = 0 then Pollers.Readable else Pollers.Writable);
      Whole     : C.long_long;
      Remainder : C.long_long;
      Timeout   : Duration;
   begin
      if not Is_Event_Thread
        or else Current_Fiber = null
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
      if not Pollers.Watch (Scheduler_Poller, Descriptor, Condition) then
         Unlock;
         return -1;
      end if;

      Item := Current_Fiber;
      Item.Deadline :=
        (if Timeout < 0.0 then No_Deadline else Clock + Timeout);
      Item.Timed_Out := False;
      Item.IO_Wait := True;
      Item.IO_Descriptor := Descriptor;
      Item.IO_Interest := Condition;
      Item.State := Waiting;
      Contexts.Switch (Item.Context, Scheduler_Context);

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
         Remove_From_Ready (Item);
         Item.Priority := Priority;
         Enqueue (Item);
      else
         Item.Priority := Priority;
      end if;
      Unlock;
      return 0;
   end Set_Priority;

   function Yield return C.int is
      Item : Fiber_Access;
   begin
      if not Is_Event_Thread or else Current_Fiber = null then
         return -1;
      end if;

      Lock;
      Item := Current_Fiber;
      Enqueue (Item);
      Contexts.Switch (Item.Context, Scheduler_Context);
      return 0;
   end Yield;

   function Sleep
     (Task_Lock : System.Address;
      Deadline  : Duration;
      Timed_Out : access C.int) return C.int
   is
      Item   : Fiber_Access;
      Result : C.int;
   begin
      if not Is_Event_Thread or else Current_Fiber = null then
         return -1;
      end if;

      Lock;
      Item := Current_Fiber;
      Item.Deadline := Deadline;
      Item.Timed_Out := False;
      Item.State := Waiting;

      if Task_Lock /= System.Null_Address then
         Result := Mutex_Unlock (Task_Lock);
         if Result /= 0 then
            raise Program_Error with "GNATEVL task unlock failed";
         end if;
      end if;

      Contexts.Switch (Item.Context, Scheduler_Context);

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
      Made_Ready : Boolean := False;
   begin
      Lock;
      Item := Find (T);
      if Item = null then
         Unlock;
         return -1;
      end if;

      if Item.State = Waiting then
         Item.Deadline := No_Deadline;
         Item.Timed_Out := False;
         Item.IO_Wait := False;
         Item.IO_Descriptor := -1;
         Enqueue (Item);
         Made_Ready := True;
      end if;
      Unlock;

      if Made_Ready and then not Pollers.Wake (Scheduler_Poller) then
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

      --  Detach the ATCB identity immediately. Finalize_TCB may free and reuse
      --  that address before a running fiber reaches its final switch.
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
      Item : constant Fiber_Access := To_Fiber (Argument);
      type Wrapper_Access is access procedure (T : System.Address);
      pragma Convention (C, Wrapper_Access);
      function To_Wrapper is new Ada.Unchecked_Conversion
        (System.Address, Wrapper_Access);
   begin
      To_Wrapper (Item.Wrapper).all (Item.T);

      Lock;
      Item.State := Finished;
      Item.Deadline := No_Deadline;
      Contexts.Switch (Item.Context, Scheduler_Context);
      raise Program_Error;
   end Fiber_Main;

   procedure Handle_Poll_Event (Event : Pollers.Poll_Event) is
      Item : Fiber_Access := All_Fibers;
      Matches : Boolean;
   begin
      if Event.Kind not in Pollers.Readable_Event | Pollers.Writable_Event then
         return;
      end if;

      while Item /= null loop
         Matches :=
           Item.State = Waiting
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
            Enqueue (Item);
         end if;
         Item := Item.Next_All;
      end loop;
   end Handle_Poll_Event;

   procedure Poll_Ready_Events is
      Waited : Boolean;
      Event  : Pollers.Poll_Event;
   begin
      --  Poll with a bounded budget while runnable fibers exist. This keeps
      --  descriptor readiness moving without allowing a hot I/O set to starve
      --  the ready queue in the opposite direction.
      for Count in 1 .. Poll_Event_Budget loop
         Unlock;
         Waited := Pollers.Wait (Scheduler_Poller, 0.0, Event);
         Lock;
         if not Waited then
            raise Program_Error with "GNATEVL readiness poll failed";
         end if;
         exit when Event.Kind = Pollers.Timeout_Event;
         Handle_Poll_Event (Event);
      end loop;
   end Poll_Ready_Events;

   procedure Scheduler_Main (Argument : System.Address) is
      pragma Unreferenced (Argument);
      Dispatches_Until_Timer_Check : Natural := 0;
      Timeout                      : Duration;
      Next                         : Fiber_Access;
      Waited                       : Boolean;
      Event                        : Pollers.Poll_Event;
   begin
      loop
         Timeout := No_Deadline;
         if Scheduling.Maintenance_Due
           (Ready_Head /= null, Dispatches_Until_Timer_Check)
         then
            Timeout := Promote_Expired_Timers;
            Dispatches_Until_Timer_Check := Timer_Check_Interval;
            if Ready_Head /= null then
               Poll_Ready_Events;
            end if;
         end if;

         if Ready_Head /= null then
            Next := Ready_Head;
            Ready_Head := Next.Next_Ready;
            Next.Next_Ready := null;
            Next.State := Running;
            Current_Fiber := Next;
            if Dispatches_Until_Timer_Check = 0 then
               raise Program_Error with
                 "GNATEVL scheduler maintenance counter invariant failed";
            end if;
            Dispatches_Until_Timer_Check :=
              Scheduling.After_Dispatch
                (Positive (Dispatches_Until_Timer_Check));
            Unlock;
            Contexts.Switch (Scheduler_Context, Next.Context);
            if Scheduling.Should_Reap_After_Switch
              (Phase_Of (Next.State), Next.Destroy_Requested)
            then
               Reap (Next);
            end if;
         else
            Current_Fiber := null;
            Unlock;
            Waited := Pollers.Wait (Scheduler_Poller, Timeout, Event);
            Lock;
            if not Waited then
               raise Program_Error with "GNATEVL readiness wait failed";
            end if;
            Handle_Poll_Event (Event);
         end if;
      end loop;
   end Scheduler_Main;

end System.Gnatevl.Scheduler;
