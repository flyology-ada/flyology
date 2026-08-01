with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.C_Time;
with System.Gnatevl.Contexts;
with System.Gnatevl.Poller;
with System.OS_Constants;
with System.OS_Interface;

package body System.Gnatevl.Scheduler is
   package C renames Interfaces.C;
   package Contexts renames System.Gnatevl.Contexts;
   package Pollers renames System.Gnatevl.Poller;
   package OSC renames System.OS_Constants;
   package OSI renames System.OS_Interface;

   use type C.int;
   use type C.size_t;
   use type C.unsigned_long;
   use type Contexts.Context_Access;
   use type OSI.pthread_t;

   Scheduler_Stack_Size : constant C.size_t := 256 * 1_024;
   Timer_Check_Interval : constant := 64;
   No_Deadline          : constant Duration := -1.0;

   type Fiber_State is (Running, Ready, Waiting, Finished);
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
   function Clock return Duration;
   function Promote_Expired_Timers return Duration;
   function Is_Event_Thread return Boolean;

   procedure Lock is
      Result : constant C.int :=
        OSI.pthread_mutex_lock (Scheduler_Lock'Access);
   begin
      pragma Assert (Result = 0);
   end Lock;

   procedure Unlock is
      Result : constant C.int :=
        OSI.pthread_mutex_unlock (Scheduler_Lock'Access);
   begin
      pragma Assert (Result = 0);
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
        and then
          (Position.Priority > Item.Priority
           or else
             (Position.Priority = Item.Priority
              and then Position.Sequence < Item.Sequence))
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

   function Clock return Duration is
      Now    : aliased System.C_Time.timespec;
      Result : C.int;
   begin
      Result :=
        OSI.clock_gettime
          (OSI.clockid_t (OSC.CLOCK_RT_Ada), Now'Access);
      pragma Assert (Result = 0);
      return System.C_Time.To_Duration (Now);
   end Clock;

   function Promote_Expired_Timers return Duration is
      Now     : constant Duration := Clock;
      Nearest : Duration := No_Deadline;
      Item    : Fiber_Access := All_Fibers;
   begin
      while Item /= null loop
         if Item.State = Waiting and then Item.Deadline >= 0.0 then
            if Item.Deadline <= Now then
               Item.Timed_Out := True;
               Enqueue (Item);
            elsif Nearest < 0.0 or else Item.Deadline < Nearest then
               Nearest := Item.Deadline;
            end if;
         end if;
         Item := Item.Next_All;
      end loop;

      return (if Nearest < 0.0 then No_Deadline else Nearest - Now);
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
      return (if Pollers.Wake (Scheduler_Poller) then 0 else -1);
   end Create;

   function Is_Event_Task (T : System.Address) return C.int is
      Result : C.int;
   begin
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
         pragma Assert (Result = 0);
      end if;

      Contexts.Switch (Item.Context, Scheduler_Context);

      if Task_Lock /= System.Null_Address then
         Result := Mutex_Lock (Task_Lock);
         pragma Assert (Result = 0);
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
         Enqueue (Item);
         Made_Ready := True;
      end if;
      Unlock;

      return
        (if not Made_Ready or else Pollers.Wake (Scheduler_Poller)
         then 0
         else -1);
   end Wake;

   function Destroy (T : System.Address) return C.int is
      Item     : Fiber_Access;
      Position : Fiber_Access;
      Previous : Fiber_Access;
   begin
      Lock;
      Item := Find (T);
      if Item = null or else Item.State /= Finished then
         Unlock;
         return -1;
      end if;

      Position := All_Fibers;
      while Position /= Item loop
         Previous := Position;
         Position := Position.Next_All;
      end loop;
      if Previous = null then
         All_Fibers := Item.Next_All;
      else
         Previous.Next_All := Item.Next_All;
      end if;
      Unlock;

      Contexts.Destroy (Item.Context);
      Free (Item);
      return 0;
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

   procedure Scheduler_Main (Argument : System.Address) is
      pragma Unreferenced (Argument);
      Dispatches_Until_Timer_Check : Natural := 0;
      Timeout                      : Duration;
      Next                         : Fiber_Access;
      Waited                       : Boolean;
   begin
      loop
         Timeout := No_Deadline;
         if Ready_Head = null or else Dispatches_Until_Timer_Check = 0 then
            Timeout := Promote_Expired_Timers;
            Dispatches_Until_Timer_Check := Timer_Check_Interval;
         end if;

         if Ready_Head /= null then
            Next := Ready_Head;
            Ready_Head := Next.Next_Ready;
            Next.Next_Ready := null;
            Next.State := Running;
            Current_Fiber := Next;
            Dispatches_Until_Timer_Check :=
              Dispatches_Until_Timer_Check - 1;
            Unlock;
            Contexts.Switch (Scheduler_Context, Next.Context);
         else
            Current_Fiber := null;
            Unlock;
            Waited := Pollers.Wait (Scheduler_Poller, Timeout);
            pragma Assert (Waited);
            Lock;
         end if;
      end loop;
   end Scheduler_Main;

end System.Gnatevl.Scheduler;
