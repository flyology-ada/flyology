--  Internal, proved state decisions for bounded permit gates. Protected-entry
--  serialization and wake-source ownership remain in Flyology.Capacity.
private package Flyology.Capacity_Policy
  with Preelaborate,
       SPARK_Mode
is
   --  Result of classifying one permit acquisition attempt.
   type Acquire_Action is
     (Admit_Permit, Wait_For_Permit, Reject_Closed);

   --  Distinguish admission, capacity wait, and terminal rejection.
   function Classify_Acquire
     (Stopping : Boolean;
      Active   : Natural;
      Capacity : Positive) return Acquire_Action
   with Pre  => Active <= Capacity,
        Post =>
          (if Stopping then
              Classify_Acquire'Result = Reject_Closed
           elsif Active = Capacity then
              Classify_Acquire'Result = Wait_For_Permit
           else
              Classify_Acquire'Result = Admit_Permit);

   --  Open the protected entry for either admission or terminal rejection.
   function Acquire_Entry_Open
     (Stopping : Boolean;
      Active   : Natural;
      Capacity : Positive) return Boolean
   with Pre  => Active <= Capacity,
        Post => Acquire_Entry_Open'Result =
          (Stopping or else Active < Capacity);

   --  Increment the active count without exceeding the configured capacity.
   function Active_After_Acquire
     (Active   : Natural;
      Capacity : Positive) return Positive
   with Pre  => Active < Capacity,
        Post => Active_After_Acquire'Result = Active + 1
          and then Active_After_Acquire'Result <= Capacity;

   --  Reject unmatched or duplicate releases.
   function Release_Allowed (Active : Natural) return Boolean
   with Post => Release_Allowed'Result = (Active > 0);

   --  Decrement a nonzero active count.
   function Active_After_Release (Active : Positive) return Natural
   with Post => Active_After_Release'Result = Active - 1;

   --  Open the drain barrier only after terminal shutdown reaches zero.
   function Is_Drained
     (Stopping : Boolean;
      Active   : Natural) return Boolean
   with Post => Is_Drained'Result = (Stopping and then Active = 0);
end Flyology.Capacity_Policy;
