package body System.Flyology.Task_Result_Policy
  with SPARK_Mode
is
   function Next (State : Phase; Occurrence : Event) return Phase is
      pragma Unreferenced (State, Occurrence);
   begin
      return Terminal;
   end Next;

   function Cause_Code (Occurrence : Event) return Encoded_Cause is
     (case Occurrence is
         when Complete_Normally       => 0,
         when Complete_Abnormally     => 1,
         when Complete_With_Exception => 2);
end System.Flyology.Task_Result_Policy;
