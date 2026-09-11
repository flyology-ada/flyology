with Ada.Command_Line;
with Flyology.Observability;

package body Library_Finalize_Runtime_Fixture is

   Armed : Boolean := False;

   procedure Arm is
   begin
      Armed := True;
   end Arm;

   overriding
   procedure Finalize (Item : in out Probe) is
      pragma Unreferenced (Item);

      Sample : Flyology.Observability.Group_Snapshot;
   begin
      if Armed and then not Flyology.Observability.Snapshot (1, Sample) then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end Finalize;

end Library_Finalize_Runtime_Fixture;
