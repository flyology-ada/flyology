package System.Flyology.Faults is
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
      Stack_Protection,
      Stack_Discard,
      Final_Reap_Window);

   for Fault_Point use
     (Fiber_Allocation     => 1,
      Stack_Mapping        => 2,
      Poller_Watch         => 3,
      Poller_Wait          => 4,
      Poller_Wake          => 5,
      Poller_EINTR         => 6,
      File_Submission_Full => 7,
      Group_Startup        => 8,
      Stack_Protection     => 9,
      Stack_Discard        => 10,
      Final_Reap_Window    => 11);

   function Fail (Point : Fault_Point) return Boolean;
   pragma Inline_Always (Fail);

   function Pause_Final_Reaper return Boolean;
   procedure Release_Final_Reaper;
end System.Flyology.Faults;
