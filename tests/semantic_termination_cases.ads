with System.Task_Info;

generic
   Label         : String;
   Subject_Model : System.Task_Info.Task_Info_Type;
   Peer_Model    : System.Task_Info.Task_Info_Type;
package Semantic_Termination_Cases is

   type Check_Id is
     (Entry_Family,
      Terminated_Entry_Call,
      Failed_Entry_Call,
      Partial_Activation_Failure,
      Abort_Active_Rendezvous,
      Nested_Asynchronous_Transfer,
      Termination_Handlers);

   type Results is array (Check_Id) of Boolean;

   function Run return Results;

end Semantic_Termination_Cases;
