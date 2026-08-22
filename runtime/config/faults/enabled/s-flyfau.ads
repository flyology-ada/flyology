with Interfaces.C;

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
      Structured_Listener_Close,
      File_Uring_Drain_Pause,
      File_Uring_Submit_EBUSY,
      File_Uring_Overflow_Flush,
      File_Uring_Backpressure,
      File_Uring_Flush_EBUSY,
      File_Uring_Probe_Unsupported,
      File_Uring_Post_Setup_Failure,
      Poller_File_Drain_Pause,
      File_Uring_Synchronous_Eventfd,
      Create_Lifecycle_Window,
      Automatic_Placement_Window);

   for Fault_Point use
     (Fiber_Allocation               => 1,
      Stack_Mapping                  => 2,
      Poller_Watch                   => 3,
      Poller_Wait                    => 4,
      Poller_Wake                    => 5,
      Poller_EINTR                   => 6,
      File_Submission_Full           => 7,
      Group_Startup                  => 8,
      Stack_Protection               => 9,
      Stack_Discard                  => 10,
      Final_Reap_Window              => 11,
      File_Cancel_Not_Cancelable     => 12,
      File_Cancel_Already_Completing => 13,
      File_Pre_Park                  => 14,
      File_Cancel_Delete_EINTR       => 15,
      File_Cancel_Delete_Failure     => 16,
      File_Cancel_Admin_Delay        => 17,
      File_Cancel_Synthetic          => 18,
      File_Cancel_Stale_Event        => 19,
      Accept_Connection_Aborted      => 20,
      Accept_Protocol_Error          => 21,
      Accept_Process_File_Limit      => 22,
      Accept_System_File_Limit       => 23,
      Accept_Bad_Descriptor          => 24,
      Structured_Listener_Close      => 25,
      File_Uring_Drain_Pause         => 26,
      File_Uring_Submit_EBUSY        => 27,
      File_Uring_Overflow_Flush      => 28,
      File_Uring_Backpressure        => 29,
      File_Uring_Flush_EBUSY         => 30,
      File_Uring_Probe_Unsupported   => 31,
      File_Uring_Post_Setup_Failure  => 32,
      Poller_File_Drain_Pause        => 33,
      File_Uring_Synchronous_Eventfd => 34,
      Create_Lifecycle_Window        => 36,
      Automatic_Placement_Window     => 37);

   function Fail (Point : Fault_Point) return Boolean;
   pragma Inline_Always (Fail);

   function Pause_Final_Reaper return Boolean;
   procedure Release_Final_Reaper;

   --  Create/Finalize rendezvous. Pause_Create_Registration parks a creating
   --  thread that already passed the unlocked lifecycle guard and returns
   --  False if finalization never arrives. Note_Create_Registering reports
   --  that the parked thread now owns its registry shard, and
   --  Release_Create_Registration releases the parked thread and waits for
   --  that report so the finalizing thread continues in the widened window.
   function Pause_Create_Registration return Boolean;
   procedure Note_Automatic_Placement_Claim (Group : Interfaces.C.int);
   function Pause_Automatic_Placement return Boolean;
   procedure Note_Create_Registering;
   procedure Release_Create_Registration;
end System.Flyology.Faults;
