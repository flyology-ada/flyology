with System.Task_Info;

generic
   Model      : System.Task_Info.Task_Info_Type;
   Peer_Model : System.Task_Info.Task_Info_Type;
package Semantic_Scenarios is

   type Check_Id is
     (Conditional_Entry,
      Timed_Entry,
      Select_Delay,
      Select_Terminate,
      Requeued_Entry,
      Abortable_Select,
      Suspension_Object,
      Task_Attribute,
      Dynamic_Priority,
      Nested_Master,
      Access_Task_Master,
      Abort_Activation,
      Abort_Delay,
      Abort_Entry_Wait,
      Abort_Finalization,
      Cross_Lane_Rendezvous);

   type Results is array (Check_Id) of Boolean;

   function Run return Results;

end Semantic_Scenarios;
