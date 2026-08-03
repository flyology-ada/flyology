with Interfaces;

--  Exposes serialized TLS controller state to deterministic runtime tests.
--  Applications should not depend on this child package.
--  @exclude
package Flyology.IO.TLS.Testing is

   --  Snapshot the descriptor generation through the controller operation
   --  used by normal TLS calls.
   --  @param Item Connection to inspect
   --  @return Current generation encoded as an unsigned test value
   function Generation
     (Item : in out Connection) return Interfaces.Unsigned_64;

   --  Attempt to acquire Item using an earlier generation snapshot. The
   --  helper releases the gate if Snapshot unexpectedly remains current.
   --  @param Item Connection whose generation is tested
   --  @param Snapshot Earlier value returned by Generation
   --  @param Was_Replaced True when the controller rejects Snapshot
   procedure Attempt_Stale_Acquisition
     (Item         : in out Connection;
      Snapshot     : Interfaces.Unsigned_64;
      Was_Replaced : out Boolean);

end Flyology.IO.TLS.Testing;
