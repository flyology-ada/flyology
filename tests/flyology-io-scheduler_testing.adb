with Flyology.Connection_Test_Hooks;

package body Flyology.IO.Scheduler_Testing is

   package Test_Hooks renames Flyology.Connection_Test_Hooks;

   --  Pull the connection test controller into waiter-only static links. Its
   --  definitions must precede the enabled hook body in the link closure.
   procedure Reset_Connection_Test_Controller
   with Import, Convention => C, External_Name => "flyology_test_connection_barrier_reset";

   procedure Reset_Waiter_Work is
   begin
      Reset_Connection_Test_Controller;
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
