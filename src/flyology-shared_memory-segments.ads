with Flyology.Data_Structures;
with Flyology.Data_Structures.Regions;
with Interfaces;
with System;

--  Provides a fixed-capacity persisted registry of exact names and relocatable
--  extents inside one shared mapping. The registry stores only fixed-width
--  scalars and name bytes. A persisted nonblocking guard serializes lookup,
--  allocation, removal, and reuse across processes and native tasks.
--
--  An initializing slot remains unavailable until its creator publishes
--  success or failure. If a creator dies while holding the registry guard or
--  an initialization claim, the state remains abandoned. This package never
--  steals ownership and provides no process-death detection. A live creator
--  can publish failure. Otherwise an independently authorized
--  supervisor must establish owner death and participant quiescence before
--  replacing the whole backing object.
package Flyology.Shared_Memory.Segments is

   --  Raised when persisted segment identity, geometry, or state is corrupt.
   Segment_Error : exception;

   --  Current fixed stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 1;

   --  Segment registry geometry and application schema. All values are stored
   --  and checked exactly at attachment.
   --  @field Schema Nonzero application-selected segment contract identity
   --  @field Registry_Capacity Fixed number of named registry slots
   --  @field Maximum_Name_Length Maximum exact UTF-8 or opaque byte name
   --     length; names are Ada String bytes and receive no normalization
   --  @field Allocation_Alignment Power-of-two alignment for every named
   --     extent and for reuse eligibility
   type Configuration is record
      Schema                 : Interfaces.Unsigned_64;
      Registry_Capacity      : Positive;
      Maximum_Name_Length    : Positive;
      Allocation_Alignment   : Positive := 64;
   end record;

   --  Result of race-safe segment creation or attachment.
   --  @enum Initialized_New This mapping was authorized by exclusive backing
   --     creation, claimed the zero lifecycle, and published the registry
   --  @enum Attached_Existing A ready compatible registry already existed
   --  @enum Initialization_In_Progress Another initializer owns the claim, or
   --     this mapping came from an opener and is not allowed to claim zero
   type Segment_Open_Result is
     (Initialized_New, Attached_Existing, Initialization_In_Progress);

   --  Outcome of one nonblocking exact-name find-or-create attempt.
   --  @enum Created The caller owns the returned Creation_Claim and must
   --     publish success or failure
   --  @enum Attached_Existing The same exact name has a ready matching extent
   --  @enum Initialization_In_Progress The same exact name has an unpublished
   --     creator
   --  @enum Previous_Initialization_Failed Failure was published and must be
   --     explicitly removed before reuse
   --  @enum Configuration_Mismatch The exact name exists with another length
   --  @enum Registry_Busy The persisted guard was already owned
   --  @enum Registry_Exhausted No free or removed registry slot is available
   --  @enum Segment_Exhausted No reusable extent fits and bump space is spent
   --  @enum Generation_Exhausted The nonwrapping generation counter is spent
   type Find_Or_Create_Result is
     (Created,
      Attached_Existing,
      Initialization_In_Progress,
      Previous_Initialization_Failed,
      Configuration_Mismatch,
      Registry_Busy,
      Registry_Exhausted,
      Segment_Exhausted,
      Generation_Exhausted);

   --  Outcome of one nonblocking exact-name lookup.
   --  @enum Found A ready extent was found
   --  @enum Not_Found No active exact name exists
   --  @enum Initialization_In_Progress The name exists but is unpublished
   --  @enum Initialization_Failed The name has a published failure
   --  @enum Registry_Busy The persisted guard was already owned
   type Lookup_Result is
     (Found,
      Not_Found,
      Initialization_In_Progress,
      Initialization_Failed,
      Registry_Busy);

   --  Outcome of explicit name removal.
   --  @enum Removed A ready or failed entry became reusable
   --  @enum Not_Found No active exact name exists
   --  @enum Initialization_In_Progress A live creation claim prevents removal
   --  @enum Registry_Busy The persisted guard was already owned
   type Remove_Result is
     (Removed, Not_Found, Initialization_In_Progress, Registry_Busy);

   --  Current state of a generation-stamped named handle.
   --  @enum Null_Handle The canonical null handle was supplied
   --  @enum Initializing The handle names an unpublished creation
   --  @enum Ready The handle names a published extent
   --  @enum Failed The handle names a published initialization failure
   --  @enum Removed The handle's slot was removed but not yet reused
   --  @enum Stale The slot generation no longer matches or is invalid
   type Handle_State is
     (Null_Handle, Initializing, Ready, Failed, Removed, Stale);

   --  Application-defined nonzero initialization failure code.
   subtype Failure_Code is Interfaces.Unsigned_32 range 1 ..
     Interfaces.Unsigned_32'Last;

   --  Process-local segment view borrowing one Mapping. Detach it before the
   --  mapping is unmapped. Segment detachment does not change stored bytes.
   type View is limited private;

   --  Copyable fixed-width generation-stamped name handle. It contains no
   --  native pointer and must be revalidated against a View before use.
   type Named_Handle is private;

   --  Limited creator capability returned only to the winner of a name race.
   --  It grants access to unpublished bytes and the right to publish success
   --  or failure. Losing callers receive an invalid claim.
   type Creation_Claim is limited private;

   --  Return the minimum bytes occupied by the segment header and registry,
   --  rounded to Allocation_Alignment. A useful segment must be larger so at
   --  least one named extent fits.
   --  @param Config Registry geometry to validate
   --  @return First allocatable byte offset
   --  @exception Constraint_Error Configuration is invalid or overflows
   function Required_Registry_Storage
     (Config : Configuration) return Byte_Length;

   --  Race-safely initialize or attach the segment at mapping offset zero.
   --  Only mappings derived from an exclusively created backing object may
   --  claim an exact-zero lifecycle sentinel. Opened or received mappings
   --  report Initialization_In_Progress instead of repairing abandoned zero
   --  bytes. Ready attachments validate magic, version, schema, total extent,
   --  capacity, name limit, slot geometry, and allocation alignment.
   --  @param Item Detached segment view to populate
   --  @param Source Live mapping borrowed for Item's lifetime
   --  @param Config Exact persisted configuration
   --  @param Result Initialization or attachment outcome
   --  @exception Constraint_Error Config or mapping extent is invalid
   --  @exception Segment_Error Persisted state or configuration is corrupt
   procedure Create_Or_Attach
     (Item   : in out View;
      Source : Mapping;
      Config : Configuration;
      Result : out Segment_Open_Result);

   --  Detach Item without changing the registry or mapping.
   --  @param Item Segment view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item borrows a live mapping.
   --  @param Item Segment view to inspect
   --  @return True after successful creation or attachment
   function Is_Attached (Item : View) return Boolean;

   --  Attach a Data_Structures region view to the complete borrowed mapping.
   --  Detach leaf views, Region, and Item before unmapping Source.
   --  @param Item Attached segment view
   --  @param Region Detached relocatable region view to attach
   --  @exception Segment_Error Item is detached or no longer ready
   procedure Attach_Region
     (Item   : View;
      Region : in out Flyology.Data_Structures.Regions.View);

   --  Attempt exact-name lookup or reserve a new aligned extent. Hashes only
   --  accelerate scanning: stored length and every name byte are compared, so
   --  collisions never alias names. Removed extents are reused when their
   --  stored length is at least Requested_Length; otherwise monotonic bump
   --  space is used. A created extent is not exposed through Resolve until
   --  Publish succeeds.
   --  @param Item Attached ready segment
   --  @param Name Nonempty exact byte name within the configured limit
   --  @param Requested_Length Positive requested extent length
   --  @param Handle Generation-stamped handle for the matching or new slot
   --  @param Claim Valid creator capability only when Result is Created
   --  @param Result Nonblocking operation outcome
   --  @param Failure Published failure code for a previous failed initializer,
   --     otherwise zero
   --  @exception Constraint_Error Name or requested length is invalid
   --  @exception Segment_Error Persisted registry state is corrupt
   procedure Try_Find_Or_Create
     (Item             : View;
      Name             : String;
      Requested_Length : Byte_Length;
      Handle           : out Named_Handle;
      Claim            : out Creation_Claim;
      Result           : out Find_Or_Create_Result;
      Failure          : out Interfaces.Unsigned_32);

   --  Attempt exact-name lookup without allocating or changing registry state.
   --  @param Item Attached ready segment
   --  @param Name Nonempty exact byte name within the configured limit
   --  @param Handle Generation-stamped handle for the active slot, if any
   --  @param Result Nonblocking lookup outcome
   --  @param Failure Published failure code when Result is
   --     Initialization_Failed
   --  @exception Constraint_Error Name is invalid
   --  @exception Segment_Error Persisted registry state is corrupt
   procedure Try_Find
     (Item    : View;
      Name    : String;
      Handle  : out Named_Handle;
      Result  : out Lookup_Result;
      Failure : out Interfaces.Unsigned_32);

   --  Return the unpublished extent to its creator. Other callers cannot
   --  construct a valid Creation_Claim and Resolve rejects initializing slots.
   --  A reused extent may retain bytes from its previous generation, so the
   --  creator must explicitly initialize the complete nested object before
   --  publication rather than assuming virgin zero storage.
   --  @param Item Attached segment containing Claim
   --  @param Claim Live creator capability
   --  @param Location Persisted region offset of the unpublished extent
   --  @param Length Reserved extent length
   --  @exception Segment_Error Claim is invalid, stale, or no longer
   --     initializing
   procedure Claimed_Extent
     (Item     : View;
      Claim    : Creation_Claim;
      Location : out Flyology.Data_Structures.Region_Offset;
      Length   : out Byte_Length);

   --  Publish successful initialization with release ordering and consume the
   --  creator capability. The returned Named_Handle then resolves as ready.
   --  @param Item Attached segment containing Claim
   --  @param Claim Live creator capability to consume
   --  @exception Segment_Error Claim is invalid, stale, or no longer
   --     initializing
   procedure Publish (Item : View; Claim : in out Creation_Claim);

   --  Publish explicit initialization failure with release ordering and
   --  consume Claim. The failed name remains reserved until Remove succeeds;
   --  no caller silently overwrites it.
   --  @param Item Attached segment containing Claim
   --  @param Claim Live creator capability to consume
   --  @param Failure Nonzero application failure code
   --  @exception Segment_Error Claim is invalid, stale, or no longer
   --     initializing
   procedure Publish_Failure
     (Item : View; Claim : in out Creation_Claim; Failure : Failure_Code);

   --  Resolve a ready generation-stamped handle to a persisted region offset
   --  and extent length. Removed, failed, initializing, or reused slots fail.
   --  Resolution does not pin the returned bytes against a later Remove;
   --  application lifecycle coordination must keep the named extent live
   --  while a nested object view borrows it.
   --  @param Item Attached segment containing Handle
   --  @param Handle Untrusted generation-stamped handle
   --  @param Location Persisted region offset
   --  @param Length Published extent length
   --  @exception Segment_Error Handle is null, stale, or not ready
   procedure Resolve
     (Item     : View;
      Handle   : Named_Handle;
      Location : out Flyology.Data_Structures.Region_Offset;
      Length   : out Byte_Length);

   --  Inspect a handle after validating its slot and generation.
   --  @param Item Attached segment containing Handle
   --  @param Handle Handle to inspect
   --  @return Current state or Stale
   --  @exception Segment_Error Persisted slot state is corrupt
   function State_Of
     (Item : View; Handle : Named_Handle) return Handle_State;

   --  Return a failed handle's application code.
   --  @param Item Attached segment containing Handle
   --  @param Handle Handle whose state must be Failed
   --  @return Published nonzero failure code
   --  @exception Segment_Error Handle is stale or not failed
   function Failure_Of
     (Item : View; Handle : Named_Handle) return Failure_Code;

   --  Explicitly remove a ready or failed exact name. Initializing entries are
   --  never stolen. The slot and extent become candidates for later reuse;
   --  existing handles stop resolving, and reuse receives a new generation.
   --  Removing registry metadata does not destroy application objects in the
   --  extent and does not unlink or close the OS backing object.
   --  @param Item Attached segment
   --  @param Name Exact name to remove
   --  @param Result Nonblocking removal outcome
   --  @exception Constraint_Error Name is invalid
   --  @exception Segment_Error Persisted registry state is corrupt
   procedure Try_Remove
     (Item : View; Name : String; Result : out Remove_Result);

private
   type Named_Handle is record
      Slot  : Interfaces.Unsigned_32 := 0;
      Stamp : Interfaces.Unsigned_64 := 0;
   end record;

   type Creation_Claim is limited record
      Slot     : Interfaces.Unsigned_32 := 0;
      Stamp    : Interfaces.Unsigned_64 := 0;
      Location : Flyology.Data_Structures.Region_Offset := 0;
      Length   : Byte_Length := 0;
   end record;

   type View is limited record
      Base       : System.Address := System.Null_Address;
      Extent     : Byte_Length := 0;
      Capacity   : Interfaces.Unsigned_32 := 0;
      Name_Limit : Interfaces.Unsigned_32 := 0;
      Slot_Size  : Interfaces.Unsigned_32 := 0;
      Alignment  : Interfaces.Unsigned_32 := 0;
      Data_Start : Byte_Length := 0;
      Schema     : Interfaces.Unsigned_64 := 0;
      Attached   : Boolean := False;
   end record;

end Flyology.Shared_Memory.Segments;
