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
      Connect_Interrupted,
      Create_Lifecycle_Window);

   for Point use
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
      Structured_Listener_Close   => 25,
      File_Uring_Drain_Pause      => 26,
      File_Uring_Submit_EBUSY     => 27,
      File_Uring_Overflow_Flush   => 28,
      File_Uring_Backpressure     => 29,
      File_Uring_Flush_EBUSY      => 30,
      File_Uring_Probe_Unsupported => 31,
      File_Uring_Post_Setup_Failure => 32,
      Poller_File_Drain_Pause        => 33,
      File_Uring_Synchronous_Eventfd => 34,
      Connect_Interrupted            => 35,
      Create_Lifecycle_Window        => 36);

   function Enabled return Boolean;
   procedure Reset;
   procedure Arm
     (At_Point : Point;
      First    : Natural := 0;
      Count    : Positive := 1);
   procedure Disarm (At_Point : Point);
   function Calls (At_Point : Point) return Natural;

   type File_Cancel_Backend is (Darwin_AIO, Linux_IO_Uring, Linux_Native_AIO);
   for File_Cancel_Backend use
     (Darwin_AIO => 1, Linux_IO_Uring => 2, Linux_Native_AIO => 3);

   type File_Cancel_Disposition is
     (Submitted, Already_Completing, Not_Cancelable, Failed);
   for File_Cancel_Disposition use
     (Submitted => 1, Already_Completing => 2,
      Not_Cancelable => 3, Failed => 4);

   function File_Cancel_Count
     (Backend     : File_Cancel_Backend;
      Disposition : File_Cancel_Disposition;
      Terminal    : Boolean) return Natural;

   --  Memory orders the runtime handed to the C atomic-store bridge. Invalid
   --  collects every value outside the __ATOMIC_* range, which is what an
   --  import that omits the model argument leaves in the argument register.
   type Memory_Model is
     (Relaxed, Consume, Acquire, Release, Acq_Rel, Seq_Cst, Invalid);
   for Memory_Model use
     (Relaxed => 0,
      Consume => 1,
      Acquire => 2,
      Release => 3,
      Acq_Rel => 4,
      Seq_Cst => 5,
      Invalid => 6);

   function Atomic_Store_Model_Count (Model : Memory_Model) return Natural;

   function Uring_Identity_Count (Reused : Boolean) return Natural;
   function Uring_Admin_Complete_Count return Natural;
   function Uring_CQ_Capacity return Natural;

private
   function C_Enabled return Interfaces.C.int;
   pragma Import (C, C_Enabled, "flyology_test_faults_enabled");

   procedure C_Reset;
   pragma Import (C, C_Reset, "flyology_test_fault_reset");

   function C_Arm
     (At_Point : Interfaces.C.int;
      First    : Interfaces.C.unsigned;
      Count    : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Arm, "flyology_test_fault_arm");

   function C_Disarm (At_Point : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Disarm, "flyology_test_fault_disarm");

   function C_Calls
     (At_Point : Interfaces.C.int) return Interfaces.C.unsigned;
   pragma Import (C, C_Calls, "flyology_test_fault_calls");

   function C_File_Cancel_Count
     (Backend     : Interfaces.C.int;
      Disposition : Interfaces.C.int;
      Terminal    : Interfaces.C.int) return Interfaces.C.unsigned;
   pragma Import
     (C, C_File_Cancel_Count, "flyology_test_file_cancel_count");

   function C_Atomic_Store_Model_Count
     (Model : Interfaces.C.int) return Interfaces.C.unsigned;
   pragma Import
     (C, C_Atomic_Store_Model_Count,
      "flyology_test_atomic_store_model_count");

   function C_Uring_Identity_Count
     (Reused : Interfaces.C.int) return Interfaces.C.unsigned;
   pragma Import
     (C, C_Uring_Identity_Count, "flyology_test_uring_identity_count");

   function C_Uring_Admin_Complete_Count return Interfaces.C.unsigned;
   pragma Import
     (C, C_Uring_Admin_Complete_Count,
      "flyology_test_uring_admin_complete_count");

   function C_Uring_CQ_Capacity return Interfaces.C.unsigned;
   pragma Import
     (C, C_Uring_CQ_Capacity, "flyology_test_uring_cq_capacity");
end Fault_Control;
