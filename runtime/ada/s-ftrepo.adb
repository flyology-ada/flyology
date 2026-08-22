package body System.Flyology.Task_Result_Policy
  with SPARK_Mode
is
   function Next (State : Phase; Occurrence : Event) return Phase is
      pragma Unreferenced (State, Occurrence);
   begin
      return Terminal;
   end Next;

   function Cause_Code (Occurrence : Event) return Encoded_Cause
   is (case Occurrence is
         when Complete_Normally       => 0,
         when Complete_Abnormally     => 1,
         when Complete_With_Exception => 2);

   function Outcome_Code (Outcome : Request_Outcome) return Request_Code
   is (case Outcome is
         when Runtime_Failure   => -3,
         when Malformed_Request => -2,
         when Unknown_Task      => -1,
         when Not_Terminal      => 0,
         when Terminal          => 1);

   function After_Retain (References : Reference_Count) return Reference_Count
   is (References + 1);

   function After_Release (References : Reference_Count) return Reference_Count
   is (References - 1);
end System.Flyology.Task_Result_Policy;
