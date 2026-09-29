--  Disabled DNS test observations selected by the owning project. The
--  imported-only declarations make a missed static guard visible to symbol
--  inspection without supplying any production implementation.
private package Flyology.DNS_Test_Observations is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   procedure Reset
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_dns_reset";
   procedure Record_Receive_Wait (After_Close : Boolean)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_dns_record";
   function Post_Close_Receive_Waits return Natural
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_dns_count";

end Flyology.DNS_Test_Observations;
