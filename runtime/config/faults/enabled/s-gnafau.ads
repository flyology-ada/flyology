package System.Gnatevl.Faults is
   pragma Preelaborate;

   Enabled : constant Boolean := True;

   type Fault_Point is
     (Fiber_Allocation,
      Stack_Mapping,
      Poller_Watch,
      Poller_Wait,
      Poller_Wake,
      Poller_EINTR,
      File_Submission_Full,
      Group_Startup,
      File_Cancel_Not_Cancelable,
      File_Cancel_Already_Completing);

   for Fault_Point use
     (Fiber_Allocation     => 1,
      Stack_Mapping        => 2,
      Poller_Watch         => 3,
      Poller_Wait          => 4,
      Poller_Wake          => 5,
      Poller_EINTR         => 6,
      File_Submission_Full => 7,
      Group_Startup        => 8,
      File_Cancel_Not_Cancelable => 9,
      File_Cancel_Already_Completing => 10);

   function Fail (Point : Fault_Point) return Boolean;
   pragma Inline_Always (Fail);
end System.Gnatevl.Faults;
