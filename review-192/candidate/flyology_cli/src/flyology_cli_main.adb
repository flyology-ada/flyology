with Ada.Command_Line;
with Ada.Text_IO;
with Flyology_CLI.Init;
with Flyology_CLI.Processes;

procedure Flyology_CLI_Main is
   use Flyology_CLI.Processes;

   procedure Show_Help is
   begin
      Ada.Text_IO.Put_Line ("Flyology project tool");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Usage: flyology <command> [arguments]");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Commands:");
      Ada.Text_IO.Put_Line ("  init    Scaffold a Flyology project");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Additional commands are discovered as flyology-<command> on PATH.");
   end Show_Help;
begin
   if Ada.Command_Line.Argument_Count = 0 then
      Show_Help;
   elsif Ada.Command_Line.Argument (1) in "--help" | "-h" | "help" then
      Show_Help;
   elsif Ada.Command_Line.Argument (1) = "--version" then
      Ada.Text_IO.Put_Line (Flyology_CLI.Version);
   elsif Ada.Command_Line.Argument (1) = "init" then
      Flyology_CLI.Init.Run;
   else
      declare
         Command   : constant String := "flyology-" & Ada.Command_Line.Argument (1);
         Arguments : String_Vectors.Vector;
         Status    : Integer;
      begin
         if not Is_Available (Command) then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "flyology: unknown command '" & Ada.Command_Line.Argument (1) & "'");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            return;
         end if;

         for Index in 2 .. Ada.Command_Line.Argument_Count loop
            Arguments.Append (Ada.Command_Line.Argument (Index));
         end loop;
         Status := Run (Command, Arguments);
         if Status < 0 then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         else
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Exit_Status (Status));
         end if;
      end;
   end if;
end Flyology_CLI_Main;
