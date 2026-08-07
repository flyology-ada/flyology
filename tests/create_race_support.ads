--  Library-level state for the Create/Finalize race regression test. The
--  racing creator runs on a foreign (non-Ada) thread that is still inside the
--  scheduler while the environment task finalizes, so everything it touches
--  must outlive the main subprogram's frame.
package Create_Race_Support is

   function Arm_Exit_Check return Boolean;
   --  Register the process-exit assertion. It runs after GNARL has finalized
   --  global tasking and reports the racing create's outcome and the
   --  scheduler's final lifecycle state.

   procedure Record_Target_Group;
   --  Called from a lightweight task. Records that task's started execution
   --  group as the group the racing create will target.

   function Start_Racer return Boolean;
   --  Spawn the detached foreign thread. It parks inside Create, past the
   --  unlocked lifecycle guard, until finalization releases it.

   function Creator_Parked return Boolean;
   --  True once the foreign thread is parked in the widened create window.

end Create_Race_Support;
