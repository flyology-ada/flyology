with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Interfaces.C;
with Interfaces.C.Strings;

--  Drive the stack-sizing scenarios of Stack_Size_Limits_Child, one child
--  process each. A stack request whose derived arena arithmetic cannot be
--  represented in size_t must be refused by a null Create result, not by a
--  zero-byte stack, a propagating exception, or a fault.
procedure Stack_Size_Limits_Smoke is
   package C renames Interfaces.C;
   package Strings renames Interfaces.C.Strings;

   use type C.int;

   function Run_Child
     (Program  : Strings.chars_ptr;
      Scenario : Strings.chars_ptr) return C.int;
   pragma Import (C, Run_Child, "flyology_test_run_stack_size_child");

   Program : Strings.chars_ptr :=
     Strings.New_String
       (Ada.Directories.Compose
          (Ada.Directories.Containing_Directory
             (Ada.Command_Line.Command_Name),
           "stack_size_limits_child"));

   procedure Run (Scenario : String);

   procedure Run (Scenario : String) is
      Name   : Strings.chars_ptr := Strings.New_String (Scenario);
      Status : constant C.int := Run_Child (Program, Name);
   begin
      Strings.Free (Name);
      if Status /= 0 then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "stack-size scenario " & Scenario
            & " reported status " & Status'Image);
         Strings.Free (Program);
         raise Program_Error with
           "unrepresentable stack size was not refused cleanly";
      end if;
   end Run;
begin
   Run ("round-up-wrap");
   Run ("stride-wrap");
   Run ("mapping-wrap");
   Run ("unmappable");
   Run ("accepted");
   Strings.Free (Program);
end Stack_Size_Limits_Smoke;
