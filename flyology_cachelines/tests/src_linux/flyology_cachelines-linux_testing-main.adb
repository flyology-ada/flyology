with Ada.Command_Line;
with Ada.Text_IO;

procedure Flyology_Cachelines.Linux_Testing.Main is
   Fixture_Root : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1)
      else "");
begin
   Run (Fixture_Root);
   Ada.Text_IO.Put_Line
     ("Linux sysconf, sysfs, and core-class detection tests passed"
      & (if Fixture_Root = "" then " (no fixtures)" else " with fixtures"));
end Flyology_Cachelines.Linux_Testing.Main;
