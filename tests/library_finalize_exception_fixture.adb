package body Library_Finalize_Exception_Fixture is

   Armed : Boolean := False;

   procedure Arm is
   begin
      Armed := True;
   end Arm;

   overriding
   procedure Finalize (Item : in out Probe) is
      pragma Unreferenced (Item);
   begin
      if Armed then
         raise Program_Error with "issue 158 finalization sentinel";
      end if;
   end Finalize;

end Library_Finalize_Exception_Fixture;
