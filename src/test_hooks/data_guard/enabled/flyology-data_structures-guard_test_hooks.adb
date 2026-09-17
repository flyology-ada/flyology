package body Flyology.Data_Structures.Guard_Test_Hooks is
   Current : Observer := null;
   procedure Reset is
   begin
      Current := null;
   end Reset;
   procedure Set_Observer (Value : Observer) is
   begin
      Current := Value;
   end Set_Observer;
   procedure After_CAS (Core : Layouts.Local_View; Guard : System.Address) is
   begin
      if Current /= null then
         Current.all (Core, Guard);
      end if;
   end After_CAS;
end Flyology.Data_Structures.Guard_Test_Hooks;
