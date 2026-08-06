with Interfaces.C;

package body Flyology.Observability is
   package C renames Interfaces.C;

   use type C.int;
   use type C.size_t;
   use type C.unsigned;
   use type C.unsigned_long_long;

   ABI_Version : constant C.unsigned := 5;

   type Runtime_Group_Snapshot is record
      Version                  : C.unsigned;
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
   end record;
   pragma Convention (C, Runtime_Group_Snapshot);

   function Runtime_Observe_Group
     (Group         : C.int;
      Snapshot      : access Runtime_Group_Snapshot;
      Snapshot_Size : C.size_t) return C.int;
   pragma Import
     (C, Runtime_Observe_Group, "flyology_runtime_observe_group");

   Task_Snapshot_ABI_Version : constant C.unsigned := 1;
   type Runtime_Task_Snapshot_Metadata is record
      Version : C.unsigned;
      Written : C.unsigned_long_long;
      Total   : C.unsigned_long_long;
   end record with Convention => C;

   function Runtime_Observe_Tasks
     (Group         : C.int;
      Items         : System.Address;
      Capacity      : C.size_t;
      Item_Size     : C.size_t;
      Metadata      : System.Address;
      Metadata_Size : C.size_t) return C.int;
   pragma Import
     (C, Runtime_Observe_Tasks, "flyology_runtime_observe_tasks");

   function Runtime_Current_Task_Instance return C.unsigned_long_long;
   pragma Import
     (C,
      Runtime_Current_Task_Instance,
      "flyology_runtime_current_task_instance");

   function Runtime_Observe_Last_Fatal return C.int;
   pragma Import
     (C, Runtime_Observe_Last_Fatal, "flyology_runtime_observe_last_fatal");

   Stack_Pool_ABI_Version : constant C.unsigned := 1;
   type Runtime_Stack_Pool_Snapshot is record
      Version          : C.unsigned;
      Active_Arenas    : C.unsigned_long_long;
      Live_Stacks      : C.unsigned_long_long;
      Live_Usable_Bytes : C.unsigned_long_long;
      Reserved_Bytes   : C.unsigned_long_long;
      Arena_Mappings   : C.unsigned_long_long;
      Arena_Unmappings : C.unsigned_long_long;
      Shared_Stacks    : C.unsigned_long_long;
      Discarded_Stacks : C.unsigned_long_long;
   end record with Convention => C;

   function Runtime_Observe_Stack_Pool
     (Snapshot      : System.Address;
      Snapshot_Size : C.size_t) return C.int;
   pragma Import
     (C, Runtime_Observe_Stack_Pool, "flyology_runtime_observe_stack_pool");

   function Snapshot
     (Group  : Group_Id;
      Result : out Group_Snapshot) return Boolean
   is
      Raw    : aliased Runtime_Group_Snapshot;
      Status : C.int;
   begin
      Status := Runtime_Observe_Group
        (C.int (Group), Raw'Access, Runtime_Group_Snapshot'Size / 8);
      if Status = 0 then
         return False;
      elsif Status /= 1 or else Raw.Version /= ABI_Version then
         raise Program_Error with "incompatible Flyology observability ABI";
      end if;

      Result :=
        (Group                    => Group,
         Thread_State             =>
           (case Raw.Thread_State is
               when 1 => Starting,
               when 2 => Running,
               when others => Failed),
         Dedicated                => Raw.Dedicated /= 0,
         Reserved                 => Raw.Reserved /= 0,
         Members                  => Counter (Raw.Members),
         Pinned_Members           => Counter (Raw.Pinned_Members),
         Ready                    => Counter (Raw.Ready),
         Waiting                  => Counter (Raw.Waiting),
         Running                  => Counter (Raw.Running),
         Migrating                => Counter (Raw.Migrating),
         Finished                 => Counter (Raw.Finished),
         Timer_Waits              => Counter (Raw.Timer_Waits),
         Descriptor_Waits         => Counter (Raw.Descriptor_Waits),
         Interrupt_Waits          => Counter (Raw.Interrupt_Waits),
         File_Waits               => Counter (Raw.File_Waits),
         Pending_File_Submissions =>
           Counter (Raw.Pending_File_Submissions),
         Dormancy_Candidates      => Counter (Raw.Dormancy_Candidates),
         Dormancy_Candidate_Bytes =>
           Counter (Raw.Dormancy_Candidate_Bytes),
         Cold_Stacks              => Counter (Raw.Cold_Stacks),
         Cold_Stack_Bytes         => Counter (Raw.Cold_Stack_Bytes),
         Cold_Advice_Attempts     => Counter (Raw.Cold_Advice_Attempts),
         Cold_Advice_Accepted     => Counter (Raw.Cold_Advice_Accepted),
         Cold_Advice_Failures     => Counter (Raw.Cold_Advice_Failures),
         Pageout_Advice_Attempts  => Counter (Raw.Pageout_Advice_Attempts),
         Pageout_Advice_Accepted  => Counter (Raw.Pageout_Advice_Accepted),
         Pageout_Advice_Failures  => Counter (Raw.Pageout_Advice_Failures),
         Dispatches               => Counter (Raw.Dispatches),
         Poll_Batches             => Counter (Raw.Poll_Batches),
         Poll_Events              => Counter (Raw.Poll_Events),
         Wakeups                  => Counter (Raw.Wakeups),
         Migrations_In            => Counter (Raw.Migrations_In),
         Migrations_Out           => Counter (Raw.Migrations_Out));
      return True;
   end Snapshot;

   function Current_Task_Instance return Task_Instance_Id is
     (Task_Instance_Id (Runtime_Current_Task_Instance));

   function Snapshot_Tasks
     (Group : Group_Id;
      Items : in out Task_Snapshot_Array;
      Count : out Natural;
      Total : out Counter) return Boolean
   is
      Metadata : aliased Runtime_Task_Snapshot_Metadata :=
        (Version => 0, Written => 0, Total => 0);
      Status : C.int;
   begin
      Count := 0;
      Total := 0;
      if Items'Length = 0 then
         raise Constraint_Error with "task snapshot buffer must be nonempty";
      end if;
      Status := Runtime_Observe_Tasks
        (C.int (Group),
         Items (Items'First)'Address,
         C.size_t (Items'Length),
         Task_Snapshot'Size / 8,
         Metadata'Address,
         Runtime_Task_Snapshot_Metadata'Size / 8);
      if Status = 0 then
         return False;
      elsif Status /= 1
        or else Metadata.Version /= Task_Snapshot_ABI_Version
        or else Metadata.Written > C.unsigned_long_long (Items'Length)
        or else Metadata.Total < Metadata.Written
      then
         raise Program_Error with
           "incompatible Flyology task snapshot ABI";
      end if;
      Count := Natural (Metadata.Written);
      Total := Counter (Metadata.Total);
      return True;
   end Snapshot_Tasks;

   function Last_Fatal return Fatal_Context is
     (case Runtime_Observe_Last_Fatal is
         when 0 => No_Fatal,
         when 1 => Scheduler_Invariant,
         when 2 => Mutex_Failure,
         when 3 => Poller_Failure,
         when 4 => Context_Switch_Failure,
         when 5 => Fork_Child_Use,
         when others => Scheduler_Invariant);

   function Stack_Pool return Stack_Pool_Snapshot is
      Raw    : aliased Runtime_Stack_Pool_Snapshot;
      Status : C.int;
   begin
      Status := Runtime_Observe_Stack_Pool
        (Raw'Address, Runtime_Stack_Pool_Snapshot'Size / 8);
      if Status /= 1 or else Raw.Version /= Stack_Pool_ABI_Version then
         raise Program_Error with
           "incompatible Flyology stack-pool observability ABI";
      end if;
      return
        (Active_Arenas    => Counter (Raw.Active_Arenas),
         Live_Stacks      => Counter (Raw.Live_Stacks),
         Live_Usable_Bytes => Counter (Raw.Live_Usable_Bytes),
         Reserved_Bytes   => Counter (Raw.Reserved_Bytes),
         Arena_Mappings   => Counter (Raw.Arena_Mappings),
         Arena_Unmappings => Counter (Raw.Arena_Unmappings),
         Shared_Stacks    => Counter (Raw.Shared_Stacks),
         Discarded_Stacks => Counter (Raw.Discarded_Stacks));
   end Stack_Pool;

end Flyology.Observability;
