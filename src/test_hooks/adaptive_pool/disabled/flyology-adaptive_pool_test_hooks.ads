--  Disabled adaptive-pool lifecycle observations selected by the owning
--  project. Imported-only declarations make a missed static guard visible to
--  symbol inspection without supplying a production implementation.

private package Flyology.Adaptive_Pool_Test_Hooks
  with Preelaborate
is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   procedure Reset
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_adaptive_pool_reset";
   procedure Record_Chunk_State (Chunk : Positive; Live : Boolean)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_adaptive_pool_record";
   function Chunk_Is_Live (Chunk : Positive) return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_adaptive_pool_state";

end Flyology.Adaptive_Pool_Test_Hooks;
