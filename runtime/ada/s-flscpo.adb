package body System.Flyology.Scheduling_Policy
  with SPARK_Mode
is
   function Plan_File_Cancel
     (File_Waiting       : Boolean;
      Submission_Pending : Boolean;
      Already_Attempted  : Boolean) return File_Cancel_Plan
   is
     (if not File_Waiting or else Already_Attempted then Ignore_Cancel
      elsif Submission_Pending then Complete_Pending
      else Request_Kernel_Cancel);

   function Placement_After_Priority_Update
     (Loss_Of_Inheritance : Boolean) return Ready_Placement
   is
     (if Loss_Of_Inheritance then Queue_Head else Queue_Tail);

   function Plan_Destroy (Phase : Fiber_Phase) return Destruction_Plan is
     (if Phase in Running | Migrating then Defer else Reap_Now);

   function Creation_Admitted (Lifecycle : C.int) return Boolean is
     (Lifecycle in 0 | 1);

   function Teardown_Admitted
     (Lifecycle          : C.int;
      Registry_Quiescent : Boolean;
      Outstanding_Claims : Natural) return Boolean
   is
     (Lifecycle = 2
      and then Registry_Quiescent
      and then Outstanding_Claims = 0);

   procedure Lemma_Creation_Excludes_Teardown
     (Lifecycle          : C.int;
      Registry_Quiescent : Boolean;
      Outstanding_Claims : Natural)
   is null;

   function Growth_Target
     (Current   : Pool_Size;
      Requested : Pool_Size) return Pool_Size
   is
     (if Requested > Current then Requested else Current);

   procedure Lemma_Growth_Idempotent
     (Current   : Pool_Size;
      Requested : Pool_Size)
   is null;

   procedure Lemma_Growth_Converges
     (Current : Pool_Size;
      Left    : Pool_Size;
      Right   : Pool_Size)
   is null;

   function Valid_Group (Group : C.int) return Boolean is
     (Group >= First_Shared_Group and then Group <= Last_Group);

   function Shared_Group (Group : C.int) return Boolean is
     (Group >= First_Shared_Group and then Group < First_Dedicated_Group);

   function Dedicated_Group (Group : C.int) return Boolean is
     (Group >= First_Dedicated_Group and then Group <= Last_Group);

   function Dedicated_Available
     (Member_Count : Natural;
      Reserved     : Boolean) return Boolean
   is
     (Member_Count = 0 and then not Reserved);

   function Migration_Allowed
     (Can_Migrate         : Boolean;
      Target_Dedicated    : Boolean;
      Target_Member_Count : Natural;
      Reservation_Matches : Boolean) return Boolean
   is
     (Can_Migrate
      and then
        (not Target_Dedicated
         or else
           (Target_Member_Count = 0 and then Reservation_Matches)));

   function Should_Reap_After_Switch
     (Phase             : Fiber_Phase;
      Destroy_Requested : Boolean) return Boolean
   is
     (Phase = Finished and then Destroy_Requested);

   function Maintenance_Due
     (Ready_Present          : Boolean;
      Dispatches_Until_Check : Natural) return Boolean
   is
     (not Ready_Present or else Dispatches_Until_Check = 0);

   function After_Dispatch
     (Dispatches_Until_Check : Positive) return Natural
   is
     (Dispatches_Until_Check - 1);

   function Earlier_Deadline (Left, Right : Duration) return Duration is
   begin
      if Left < 0.0 then
         return Right;
      elsif Right < 0.0 or else Left <= Right then
         return Left;
      else
         return Right;
      end if;
   end Earlier_Deadline;

   function Classify_Deadline
     (Deadline : Duration;
      Now      : Duration) return Deadline_Status
   is
   begin
      if Deadline < 0.0 then
         return No_Deadline_Set;
      elsif Deadline <= Now then
         return Expired;
      else
         return Pending;
      end if;
   end Classify_Deadline;

   function Time_Until
     (Deadline : Duration;
      Now      : Duration) return Duration
   is
   begin
      if Deadline < 0.0 then
         return No_Deadline;
      elsif Now <= 0.0 then
         return Deadline;
      elsif Deadline <= Now then
         return 0.0;
      else
         return Deadline - Now;
      end if;
   end Time_Until;

   function Heap_Parent (Position : Positive) return Positive is
     (Position / 2);

   function Heap_Has_Child
     (Position : Positive;
      Count    : Natural) return Boolean
   is
     (Position <= Count / 2);

   function Heap_First_Child
     (Position : Positive;
      Count    : Natural) return Positive
   is
      pragma Unreferenced (Count);
   begin
      return Position * 2;
   end Heap_First_Child;

   function Descriptor_Bucket
     (Descriptor   : Natural;
      Bucket_Count : Positive) return Natural
   is
     (Descriptor mod Bucket_Count);

end System.Flyology.Scheduling_Policy;
