--  Enabled DNS test observations selected by the owning project. Production
--  selects an imported-only specification and statically removes its guarded
--  references.
private package Flyology.DNS_Test_Observations is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   --  Clear all test-only receive-wait observations.
   procedure Reset;

   --  Record one receive wait and whether its UDP socket was already closed.
   procedure Record_Receive_Wait (After_Close : Boolean);

   --  Return the number of receive waits attempted after UDP closure.
   function Post_Close_Receive_Waits return Natural;

end Flyology.DNS_Test_Observations;
