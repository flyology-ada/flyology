with Ada.Exceptions;
with Interfaces.C;
with System.Tasking;

package System.Flyology.Task_Results is
   function Allocate_Task_Result return System.Address;
   --  Allocate a task-owned result sidecar before taking an RTS or ATCB lock.
   --  The caller must either attach it to an initialized ATCB or release it.

   procedure Attach_Task_Result
     (T       : System.Tasking.Task_Id;
      Storage : System.Address);
   --  Attach an already allocated sidecar to T. This performs only one scalar
   --  address store and may be called while the creator holds runtime locks.

   procedure Release_Task_Result (Storage : System.Address);
   --  Release a sidecar that was allocated but not attached to an ATCB. This
   --  may finalize synchronization state and must run without runtime locks.

   function Detach_Task_Result
     (T : System.Tasking.Task_Id) return System.Address;
   --  Remove and return T's sidecar pointer while its ATCB is protected.
   --  The caller releases the returned storage only after dropping every RTS
   --  and ATCB lock.

   procedure Publish
     (Cause : System.Tasking.Cause_Of_Termination;
      T     : System.Tasking.Task_Id;
      X     : Ada.Exceptions.Exception_Occurrence);
   --  Copy one terminal result after the task body and its dependent-task
   --  master have completed. Exception rendering and protected signaling run
   --  without an ATCB or RTS lock.

   function Observe_Task
     (T         : System.Address;
      Item      : System.Address;
      Item_Size : Interfaces.C.size_t) return Interfaces.C.int;
   pragma Export
     (C, Observe_Task, "flyology_runtime_task_result_observe_task");
   --  Return 1 and copy a terminal result, 0 while the task is not terminal,
   --  or a negative ABI/lifetime error. The copy is acquire-synchronized with
   --  publication and does not expose task-owned storage.

   function Wait_Task
     (T                   : System.Address;
      Timeout_Nanoseconds : Interfaces.C.long_long) return Interfaces.C.int;
   pragma Export
     (C, Wait_Task, "flyology_runtime_task_result_wait_task");
   --  Wait for T's persistent completion gate. A negative timeout waits
   --  indefinitely, zero only checks, and a positive value is relative.
   --  Ordinary GNARL protected-entry and delay machinery supplies lane-aware
   --  blocking for both native and lightweight callers. Return 1 once the
   --  result is terminal, 0 on timeout, or a negative code. Only a task that
   --  reaches Task_Wrapper publishes, so a created-but-never-activated task
   --  keeps its gate closed; reclaiming that task finalizes the gate and any
   --  queued caller here is reported as -3 rather than an Ada exception
   --  crossing this Convention-C boundary. Abort is not an exception and
   --  still propagates to the caller.
end System.Flyology.Task_Results;
