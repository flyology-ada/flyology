with Ada.Command_Line;
with Ada.Directories;
with Interfaces.C;
with Interfaces.C.Strings;

procedure Stack_Guard_Smoke is
   package C renames Interfaces.C;

   use type C.int;

   function Run_Child (Program : Interfaces.C.Strings.chars_ptr) return C.int;
   pragma Import (C, Run_Child, "flyology_test_run_stack_guard_child");

   Program : Interfaces.C.Strings.chars_ptr :=
     Interfaces.C.Strings.New_String
       (Ada.Directories.Compose
          (Ada.Directories.Containing_Directory (Ada.Command_Line.Command_Name),
           "stack_guard_violation_child"));
begin
   if Run_Child (Program) /= 0 then
      Interfaces.C.Strings.Free (Program);
      raise Program_Error with "sparse stack jump escaped the inter-slot guard";
   end if;
   Interfaces.C.Strings.Free (Program);
end Stack_Guard_Smoke;
