package Flyology.Process_Lifecycle with Preelaborate is

   type Event_Runtime_State is
     (Dormant,
      Running,
      Finalizing,
      Stopped,
      Cleanup_Deferred,
      Fork_Child);

   --  Dormant means that Flyology is initialized but no event-loop group has
   --  ever been created. Native-only applications remain in this state until
   --  GNARL process finalization changes it to Stopped.
   --
   --  Cleanup_Deferred means that finalization found an unexpected live
   --  fiber or could not safely stop a loop. Resources are deliberately left
   --  to operating-system process exit instead of racing the task.
   --
   --  Fork_Child is reported when the process identity no longer matches the
   --  runtime that initialized Flyology. The underlying query takes no runtime
   --  lock, but this diagnostic does not broaden the child contract: only
   --  async-signal-safe operations followed by exec/_exit are supported;
   --  Ada tasking and all other Flyology operations are unsupported.
   function State return Event_Runtime_State;

   subtype Group_Count is Natural range 0 .. 256;

   --  Number of lazily created groups currently owned by the process. This
   --  query is inert and does not start an event loop.
   function Created_Groups return Group_Count;

end Flyology.Process_Lifecycle;
