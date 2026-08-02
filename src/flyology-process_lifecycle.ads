--  Exposes inert process-level state for the patched tasking runtime.
--
--  Example:
--
--     State := Flyology.Process_Lifecycle.State;
package Flyology.Process_Lifecycle with Preelaborate is

   --  Process-wide Flyology scheduler lifecycle.
   --  @enum Dormant Initialized but no event-loop group was created
   --  @enum Running At least one group exists and finalization has not begun
   --  @enum Finalizing Runtime shutdown is in progress
   --  @enum Stopped Runtime shutdown completed
   --  @enum Cleanup_Deferred Unsafe cleanup was deferred to process exit
   --  @enum Fork_Child Process identity changed after runtime initialization
   type Event_Runtime_State is
     (Dormant,
      Running,
      Finalizing,
      Stopped,
      Cleanup_Deferred,
      Fork_Child);

   --  Read the process lifecycle without taking a runtime lock. Native-only
   --  programs remain Dormant until GNARL finalization changes them to
   --  Stopped.
   --  Cleanup_Deferred means live resources were intentionally left for OS
   --  process exit. Fork_Child is diagnostic only: after fork, only
   --  async-signal-safe operations followed by exec or _exit are supported.
   --  @return Current process lifecycle state
   --  @exception Program_Error The runtime reports an unknown state encoding
   function State return Event_Runtime_State;

   --  Number of possible lazily created execution groups.
   subtype Group_Count is Natural range 0 .. 256;

   --  Count groups currently owned by the process. This thread-safe query is
   --  inert and does not start an event loop.
   --  @return Number of created groups
   --  @exception Program_Error The runtime reports an invalid count
   function Created_Groups return Group_Count;

end Flyology.Process_Lifecycle;
