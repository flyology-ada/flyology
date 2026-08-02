with Interfaces.C;

package System.Gnatevl.Faults is
   pragma Preelaborate;

   --  Stable identifiers shared with runtime/native/platform.c. Faults are
   --  disabled in ordinary runtime builds; test builds arm deterministic
   --  call ranges through the exported C test interface.
   type Fault_Point is
     (Fiber_Allocation,
      Stack_Mapping,
      Poller_Watch,
      Poller_Wait,
      Poller_Wake,
      Poller_EINTR,
      File_Submission_Full,
      Group_Startup);

   for Fault_Point use
     (Fiber_Allocation     => 1,
      Stack_Mapping        => 2,
      Poller_Watch         => 3,
      Poller_Wait          => 4,
      Poller_Wake          => 5,
      Poller_EINTR         => 6,
      File_Submission_Full => 7,
      Group_Startup        => 8);

   function Fail (Point : Fault_Point) return Boolean;

private
   function Test_Fault_Hit (Point : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, Test_Fault_Hit, "gnatevl_test_fault_hit");
end System.Gnatevl.Faults;
