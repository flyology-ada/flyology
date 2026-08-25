package body Prepared_Admission_Lifetime_Support is
   procedure Run_Generation
     (State   : aliased in out Context;
      Input   : Request;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      pragma Unreferenced (State, Input, Control, Result);
   begin
      raise Program_Error with "compile-only lifetime fixture";
   end Run_Generation;
end Prepared_Admission_Lifetime_Support;
