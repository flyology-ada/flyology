with Ada.Finalization;

--  Maintains a bounded set of directory registrations below one root.
--  Events describe the complete tree rather than one internal registration.
package Flyology.IO.File_Watches.Recursive is

   --  Tree-wide notification returned after registration reconciliation.
   --  @field Changes Coalesced hints that apply to the watched tree
   --  @field Registrations_Changed Whether reconciliation added or removed a
   --     directory registration
   --  @field Directory_Count Current number of retained logical directory
   --     registrations
   --  @field Coverage_Complete Whether the last scan covered every real
   --     directory below the root and registered each one
   type Recursive_Event is record
      Changes              : Change_Set := No_Changes;
      Registrations_Changed : Boolean := False;
      Directory_Count       : Natural := 0;
      Coverage_Complete     : Boolean := False;
   end record;

   --  Controlled owner of one recursive directory watch. Capacity bounds the
   --  root plus all real subdirectories. The default is 64. Operations are
   --  intentionally unsynchronized and can perform directory metadata work.
   type Recursive_Watcher
     (Capacity : Positive := Default_Capacity) is
     new Ada.Finalization.Limited_Controlled with private;

   --  Discover Root and register every real directory below it. The final
   --  symbolic-link component of Root is followed. Symbolic links found below
   --  Root are not traversed. Repeated calls for the same open root are
   --  harmless. Initial discovery is transactional and requires complete
   --  coverage.
   --  @param Item Closed serialized recursive watcher
   --  @param Root Existing directory tree to observe
   --  @exception Device_Error Root is invalid or not a directory, discovery
   --     or registration fails, capacity is insufficient, or Item is already
   --     open for another root
   procedure Open (Item : in out Recursive_Watcher; Root : String);

   --  Reconcile the current directory tree with its registrations. Capacity
   --  overflow or incomplete discovery preserves the previous registration
   --  set, reports incomplete coverage, and sets Events_Lost. If Root no
   --  longer exists, Refresh closes Item and reports Identity_Changed and
   --  Watch_Invalidated. Directory discovery and registration syscalls execute
   --  on the calling lane.
   --  @param Item Open serialized recursive watcher
   --  @param Result Reconciliation outcome
   --  @exception Device_Error Item is closed or discovery, registration, or
   --     cleanup fails
   procedure Refresh
     (Item   : in out Recursive_Watcher;
      Result : out Recursive_Event);

   --  Wait for one tree hint, reconcile the directory registrations, and
   --  return a tree-wide event. Timeout and Interrupts apply to the readiness
   --  wait. Reconciliation starts after readiness and is not bounded by that
   --  deadline. Interrupt descriptors are observed but never consumed. A
   --  lightweight task suspends for readiness but performs reconciliation on
   --  its event-loop pthread.
   --  @param Item Open serialized recursive watcher
   --  @param Result Tree-wide event returned when Outcome is Ready
   --  @param Outcome Ready, Timed_Out, or Interrupted
   --  @param Timeout Relative monotonic readiness deadline in seconds
   --  @param Interrupts Borrowed readable interruption descriptors
   --  @exception Device_Error State, readiness, discovery, registration, or
   --     cleanup fails
   procedure Next
     (Item       : in out Recursive_Watcher;
      Result     : out Recursive_Event;
      Outcome    : out Wait_Outcome;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
   with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Release every directory registration and owned pathname. Repeated calls
   --  are harmless. Item becomes closed even when cleanup reports failure.
   --  @param Item Serialized recursive watcher to close
   --  @exception Device_Error Platform cleanup reports failure
   procedure Close (Item : in out Recursive_Watcher);

   --  Report whether Item currently owns a recursive watch.
   --  @param Item Recursive watcher to inspect
   --  @return True after Open and before Close or root invalidation
   function Is_Open (Item : Recursive_Watcher) return Boolean;

   --  Return the number of retained logical directory registrations. While
   --  coverage is incomplete, this count can include an obsolete pathname and
   --  omit a current directory.
   --  @param Item Recursive watcher to inspect
   --  @return Retained logical directory registration count
   function Directory_Count (Item : Recursive_Watcher) return Natural;

   --  Report whether the last scan covered every real directory below Root
   --  and registered each one.
   --  @param Item Recursive watcher to inspect
   --  @return True only while Item is open with complete coverage
   function Coverage_Is_Complete
     (Item : Recursive_Watcher) return Boolean;

private
   type String_Access is access String;

   type Directory_Record is record
      Watch : Watch_Id := No_Watch;
      Path  : String_Access := null;
   end record;
   type Directory_Array is array (Positive range <>) of Directory_Record;

   type Recursive_Watcher
     (Capacity : Positive := Default_Capacity) is
     new Ada.Finalization.Limited_Controlled with record
      Source            : Watcher (Capacity => Capacity);
      Root              : String_Access := null;
      Directories       : Directory_Array (1 .. Capacity);
      Count             : Natural := 0;
      Complete_Coverage : Boolean := False;
   end record;

   --  Close Item without propagating cleanup failures.
   --  @param Item Recursive watcher being finalized
   overriding procedure Finalize (Item : in out Recursive_Watcher);
end Flyology.IO.File_Watches.Recursive;
