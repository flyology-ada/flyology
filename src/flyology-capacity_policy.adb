package body Flyology.Capacity_Policy
  with SPARK_Mode
is
   function Classify_Acquire
     (Stopping : Boolean;
      Active   : Natural;
      Capacity : Positive) return Acquire_Action
   is
     (if Stopping then Reject_Closed
      elsif Active = Capacity then Wait_For_Permit
      else Admit_Permit);

   function Acquire_Entry_Open
     (Stopping : Boolean;
      Active   : Natural;
      Capacity : Positive) return Boolean
   is
     (Stopping or else Active < Capacity);

   function Active_After_Acquire
     (Active   : Natural;
      Capacity : Positive) return Positive
   is
     (Active + 1);

   function Release_Allowed (Active : Natural) return Boolean is
     (Active > 0);

   function Active_After_Release (Active : Positive) return Natural is
     (Active - 1);

   function Is_Drained
     (Stopping : Boolean;
      Active   : Natural) return Boolean
   is
     (Stopping and then Active = 0);
end Flyology.Capacity_Policy;
