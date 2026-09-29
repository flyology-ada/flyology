--  Enabled adaptive-pool lifecycle observations selected by the owning
--  project. Production selects an imported-only specification and statically
--  removes every guarded reference.

private package Flyology.Adaptive_Pool_Test_Hooks
  with Preelaborate
is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   --  Clear the two-chunk conformance fixture's lifecycle observations.
   procedure Reset;

   --  Make an adaptive chunk release report arena contention after the given
   --  number of successful release attempts.
   procedure Arm_Release_Contention (After_Releases : Natural := 0);

   --  Consume one armed adaptive chunk-release contention.
   procedure Consume_Release_Contention (Armed : out Boolean);

   --  Record one chunk lifecycle transition while the pool guard is owned.
   procedure Record_Chunk_State (Chunk : Positive; Live : Boolean);

   --  Report the last guarded lifecycle state for one modeled chunk.
   function Chunk_Is_Live (Chunk : Positive) return Boolean;

end Flyology.Adaptive_Pool_Test_Hooks;
