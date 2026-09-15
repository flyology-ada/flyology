with Interfaces;

--  Exposes fault-enabled scheduler operation counts to deterministic runtime
--  tests. Applications should not depend on this child package.
--  @exclude
package Flyology.IO.Scheduler_Testing is

   type Waiter_Work_Snapshot is record
      Unlink_Scans    : Interfaces.Unsigned_64;
      Retention_Scans : Interfaces.Unsigned_64;
      Delivery_Scans  : Interfaces.Unsigned_64;
   end record;

   procedure Reset_Waiter_Work;

   function Waiter_Work return Waiter_Work_Snapshot;

end Flyology.IO.Scheduler_Testing;
