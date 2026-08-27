--  Disabled channel test seams selected by the owning project. The
--  imported-only declarations make a missed static guard visible to symbol
--  inspection without supplying any production implementation.

private package Flyology.Channel_Test_Hooks is
   pragma Preelaborate;

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   procedure Reset
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_reset";
   procedure Arm_Before_Send
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_arm";
   procedure Before_Send_Barrier
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_barrier";
   function Before_Send_Reached return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_reached";
   procedure Release_Before_Send
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_channel_release";

end Flyology.Channel_Test_Hooks;
