with Ada.Finalization;
with Interfaces;
with Interfaces.C;

--  Provides coalesced filesystem-change hints through task-aware readiness.
--  Notifications are advisory: callers must inspect the watched object to
--  determine its current state and must not use events as an operation count.
--
--  Example:
--
--     Watcher.Open;
--     Id := Watcher.Add ("configuration");
--     Watcher.Next (Change, Outcome, Timeout => 30.0);
package Flyology.IO.File_Watches is

   --  Number of paths accepted by a default-discriminated watcher. Callers
   --  that need another bound select it on the Watcher object.
   Default_Capacity : constant Positive := 64;

   --  Stable identifier for one registration during its owner's lifetime.
   type Watch_Id is new Interfaces.Unsigned_64;
   --  Sentinel that never identifies a registration.
   No_Watch : constant Watch_Id := 0;

   --  Portable change categories. Each value is a coalesced hint rather than
   --  a claim that exactly one filesystem operation occurred.
   --  @enum Contents_Changed File data or directory entries may have changed
   --  @enum Metadata_Changed Attributes or link metadata may have changed
   --  @enum Identity_Changed The watched pathname may name a different object
   --  @enum Watch_Invalidated The registration must be removed and recreated
   --  @enum Events_Lost Kernel detail was lost; rebuild relevant cached state
   type Change_Kind is
     (Contents_Changed,
      Metadata_Changed,
      Identity_Changed,
      Watch_Invalidated,
      Events_Lost);
   --  Set of coalesced hints reported for one watch.
   type Change_Set is array (Change_Kind) of Boolean with Pack;
   --  Empty hint set.
   No_Changes : constant Change_Set := (others => False);

   --  One notification associated with a still-known registration.
   --  @field Watch Registration returned by Add
   --  @field Changes Coalesced portable change hints
   type File_Event is record
      Watch   : Watch_Id := No_Watch;
      Changes : Change_Set := No_Changes;
   end record;

   --  Controlled owner of one platform queue and up to Capacity watched
   --  paths. Operations are intentionally unsynchronized: one task must
   --  serialize Open, Add, Remove, Next, and Close. Finalization is
   --  nonraising.
   type Watcher (Capacity : Positive := Default_Capacity) is
     new Ada.Finalization.Limited_Controlled with private;

   --  Allocate the platform queue. Repeated calls while open are harmless.
   --  The metadata syscall executes directly on the calling lane.
   --  @param Item Serialized watcher to initialize
   --  @exception Device_Error Queue creation or configuration fails
   procedure Open (Item : in out Watcher);

   --  Register an existing file or directory. The final symbolic-link
   --  component is followed. Registration is persistent between Next calls,
   --  so a later Next observes a coalesced hint for changes made meanwhile.
   --  Add performs pathname metadata syscalls directly on the calling lane.
   --  @param Item Open serialized watcher
   --  @param Path Existing file or directory to observe
   --  @return Stable registration identifier
   --  @exception Device_Error Item is closed, capacity is exhausted, Path is
   --     empty or contains NUL, or registration fails
   function Add (Item : in out Watcher; Path : String) return Watch_Id;

   --  Remove Id and release its platform resources. Queued hints for Id are
   --  discarded. The logical identifier is retired even when the platform
   --  removal reports failure, so callers must not retry the same Id.
   --  Removing No_Watch or an unknown identifier is rejected.
   --  @param Item Open serialized watcher
   --  @param Id Registration to remove
   --  @exception Device_Error Item is closed, Id is unknown, or removal fails
   procedure Remove (Item : in out Watcher; Id : Watch_Id);

   --  Return one pending coalesced event, wait until one becomes available,
   --  or report timeout/interruption. Negative Timeout waits indefinitely;
   --  zero performs an immediate drain. One monotonic deadline spans stale
   --  kernel records and readiness retries. Interrupt descriptors are observed
   --  but never consumed. A lightweight task suspends only itself; a native
   --  task blocks only its pthread. Result is empty unless Outcome is Ready.
   --  @param Item Open serialized watcher with at least one registration
   --  @param Result Event returned when Outcome is Ready
   --  @param Outcome Ready, Timed_Out, or Interrupted
   --  @param Timeout Relative monotonic deadline in seconds
   --  @param Interrupts Borrowed readable interruption descriptors
   --  @exception Device_Error State, readiness, or event draining fails
   procedure Next
     (Item       : in out Watcher;
      Result     : out File_Event;
      Outcome    : out Wait_Outcome;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Release all registrations and the platform queue. Repeated calls are
   --  harmless. The watcher is invalidated even if a close reports failure.
   --  @param Item Serialized watcher whose resources are released
   --  @exception Device_Error A platform close or removal reports failure
   procedure Close (Item : in out Watcher);

   --  Report whether Item currently owns a platform queue.
   --  @param Item Watcher to inspect
   --  @return True after Open and before Close
   function Is_Open (Item : Watcher) return Boolean;

private
   type Watch_Record;
   type Watch_Record_Access is access Watch_Record;
   type Watch_Record is record
      Id      : Watch_Id := No_Watch;
      Subject : Interfaces.C.int := Interfaces.C.int (-1);
      Pending : Change_Set := No_Changes;
      Next    : Watch_Record_Access := null;
   end record;

   type Watcher (Capacity : Positive := Default_Capacity) is
     new Ada.Finalization.Limited_Controlled with record
      Native_Source : Interfaces.C.int := Interfaces.C.int (-1);
      First   : Watch_Record_Access := null;
      Count   : Natural := 0;
      Next_Id : Watch_Id := 1;
   end record;

   --  Release Item without propagating close errors.
   --  @param Item Watcher being finalized
   overriding procedure Finalize (Item : in out Watcher);
end Flyology.IO.File_Watches;
