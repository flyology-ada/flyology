with Interfaces.C;

package Fault_Control is

   type Point is
     (Fiber_Allocation,
      Stack_Mapping,
      Poller_Watch,
      Poller_Wait,
      Poller_Wake,
      Poller_EINTR,
      File_Submission_Full,
      Group_Startup);

   for Point use
     (Fiber_Allocation     => 1,
      Stack_Mapping        => 2,
      Poller_Watch         => 3,
      Poller_Wait          => 4,
      Poller_Wake          => 5,
      Poller_EINTR         => 6,
      File_Submission_Full => 7,
      Group_Startup        => 8);

   function Enabled return Boolean;
   procedure Reset;
   procedure Arm
     (At_Point : Point;
      First    : Natural := 0;
      Count    : Positive := 1);
   function Calls (At_Point : Point) return Natural;

private
   function C_Enabled return Interfaces.C.int;
   pragma Import (C, C_Enabled, "gnatevl_test_faults_enabled");

   procedure C_Reset;
   pragma Import (C, C_Reset, "gnatevl_test_fault_reset");

   function C_Arm
     (At_Point : Interfaces.C.int;
      First    : Interfaces.C.unsigned;
      Count    : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Arm, "gnatevl_test_fault_arm");

   function C_Calls
     (At_Point : Interfaces.C.int) return Interfaces.C.unsigned;
   pragma Import (C, C_Calls, "gnatevl_test_fault_calls");
end Fault_Control;
