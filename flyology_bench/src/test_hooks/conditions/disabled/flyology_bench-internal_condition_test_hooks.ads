--  Disabled operating-condition test seams selected by the owning project.
--  Imported-only declarations make a missed static guard visible without
--  supplying any production implementation.
with Flyology_Bench.Internal_Conditions;

private package Flyology_Bench.Internal_Condition_Test_Hooks is

   --  Keep this a literal compile-time constant so GNAT removes guarded calls
   --  even at -O0.
   Enabled : constant Boolean := False;

   procedure Supply
     (Value : out Internal_Conditions.Snapshot; Include_Profile : Boolean; Supplied : out Boolean)
   with Import, External_Name => "flyology_bench_disabled_condition_hook_must_be_elided_supply";

end Flyology_Bench.Internal_Condition_Test_Hooks;
