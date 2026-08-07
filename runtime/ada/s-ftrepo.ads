with Interfaces;

package System.Flyology.Task_Result_Policy
  with Preelaborate,
       SPARK_Mode
is
   use type Interfaces.Unsigned_32;

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

   --  Outcomes the Convention-C observation and wait entry points report.
   --  Runtime_Failure covers a request the runtime could not carry out at all,
   --  such as a completion gate finalized while this caller was queued on it.
   --  It exists so those bodies can report a code instead of letting an Ada
   --  exception cross the language boundary.
   type Request_Outcome is
     (Runtime_Failure,
      Malformed_Request,
      Unknown_Task,
      Not_Terminal,
      Terminal);

   subtype Request_Code is Integer range -3 .. 1;

   function Outcome_Code (Outcome : Request_Outcome) return Request_Code
   with
     Contract_Cases =>
       (Outcome = Runtime_Failure   => Outcome_Code'Result = -3,
        Outcome = Malformed_Request => Outcome_Code'Result = -2,
        Outcome = Unknown_Task      => Outcome_Code'Result = -1,
        Outcome = Not_Terminal      => Outcome_Code'Result = 0,
        Outcome = Terminal          => Outcome_Code'Result = 1),
     Post =>
       (Outcome_Code'Result in 0 .. 1) =
         (Outcome in Not_Terminal | Terminal);

   subtype Reference_Count is Interfaces.Unsigned_32;

   function Retain_Allowed (References : Reference_Count) return Boolean is
     (References in 1 .. Reference_Count'Last - 1);

   function After_Retain
     (References : Reference_Count) return Reference_Count
   with
     Pre  => Retain_Allowed (References),
     Post => After_Retain'Result = References + 1
       and then After_Retain'Result > References;

   function Release_Allowed (References : Reference_Count) return Boolean is
     (References > 0);

   function After_Release
     (References : Reference_Count) return Reference_Count
   with
     Pre  => Release_Allowed (References),
     Post => After_Release'Result = References - 1
       and then After_Release'Result < References;

end System.Flyology.Task_Result_Policy;
