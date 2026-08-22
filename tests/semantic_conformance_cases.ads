with System.Task_Info;

generic
   Server_Model : System.Task_Info.Task_Info_Type;
   Caller_Model : System.Task_Info.Task_Info_Type;
package Semantic_Conformance_Cases is

   type Check_Id is
     (Rendezvous_Exception, Activation_Failure_Cleanup, Requeue_With_Abort, Requeue_Without_Abort);

   type Results is array (Check_Id) of Boolean;

   function Run return Results;

end Semantic_Conformance_Cases;
