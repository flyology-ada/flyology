with Interfaces;
with System;

--  Defines the representation contract shared by Flyology's relocatable
--  data structures. Stored layouts contain only fixed-width scalar values and
--  payload bytes; a Region_View's native address is process-local state and
--  is never copied into its backing bytes. Linking this hierarchy has no
--  scheduler, poller, task, mapping, or allocation side effect.
--  Every attached structure view caches a persisted initialization epoch.
--  Reinitializing an extent advances that epoch, so an older local view fails
--  closed instead of applying cached geometry to replacement bytes.
--  If out-of-band corruption destroys the epoch itself, recovery Initialize
--  treats the bytes as fresh; all earlier views must first be retired.
package Flyology.Data_Structures with Preelaborate is

   --  Fixed-width byte count used by stored extents and region views.
   type Byte_Count is new Interfaces.Unsigned_64;

   --  Fixed-width offset from the first byte of a backing region. Zero is the
   --  null sentinel for persisted relationships and is not a valid structure
   --  location.
   type Region_Offset is new Interfaces.Unsigned_64;

   --  Stable identity of one stored layout. Leaf packages expose one value so
   --  wrappers can consume the identity without repeating numeric literals.
   --  Bump Version or Schema when the leaf's stored contract changes; Magic
   --  identifies the structure family.
   --  @field Magic Nonzero 64-bit structure-family identifier
   --  @field Version Leaf-specific stored-layout version
   --  @field Schema Nonzero 64-bit layout and algorithm schema identifier
   type Layout_Identity is record
      Magic   : Interfaces.Unsigned_64;
      Version : Interfaces.Unsigned_32;
      Schema  : Interfaces.Unsigned_64;
   end record;

   --  Null persisted relationship.
   Null_Offset : constant Region_Offset := 0;

   --  Raised when a local region view is detached or a requested slice is
   --  null, overflowing, misaligned, out of bounds, or not representable by
   --  the native address model.
   Region_Error : exception;

   --  Raised when stored magic, version, schema, extent, configuration, or
   --  mutable bookkeeping is incompatible or corrupt.
   Layout_Error : exception;

   --  Raised when a handle is null, malformed, out of range, stale, already
   --  reclaimed, or otherwise invalid for the receiving structure.
   Handle_Error : exception;

   --  Raised when a nonblocking internally synchronized operation cannot
   --  acquire its stored guard immediately. Callers may retry only at an
   --  application-selected scheduling or fairness point; implementations do
   --  not spin, sleep, or block an event-loop pthread.
   Busy_Error : exception;

   --  Raised when an explicitly waiting data-structure operation cannot
   --  complete before its nonnegative monotonic timeout expires. Waiting
   --  operations yield the calling Ada task between attempts; their leaf
   --  contracts describe which resource conditions are retried.
   Timeout_Error : exception;

   --  Nonnegative relative timeout accepted by explicitly waiting operations,
   --  limited to 24 hours. Zero permits one immediate attempt and then times
   --  out. Time starts with the first unsuccessful claim.
   subtype Wait_Timeout is Duration range 0.0 .. 86_400.0;

   --  Outcome of one race-safe attempt to create a virgin stored object or
   --  attach to an existing compatible object.
   --  @enum Initialized_New The caller atomically claimed an exact zero
   --     lifecycle sentinel, initialized the object, and attached Item
   --  @enum Attached_Existing A ready compatible object already existed and
   --     Item attached to it without rewriting stored bytes
   --  @enum Initialization_In_Progress Another caller owns the virgin-state
   --     initialization claim; Item remains detached and no waiting occurs
   type Open_Result is
     (Initialized_New, Attached_Existing, Initialization_In_Progress);

   --  Raised when an object or independently recoverable slot was explicitly
   --  poisoned after an interrupted or failed mutation. Poisoned bytes are
   --  never silently treated as ready; the leaf defines explicit recovery.
   Poison_Error : exception;

   --  Process-local view of mapped or arena-backed bytes. The type owns no
   --  mapping and performs no allocation. Flyology.Data_Structures.Regions
   --  attaches and detaches it; every structure view borrowing the same bytes
   --  must be detached before the application unmaps or releases the region.
   type Region_View is limited private;

private
   type Region_View is limited record
      Base         : System.Address := System.Null_Address;
      Length_Value : Byte_Count := 0;
      Attached     : Boolean := False;
   end record;

   --  Return an address only after checking the complete local slice. This is
   --  private to the hierarchy so callers cannot perform base-plus-offset
   --  arithmetic outside the structure implementations.
   --  @exclude
   --  @param Base Native base retained only in a process-local view
   --  @param Length Complete local region length
   --  @param Is_Attached Whether the local view is active
   --  @param Offset Checked byte offset
   --  @param Extent Checked object extent
   --  @param Alignment Required native alignment
   --  @return Validated native object address
   function Checked_Address
     (Base       : System.Address;
      Length     : Byte_Count;
      Is_Attached : Boolean;
      Offset     : Region_Offset;
      Extent     : Byte_Count;
      Alignment  : Byte_Count) return System.Address;
   pragma Inline_Always (Checked_Address);

end Flyology.Data_Structures;
