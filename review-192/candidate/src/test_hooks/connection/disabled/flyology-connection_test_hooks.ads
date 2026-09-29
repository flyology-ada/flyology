with Interfaces.C;

--  Disabled connection test seams selected by the owning project. The
--  imported-only declarations make a missed static guard visible to symbol
--  inspection without supplying any production implementation.
private package Flyology.Connection_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   procedure Barrier (Point : Interfaces.C.int)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_connection_barrier";
   procedure One_Shot_Barrier (Point : Interfaces.C.int)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_connection_one_shot";
   function Receive_Limit (Requested : Interfaces.C.int) return Interfaces.C.int
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_connection_receive_limit";
   procedure Raw_Accept_Return_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_connection_raw_accept";
   function Fail_Next_Capacity_Release_Wake return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_connection_capacity_wake";

end Flyology.Connection_Test_Hooks;
