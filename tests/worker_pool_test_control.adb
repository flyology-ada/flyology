with Ada.Real_Time;
with Interfaces.C;

package body Worker_Pool_Test_Control is

   use type Ada.Real_Time.Time;
   use type Interfaces.C.int;

   procedure C_Reset
     with Import,
          Convention => C,
          External_Name => "flyology_test_worker_pool_reset";
   procedure C_Fail_Activation_At (Ordinal : Interfaces.C.int)
     with Import,
          Convention => C,
          External_Name => "flyology_test_worker_activation_fail_at";
   procedure C_Arm_Shutdown_Barrier
     with Import,
          Convention => C,
          External_Name => "flyology_test_worker_shutdown_barrier_arm";
   function C_Shutdown_Barrier_Reached return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_worker_shutdown_barrier_reached";
   procedure C_Release_Shutdown_Barrier
     with Import,
          Convention => C,
          External_Name => "flyology_test_worker_shutdown_barrier_release";

   procedure Reset is
   begin
      C_Reset;
   end Reset;

   procedure Fail_Activation_At (Ordinal : Positive) is
   begin
      C_Fail_Activation_At (Interfaces.C.int (Ordinal));
   end Fail_Activation_At;

   procedure Arm_Shutdown_Barrier is
   begin
      C_Arm_Shutdown_Barrier;
   end Arm_Shutdown_Barrier;

   procedure Wait_Shutdown_Barrier is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while C_Shutdown_Barrier_Reached = 0 loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with
              "worker pool shutdown barrier was not reached";
         end if;
         delay 0.001;
      end loop;
   end Wait_Shutdown_Barrier;

   procedure Release_Shutdown_Barrier is
   begin
      C_Release_Shutdown_Barrier;
   end Release_Shutdown_Barrier;

end Worker_Pool_Test_Control;
