with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology.Subprocesses;
with Flyology.Subprocesses.Capture;

--  Require native and lightweight tasks to retain an alternate signal stack,
--  give lightweight tasks only their requested usable stack, and translate a
--  real stack overflow to Storage_Error. Each scenario has a bounded child
--  process because the regression kills the whole process.

procedure Stack_Overflow_Smoke is
   package Subprocesses renames Flyology.Subprocesses;
   package Capture renames Flyology.Subprocesses.Capture;

   use type Subprocesses.Exit_Kind;

   Program : constant String :=
     Ada.Directories.Compose
       (Ada.Directories.Containing_Directory
          (Ada.Directories.Full_Name (Ada.Command_Line.Command_Name)),
        "stack_overflow_child");

   --  Preserve the removed runner's five-second isolation deadline. This is a
   --  test-resource bound, not a runtime timing guarantee.
   Scenario_Timeout : constant Duration := 5.0;

   Failed : Boolean := False;

   procedure Run (Scenario : String);

   procedure Run (Scenario : String) is
      Command : Subprocesses.Command := Subprocesses.To_Command (Program);
   begin
      Subprocesses.Append_Argument (Command, Scenario);
      declare
         Result : constant Capture.Result :=
           Capture.Run (Command, Timeout => Scenario_Timeout);
         Status : constant Subprocesses.Exit_Status := Capture.Status (Result);
         Error  : constant String := Capture.Standard_Error (Result);
      begin
         if Error'Length > 0 then
            Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, Error);
         end if;
         if not Subprocesses.Successful (Status) then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "stack-overflow scenario "
               & Scenario
               & (if Status.Kind = Subprocesses.Exited
                  then " exited with status" & Status.Code'Image
                  else " received signal" & Status.Signal'Image));
            Failed := True;
         end if;
      end;
   exception
      when Occurrence : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "stack-overflow scenario "
            & Scenario
            & " failed: "
            & Ada.Exceptions.Exception_Information (Occurrence));
         Failed := True;
   end Run;
begin
   Run ("observe-lightweight");
   Run ("observe-lightweight-size");
   Run ("overflow-lightweight");
   Run ("observe-native");
   Run ("overflow-native");
   if Failed then
      raise Program_Error
        with "task stack or alternate signal stack behavior was incorrect";
   end if;
end Stack_Overflow_Smoke;
