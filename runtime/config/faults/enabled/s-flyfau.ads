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
      Final_Reap_Window,
      File_Cancel_Not_Cancelable,
      File_Cancel_Already_Completing,
      File_Pre_Park,
      File_Cancel_Delete_EINTR,
      File_Cancel_Delete_Failure,
      File_Cancel_Admin_Delay,
      File_Cancel_Synthetic,
      File_Cancel_Stale_Event,
      Accept_Connection_Aborted,
      Accept_Protocol_Error,
      Accept_Process_File_Limit,
      Accept_System_File_Limit,
      Accept_Bad_Descriptor,
      Structured_Listener_Close);

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
      Final_Reap_Window    => 11,
      File_Cancel_Not_Cancelable   => 12,
      File_Cancel_Already_Completing => 13,
      File_Pre_Park                => 14,
      File_Cancel_Delete_EINTR     => 15,
      File_Cancel_Delete_Failure   => 16,
      File_Cancel_Admin_Delay      => 17,
      File_Cancel_Synthetic        => 18,
      File_Cancel_Stale_Event      => 19,
      Accept_Connection_Aborted    => 20,
      Accept_Protocol_Error        => 21,
      Accept_Process_File_Limit    => 22,
      Accept_System_File_Limit     => 23,
      Accept_Bad_Descriptor        => 24,
      Structured_Listener_Close   => 25);

   function Fail (Point : Fault_Point) return Boolean;
   pragma Inline_Always (Fail);

   function Pause_Final_Reaper return Boolean;
   procedure Release_Final_Reaper;
end System.Flyology.Faults;
