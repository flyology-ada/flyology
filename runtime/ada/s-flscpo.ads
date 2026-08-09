with Interfaces.C;

package System.Flyology.Scheduling_Policy
  with Preelaborate,
       SPARK_Mode
is
   package C renames Interfaces.C;

   use type C.int;
   No_Deadline : constant Duration := -1.0;
   type Deadline_Status is (No_Deadline_Set, Expired, Pending);

   type Fiber_Phase is (Running, Ready, Waiting, Migrating, Finished);
   type Destruction_Plan is (Defer, Reap_Now);
   type Ready_Placement is (Queue_Head, Queue_Tail);
   type File_Cancel_Plan is
     (Ignore_Cancel, Complete_Pending, Request_Kernel_Cancel);

   function Plan_File_Cancel
     (File_Waiting       : Boolean;
      Submission_Pending : Boolean;
      Already_Attempted  : Boolean) return File_Cancel_Plan
   with Inline,
        Post =>
          (if not File_Waiting or else Already_Attempted then
              Plan_File_Cancel'Result = Ignore_Cancel
           elsif Submission_Pending then
              Plan_File_Cancel'Result = Complete_Pending
           else
              Plan_File_Cancel'Result = Request_Kernel_Cancel);

   function Placement_After_Priority_Update
     (Loss_Of_Inheritance : Boolean) return Ready_Placement
   with Inline,
        Post =>
          (if Loss_Of_Inheritance then
              Placement_After_Priority_Update'Result = Queue_Head
           else
              Placement_After_Priority_Update'Result = Queue_Tail);

   function Plan_Destroy (Phase : Fiber_Phase) return Destruction_Plan
   with Inline,
        Post =>
          (if Phase in Running | Migrating then
              Plan_Destroy'Result = Defer
           else
              Plan_Destroy'Result = Reap_Now);

   --  Published process-lifecycle states: 0 dormant, 1 running, 2 finalizing,
   --  3 stopped, 4 cleanup deferred. Admitting a create means letting it name,
   --  read, or lock an execution group.
   function Creation_Admitted (Lifecycle : C.int) return Boolean
   with Inline,
        Post => Creation_Admitted'Result = (Lifecycle in 0 | 1);

   --  Admitting a teardown means destroying pollers, group mutexes, and the
   --  groups themselves. It requires the published finalizing state, a
   --  quiescent registry, and no create still holding a claim on a group.
   function Teardown_Admitted
     (Lifecycle          : C.int;
      Registry_Quiescent : Boolean;
      Outstanding_Claims : Natural) return Boolean
   with Inline,
        Post =>
          Teardown_Admitted'Result =
            (Lifecycle = 2
             and then Registry_Quiescent
             and then Outstanding_Claims = 0);

   --  The two admissions are mutually exclusive for every lifecycle value.
   --  That is the property the scheduler depends on: while any create can
   --  still be admitted, no group it may reach can be stopped or freed.
   procedure Lemma_Creation_Excludes_Teardown
     (Lifecycle          : C.int;
      Registry_Quiescent : Boolean;
      Outstanding_Claims : Natural)
   with Ghost,
        Post =>
          not (Creation_Admitted (Lifecycle)
               and then Teardown_Admitted
                          (Lifecycle,
                           Registry_Quiescent,
                           Outstanding_Claims));

   First_Shared_Group    : constant C.int := 0;
   First_Dedicated_Group : constant C.int := 128;
   Last_Group            : constant C.int := 255;

   subtype Pool_Size is C.int range 1 .. First_Dedicated_Group;

   type Reduction_Phase is
     (No_Reduction, Reduction_Draining, Reduction_Complete);
   type Reduction_Decision is
     (Start_Reduction, Already_At_Or_Below, Reduction_In_Progress);

   --  Compute the grow-only automatic-pool transition used while the
   --  scheduler holds the topology lock.
   function Growth_Target
     (Current   : Pool_Size;
      Requested : Pool_Size) return Pool_Size
   with Inline,
        Post =>
          Growth_Target'Result =
            (if Requested > Current then Requested else Current)
          and then Growth_Target'Result >= Current
          and then Growth_Target'Result >= Requested;

   --  Repeating a growth request cannot change its first result.
   procedure Lemma_Growth_Idempotent
     (Current   : Pool_Size;
      Requested : Pool_Size)
   with Ghost,
        Post =>
          Growth_Target
            (Growth_Target (Current, Requested), Requested) =
          Growth_Target (Current, Requested);

   --  Serialized concurrent requests converge regardless of lock order.
   procedure Lemma_Growth_Converges
     (Current : Pool_Size;
      Left    : Pool_Size;
      Right   : Pool_Size)
   with Ghost,
        Post =>
          Growth_Target (Growth_Target (Current, Left), Right) =
          Growth_Target (Growth_Target (Current, Right), Left);

   --  Serialize reduction requests and start only a strict decrease.
   function Plan_Reduction
     (Current   : Pool_Size;
      Requested : Pool_Size;
      Phase     : Reduction_Phase) return Reduction_Decision
   with Inline,
        Post =>
          Plan_Reduction'Result =
            (if Phase = Reduction_Draining then Reduction_In_Progress
             elsif Requested >= Current then Already_At_Or_Below
             else Start_Reduction);

   --  A reduction is drained only after every pre-cutover automatic placement
   --  claim and every automatically placed task outside the target is gone.
   function Reduction_Drained
     (Automatic_Tasks : Natural;
      Placement_Claims : Natural) return Boolean
   with Inline,
        Post =>
          Reduction_Drained'Result =
            (Automatic_Tasks = 0 and then Placement_Claims = 0);

   --  Start in the complete phase when no migration or pre-cutover creation
   --  remains; otherwise publish the draining phase and its destination.
   function Reduction_Start_Phase
     (Automatic_Tasks  : Natural;
      Placement_Claims : Natural) return Reduction_Phase
   with Inline,
        Post =>
          Reduction_Start_Phase'Result =
            (if Reduction_Drained (Automatic_Tasks, Placement_Claims) then
                Reduction_Complete
             else
                Reduction_Draining)
          and then Reduction_Start_Phase'Result /= No_Reduction;

   --  Select only movable, automatically placed ready work owned by a shared
   --  group that is now outside the automatic-placement ceiling.
   function Should_Drain
     (Phase                 : Reduction_Phase;
      Source                : C.int;
      Target                : Pool_Size;
      Automatic_Placement   : Boolean;
      Pinned                : Boolean;
      Can_Migrate           : Boolean;
      Destination_Available : Boolean) return Boolean
   with Inline,
        Post =>
          Should_Drain'Result =
            (Phase = Reduction_Draining
             and then Source >= Target
             and then Source < First_Dedicated_Group
             and then Automatic_Placement
             and then not Pinned
             and then Can_Migrate
             and then Destination_Available);

   function Valid_Group (Group : C.int) return Boolean
   with Inline,
        Post =>
          Valid_Group'Result =
            (Group >= First_Shared_Group and then Group <= Last_Group);

   function Shared_Group (Group : C.int) return Boolean
   with Inline,
        Post =>
          Shared_Group'Result =
            (Group >= First_Shared_Group
             and then Group < First_Dedicated_Group);

   function Dedicated_Group (Group : C.int) return Boolean
   with Inline,
        Post =>
          Dedicated_Group'Result =
            (Group >= First_Dedicated_Group and then Group <= Last_Group);

   function Dedicated_Available
     (Member_Count : Natural;
      Reserved     : Boolean) return Boolean
   with Inline,
        Post =>
          Dedicated_Available'Result =
            (Member_Count = 0 and then not Reserved);

   function Migration_Allowed
     (Can_Migrate         : Boolean;
      Target_Dedicated    : Boolean;
      Target_Member_Count : Natural;
      Reservation_Matches : Boolean) return Boolean
   with Inline,
        Post =>
          Migration_Allowed'Result =
            (Can_Migrate
             and then
               (not Target_Dedicated
                or else
                  (Target_Member_Count = 0
                   and then Reservation_Matches)));

   function Should_Reap_After_Switch
     (Phase             : Fiber_Phase;
      Destroy_Requested : Boolean) return Boolean
   with Inline,
        Post =>
          Should_Reap_After_Switch'Result =
            (Phase = Finished and then Destroy_Requested);

   function Maintenance_Due
     (Ready_Present              : Boolean;
      Dispatches_Until_Check     : Natural) return Boolean
   with Inline,
        Post =>
          Maintenance_Due'Result =
            (not Ready_Present or else Dispatches_Until_Check = 0);

   function After_Dispatch
     (Dispatches_Until_Check : Positive) return Natural
   with Inline,
        Post =>
          After_Dispatch'Result = Dispatches_Until_Check - 1;

   function Earlier_Deadline (Left, Right : Duration) return Duration
   with Post =>
     (if Left < 0.0 then
         Earlier_Deadline'Result = Right
      elsif Right < 0.0 then
         Earlier_Deadline'Result = Left
      elsif Left <= Right then
         Earlier_Deadline'Result = Left
      else
         Earlier_Deadline'Result = Right);

   function Classify_Deadline
     (Deadline : Duration;
      Now      : Duration) return Deadline_Status
   with Post =>
     (if Deadline < 0.0 then
         Classify_Deadline'Result = No_Deadline_Set
      elsif Deadline <= Now then
         Classify_Deadline'Result = Expired
      else
         Classify_Deadline'Result = Pending);

   function Time_Until
     (Deadline : Duration;
      Now      : Duration) return Duration
   with Post =>
     (if Deadline < 0.0 then
         Time_Until'Result = No_Deadline
      elsif Now <= 0.0 then
         Time_Until'Result = Deadline
      elsif Deadline <= Now then
         Time_Until'Result = 0.0
      else
         Time_Until'Result = Deadline - Now);

   --  Return the parent position in a one-based binary heap.
   function Heap_Parent (Position : Positive) return Positive
   with Pre  => Position > 1,
        Post => Heap_Parent'Result = Position / 2
          and then Heap_Parent'Result < Position;

   --  Report whether Position has at least one child within Count elements.
   function Heap_Has_Child
     (Position : Positive;
      Count    : Natural) return Boolean
   with Post =>
     Heap_Has_Child'Result = (Position <= Count / 2);

   --  Return the first child of Position within a one-based binary heap.
   function Heap_First_Child
     (Position : Positive;
      Count    : Natural) return Positive
   with Pre  => Position <= Count / 2,
        Post => Heap_First_Child'Result = Position * 2
          and then Heap_First_Child'Result <= Count;

   --  Map a nonnegative descriptor to one zero-based wait-table bucket.
   function Descriptor_Bucket
     (Descriptor   : Natural;
      Bucket_Count : Positive) return Natural
   with Post => Descriptor_Bucket'Result < Bucket_Count;

end System.Flyology.Scheduling_Policy;
