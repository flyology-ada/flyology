with Gnatevl;
with Interfaces.C;

procedure Sanitizer_Stack_Violation is
   procedure Trigger (Index : Interfaces.C.unsigned);
   pragma Import
     (C, Trigger, "gnatevl_sanitizer_trigger_stack_violation");

   task Victim is
      pragma Task_Info (Gnatevl.Event_Loop_Task);
      pragma Storage_Size (64 * 1_024);
   end Victim;

   task body Victim is
   begin
      Trigger (16);
   end Victim;
begin
   null;
end Sanitizer_Stack_Violation;
