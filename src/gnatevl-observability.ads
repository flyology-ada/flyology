with Gnatevl.Execution_Groups;
with Interfaces;

package Gnatevl.Observability with Preelaborate is

   use type Interfaces.Unsigned_64;

   subtype Group_Id is Gnatevl.Execution_Groups.Group_Id;
   subtype Counter is Interfaces.Unsigned_64;

   type Event_Thread_State is (Starting, Running, Failed);
   type Fatal_Context is
     (No_Fatal,
      Scheduler_Invariant,
      Mutex_Failure,
      Poller_Failure,
      Context_Switch_Failure,
      Fork_Child_Use);

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

   --  Return False when Group has never been created. This query is inert: it
   --  does not initialize an event group or allocate runtime resources.
   --
   --  The state and queue counts in Result are captured while holding the
   --  group's scheduler lock. Counters are cumulative modulo Counter'Modulus
   --  and belong to the lifetime of the permanent group.
   function Snapshot
     (Group  : Group_Id;
      Result : out Group_Snapshot) return Boolean;

   --  Progress between periodic samples is the least intrusive loop-lag
   --  signal: a group with runnable work and no new dispatches or poll batches
   --  is not advancing. This deliberately avoids a clock read per dispatch.
   function Made_Progress
     (Earlier : Group_Snapshot;
      Later   : Group_Snapshot) return Boolean
   is (Later.Dispatches /= Earlier.Dispatches
       or else Later.Poll_Batches /= Earlier.Poll_Batches
       or else Later.Poll_Events /= Earlier.Poll_Events);

   --  Fatal runtime paths record this classification and write it to standard
   --  error immediately before aborting. In a normally running process the
   --  value is No_Fatal; the retained scalar is principally useful to crash
   --  handlers and postmortem debuggers and requires no scheduler lock.
   function Last_Fatal return Fatal_Context;

end Gnatevl.Observability;
