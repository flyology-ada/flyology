package body Flyology.Native_Executor_Policy
  with SPARK_Mode
is
   function Terminal_Report_Allowed (State : Slot_State) return Boolean
   is (State = Running);

   function State_After_Report (Relinquished : Boolean) return Slot_State
   is (if Relinquished then Free else Completed);

   function Running_After_Report (Running : Positive) return Natural
   is (Running - 1);

   function Outstanding_After_Report (Outstanding : Positive; Relinquished : Boolean) return Natural
   is (if Relinquished then Outstanding - 1 else Outstanding);
end Flyology.Native_Executor_Policy;
