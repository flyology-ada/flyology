with Interfaces.C;
with System.OS_Interface;

package System.Flyology.Scheduler is
   pragma Preelaborate;

   function Initialize (Environment : System.Address) return Interfaces.C.int;
   procedure Finalize;

   function Create
     (T          : System.Address;
      Stack_Size : Interfaces.C.size_t;
      Priority   : Interfaces.C.int;
      Wrapper    : System.Address;
      Group      : Interfaces.C.int) return Interfaces.C.int;

   function Is_Lightweight_Task (T : System.Address) return Interfaces.C.int;
   function Current_Task return System.Address;
   function Task_Thread
     (T : System.Address) return System.OS_Interface.Thread_Id;

   function Sleep
     (Task_Lock : System.Address;
      Deadline  : Duration;
      Timed_Out : access Interfaces.C.int) return Interfaces.C.int;

   function Wake (T : System.Address) return Interfaces.C.int;
   function Yield return Interfaces.C.int;

   function Set_Priority
     (T                   : System.Address;
      Priority            : Interfaces.C.int;
      Loss_Of_Inheritance : Interfaces.C.int)
      return Interfaces.C.int;
   --  Priority is GNARL's current (active) Ada priority. A nonzero
   --  Loss_Of_Inheritance preserves RM D.2.2(9) head-of-queue placement at
   --  the lightweight task's next event-loop dispatching point.

   function Destroy (T : System.Address) return Interfaces.C.int;

   function Current_Group return Interfaces.C.int;
   pragma Export (C, Current_Group, "flyology_runtime_current_group");

   function Configured_Pool_Size return Interfaces.C.int;
   pragma Export
     (C, Configured_Pool_Size, "flyology_runtime_configured_pool_size");

   function Configured_Placement return Interfaces.C.int;
   pragma Export
     (C, Configured_Placement, "flyology_runtime_configured_placement");

   function Placement_Supported
     (Mode : Interfaces.C.int) return Interfaces.C.int;
   pragma Export
     (C, Placement_Supported, "flyology_runtime_placement_supported");

   function Placement_Value_Available
     (Mode  : Interfaces.C.int;
      Value : Interfaces.C.int) return Interfaces.C.int;
   pragma Export
     (C,
      Placement_Value_Available,
      "flyology_runtime_placement_value_available");

   function Configure_Group_Placement
     (Group : Interfaces.C.int;
      Mode  : Interfaces.C.int;
      Value : Interfaces.C.int) return Interfaces.C.int;
   pragma Export
     (C,
      Configure_Group_Placement,
      "flyology_runtime_configure_group_placement");

   function Query_Group_Placement
     (Group       : Interfaces.C.int;
      Status      : System.Address;
      Status_Size : Interfaces.C.size_t) return Interfaces.C.int;
   pragma Export
     (C,
      Query_Group_Placement,
      "flyology_runtime_query_group_placement");

   function Current_Processor return Interfaces.C.int;
   pragma Export
     (C, Current_Processor, "flyology_runtime_current_processor");

   function Migrate (Group : Interfaces.C.int) return Interfaces.C.int;
   pragma Export (C, Migrate, "flyology_runtime_migrate");

   function Pin_Current_Thread
     (Owner : access System.Address) return Interfaces.C.int;
   pragma Export
     (C, Pin_Current_Thread, "flyology_runtime_pin_current_thread");

   function Unpin_Current_Thread
     (Owner : System.Address) return Interfaces.C.int;
   pragma Export
     (C, Unpin_Current_Thread, "flyology_runtime_unpin_current_thread");

   function Current_Thread_Is_Pinned return Interfaces.C.int;
   pragma Export
     (C,
      Current_Thread_Is_Pinned,
      "flyology_runtime_current_thread_is_pinned");

   function Create_Dedicated_Group return Interfaces.C.int;
   pragma Export
     (C, Create_Dedicated_Group, "flyology_runtime_create_dedicated_group");

   function Is_Dedicated_Group
     (Group : Interfaces.C.int) return Interfaces.C.int;
   pragma Export
     (C, Is_Dedicated_Group, "flyology_runtime_is_dedicated_group");

   --  Internal ABI used by Flyology.Observability. Snapshot points at a
   --  caller-owned, C-compatible record and Snapshot_Size permits the ABI to
   --  reject mismatched clients instead of overwriting a shorter record. A
   --  fork child returns no snapshot before consulting inherited locks.
   function Observe_Group
     (Group         : Interfaces.C.int;
      Snapshot      : System.Address;
      Snapshot_Size : Interfaces.C.size_t) return Interfaces.C.int;
   pragma Export (C, Observe_Group, "flyology_runtime_observe_group");

   function Observe_Last_Fatal return Interfaces.C.int;
   pragma Export
     (C, Observe_Last_Fatal, "flyology_runtime_observe_last_fatal");

   --  Process-lifecycle ABI. State is an atomic scalar and is safe to query
   --  in the child immediately after fork; no scheduler lock is acquired.
   function Observe_Lifecycle return Interfaces.C.int;
   pragma Export
     (C, Observe_Lifecycle, "flyology_runtime_observe_lifecycle");

   function Observe_Created_Groups return Interfaces.C.int;
   pragma Export
     (C,
      Observe_Created_Groups,
      "flyology_runtime_observe_created_groups");

   --  ABI used by the public Flyology.IO package. A timeout below zero waits
   --  indefinitely; otherwise it is a relative count of nanoseconds.
   function In_Lightweight_Task return Interfaces.C.int;
   pragma Export
     (C, In_Lightweight_Task, "flyology_runtime_in_lightweight_task");

   --  Register Count descriptor/interest pairs. Interrupt_Wait is 1 when the
   --  set combines a primary descriptor with lifecycle wake descriptors; it
   --  affects observability only, not readiness selection.
   function Wait_IO_Many
     (Requests            : System.Address;
      Count               : Interfaces.C.unsigned;
      Timeout_Nanoseconds : Interfaces.C.long_long;
      Interrupt_Wait      : Interfaces.C.int)
      return Interfaces.C.int;
   pragma Export (C, Wait_IO_Many, "flyology_runtime_wait_io_many");

   function File_IO
     (Descriptor  : Interfaces.C.int;
      Buffer      : System.Address;
      Length      : Interfaces.C.size_t;
      Offset      : Interfaces.C.long_long;
      For_Write   : Interfaces.C.int;
      Cancel_FD   : Interfaces.C.int;
      Task_Lock   : System.Address;
      Transferred : access Interfaces.C.long_long;
      Error_Code  : access Interfaces.C.int;
      Cancelled   : access Interfaces.C.int) return Interfaces.C.int;

private
   pragma Inline (Is_Lightweight_Task);
   pragma Inline (Current_Task);
end System.Flyology.Scheduler;
