with Ada.Command_Line;
with Ada.Text_IO;

procedure Flyology_NUMA.Fixture_Testing.Main is
begin
   if Ada.Command_Line.Argument_Count < 1 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "usage: " & Ada.Command_Line.Command_Name & " <fixture-root>");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Run (Ada.Command_Line.Argument (1));
end Flyology_NUMA.Fixture_Testing.Main;
