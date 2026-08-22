package body Flyology.Task_Scope_Policy
  with SPARK_Mode
is
   function Awaited_Workers (Created : Natural; Activated : Natural) return Natural
   is (Activated);

   function Unstarted_Workers (Created : Natural; Activated : Natural) return Natural
   is (Created - Activated);

   function First_Unstarted (Created : Natural; Activated : Natural) return Positive
   is (Activated + 1);

   function Last_Unstarted (Created : Natural; Activated : Natural) return Natural
   is (Created);

   function Accounts_For_Every_Worker (Created : Natural; Activated : Natural) return Boolean
   is (True);
end Flyology.Task_Scope_Policy;
