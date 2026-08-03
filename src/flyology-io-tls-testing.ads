with Interfaces;

--  Exposes serialized TLS controller state to deterministic runtime tests.
--  Applications should not depend on this child package.
--  @exclude
package Flyology.IO.TLS.Testing is

   --  Report whether a provider operation currently owns the connection gate.
   --  @param Item Connection to inspect
   --  @return True while one operation is active
   function Operation_Active (Item : Connection) return Boolean;

   --  Report how many operations are queued at the connection gate.
   --  @param Item Connection to inspect
   --  @return Current queued acquisition count
   function Queued_Operations (Item : Connection) return Natural;

   --  Report whether a leader Close has published its draining state.
   --  @param Item Connection to inspect
   --  @return True while close cleanup is in progress
   function Close_In_Progress (Item : Connection) return Boolean;

   --  Snapshot the descriptor generation used by the controller.
   --  @param Item Connection to inspect
   --  @return Current generation encoded as an unsigned test value
   function Generation (Item : Connection) return Interfaces.Unsigned_64;

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
