with Interfaces.C;

package System.Gnatevl.Scheduling_Policy
  with Preelaborate,
       SPARK_Mode
is
   package C renames Interfaces.C;

   use type C.int;
   No_Deadline : constant Duration := -1.0;
   type Deadline_Status is (No_Deadline_Set, Expired, Pending);

   type Fiber_Phase is (Running, Ready, Waiting, Migrating, Finished);
   type Destruction_Plan is (Defer, Reap_Now);

   function Plan_Destroy (Phase : Fiber_Phase) return Destruction_Plan
   with Inline,
        Post =>
          (if Phase in Running | Migrating then
              Plan_Destroy'Result = Defer
           else
              Plan_Destroy'Result = Reap_Now);

   First_Shared_Group    : constant C.int := 0;
   First_Dedicated_Group : constant C.int := 128;
   Last_Group            : constant C.int := 255;

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

end System.Gnatevl.Scheduling_Policy;
