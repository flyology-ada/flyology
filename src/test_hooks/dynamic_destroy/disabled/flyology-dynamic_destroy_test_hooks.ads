--  Disabled dynamic-destroy fault injection selected by the owning project.
--  Imported-only declarations expose any reference that survives the literal
--  static guard in a production build.

private package Flyology.Dynamic_Destroy_Test_Hooks
  with Preelaborate
is

   --  Keep this a literal compile-time constant so GNAT removes every guarded
   --  reference even at -O0.
   Enabled : constant Boolean := False;

   procedure Reset
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_dynamic_destroy_reset";
   procedure Arm_Current_Release_Contention
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_dynamic_destroy_arm_current";
   procedure Consume_Current_Release_Contention (Armed : out Boolean)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_dynamic_destroy_consume_current";

end Flyology.Dynamic_Destroy_Test_Hooks;
