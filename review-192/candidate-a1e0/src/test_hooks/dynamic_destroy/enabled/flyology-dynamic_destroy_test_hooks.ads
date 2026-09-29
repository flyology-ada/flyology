--  Enabled dynamic-destroy fault injection selected by the owning project.
--  Production selects an imported-only specification and statically removes
--  every guarded reference.

private package Flyology.Dynamic_Destroy_Test_Hooks
  with Preelaborate
is

   --  Keep this a literal compile-time constant so GNAT removes every guarded
   --  reference even at -O0.
   Enabled : constant Boolean := True;

   --  Clear the one-shot contention injection.
   procedure Reset;

   --  Make the next current-allocation release report arena contention.
   procedure Arm_Current_Release_Contention;

   --  Consume one armed current-allocation release contention.
   procedure Consume_Current_Release_Contention (Armed : out Boolean);

end Flyology.Dynamic_Destroy_Test_Hooks;
