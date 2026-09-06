with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Interfaces.C;
with Interfaces.C.Strings;

--  Require native and lightweight tasks to retain an alternate signal stack,
--  give lightweight tasks only their requested usable stack, and translate a
--  real stack overflow to Storage_Error. Each scenario has a bounded child
--  process because the regression kills the whole process.

procedure Stack_Overflow_Smoke is
   package C renames Interfaces.C;
   package Strings renames Interfaces.C.Strings;

   use type C.int;

   function Run_Child
     (Program : Strings.chars_ptr; Scenario : Strings.chars_ptr) return C.int;
   pragma Import (C, Run_Child, "flyology_test_run_stack_overflow_child");

   Program : Strings.chars_ptr :=
     Strings.New_String
       (Ada.Directories.Compose
          (Ada.Directories.Containing_Directory
             (Ada.Command_Line.Command_Name),
           "stack_overflow_child"));

   Failed : Boolean := False;

   procedure Run (Scenario : String);

   procedure Run (Scenario : String) is
      Name   : Strings.chars_ptr := Strings.New_String (Scenario);
      Status : constant C.int := Run_Child (Program, Name);
   begin
      Strings.Free (Name);
      if Status /= 0 then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "stack-overflow scenario "
            & Scenario
            & " reported status "
            & Status'Image);
         Failed := True;
      end if;
   end Run;
begin
   Run ("observe-lightweight");
   Run ("observe-lightweight-size");
   Run ("overflow-lightweight");
   Run ("observe-native");
   Run ("overflow-native");
   Strings.Free (Program);
   if Failed then
      raise Program_Error
        with "task stack or alternate signal stack behavior was incorrect";
   end if;
end Stack_Overflow_Smoke;
