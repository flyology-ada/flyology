package body System.Gnatevl.Scheduling_Policy
  with SPARK_Mode
is
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

   function Before (Left, Right : Ready_Key) return Boolean is
     (Left.Priority > Right.Priority
      or else
        (Left.Priority = Right.Priority
         and then Left.Sequence < Right.Sequence));

   procedure Lemma_Irreflexive (Key : Ready_Key) is null;

   procedure Lemma_Asymmetric (Left, Right : Ready_Key) is null;

   procedure Lemma_Transitive (Left, Middle, Right : Ready_Key) is null;

end System.Gnatevl.Scheduling_Policy;
