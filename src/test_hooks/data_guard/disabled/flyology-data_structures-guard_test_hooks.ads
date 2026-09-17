with Flyology.Data_Structures.Layouts;
with System;

private package Flyology.Data_Structures.Guard_Test_Hooks
  with Preelaborate
is
   --  Literal Enabled : constant Boolean := False; removes every guarded call at -O0.
   Enabled : constant Boolean := False;
   type Observer is access procedure (Core : Layouts.Local_View; Guard : System.Address);
   procedure Reset
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_data_guard_reset";
   procedure Set_Observer (Value : Observer)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_data_guard_set";
   procedure After_CAS (Core : Layouts.Local_View; Guard : System.Address)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_data_guard_after_cas";
end Flyology.Data_Structures.Guard_Test_Hooks;
