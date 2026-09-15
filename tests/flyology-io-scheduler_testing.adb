with Flyology.Connection_Test_Hooks;

package body Flyology.IO.Scheduler_Testing is

   package Test_Hooks renames Flyology.Connection_Test_Hooks;

   procedure Reset_Waiter_Work is
   begin
      Test_Hooks.Reset_Scheduler_Waiter_Work;
   end Reset_Waiter_Work;

   function Waiter_Work return Waiter_Work_Snapshot is
   begin
      return
        (Unlink_Scans    =>
           Interfaces.Unsigned_64 (Test_Hooks.Scheduler_Waiter_Work (53)),
         Retention_Scans =>
           Interfaces.Unsigned_64 (Test_Hooks.Scheduler_Waiter_Work (54)),
         Delivery_Scans  =>
           Interfaces.Unsigned_64 (Test_Hooks.Scheduler_Waiter_Work (55)));
   end Waiter_Work;

end Flyology.IO.Scheduler_Testing;
