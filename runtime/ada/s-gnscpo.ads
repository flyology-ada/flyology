with Interfaces.C;

package System.Gnatevl.Scheduling_Policy
  with Preelaborate,
       SPARK_Mode
is
   package C renames Interfaces.C;

   use type C.int;
   use type C.unsigned_long;

   type Ready_Key is record
      Priority : C.int;
      Sequence : C.unsigned_long;
   end record;

   No_Deadline : constant Duration := -1.0;
   type Deadline_Status is (No_Deadline_Set, Expired, Pending);

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

   function Before (Left, Right : Ready_Key) return Boolean
   with Inline,
        Post =>
          Before'Result =
            (Left.Priority > Right.Priority
             or else
               (Left.Priority = Right.Priority
                and then Left.Sequence < Right.Sequence));

   procedure Lemma_Irreflexive (Key : Ready_Key)
   with Ghost,
        Global => null,
        Post   => not Before (Key, Key);

   procedure Lemma_Asymmetric (Left, Right : Ready_Key)
   with Ghost,
        Global => null,
        Pre    => Before (Left, Right),
        Post   => not Before (Left => Right, Right => Left);

   procedure Lemma_Transitive (Left, Middle, Right : Ready_Key)
   with Ghost,
        Global => null,
        Pre    => Before (Left, Middle) and then Before (Middle, Right),
        Post   => Before (Left, Right);

end System.Gnatevl.Scheduling_Policy;
