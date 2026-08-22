--  Disabled TLS ownership-transfer test seams selected by the owning project.
--  The imported-only declarations make a missed static guard visible to
--  symbol inspection without supplying any production implementation.
private package Flyology.TLS_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   Barrier_Count : constant := 2;

   function Valid_Point (Point : Integer) return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_tls_valid_point";
   procedure Reset
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_tls_reset";
   procedure Arm (Point : Integer)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_tls_arm";
   procedure Arrive (Point : Integer; Did_Arrive : out Boolean)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_tls_arrive";
   function Reached (Point : Integer) return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_tls_reached";
   function Released (Point : Integer) return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_tls_released";
   procedure Release (Point : Integer)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_tls_release";

end Flyology.TLS_Test_Hooks;
