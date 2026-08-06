package System.Flyology.Task_Result_Policy
  with Preelaborate,
       SPARK_Mode
is
   type Phase is (Running, Terminal);

   type Event is
     (Complete_Normally,
      Complete_With_Exception,
      Complete_Abnormally);

   function Next (State : Phase; Occurrence : Event) return Phase
   with
     Pre  => State = Running,
     Post => Next'Result = Terminal;

   subtype Encoded_Cause is Natural range 0 .. 2;

   function Cause_Code (Occurrence : Event) return Encoded_Cause
   with
     Post =>
       Cause_Code'Result =
         (case Occurrence is
             when Complete_Normally       => 0,
             when Complete_Abnormally     => 1,
             when Complete_With_Exception => 2);

end System.Flyology.Task_Result_Policy;
