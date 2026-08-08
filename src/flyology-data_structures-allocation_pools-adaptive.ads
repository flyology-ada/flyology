with Flyology.Data_Structures.Arenas;
with Flyology.Data_Structures.Handles;
with Flyology.Data_Structures.Slab_Pools;
with Flyology.Data_Structures.Storage_Types.Elements;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

use type Interfaces.Unsigned_64;

--  Provides a bounded adaptive fixed-size pool backed by a relocatable arena.
--  The pool adds fixed-size slab chunks only after existing chunks are
--  exhausted. Chunk allocation is serialized by one persisted nonblocking
--  guard; live chunks use Slab_Pools per-slot synchronization, so operations
--  on different slots may proceed concurrently through distinct local views.
--  One local View must not be used concurrently because it owns process-local
--  chunk attachment caches. A dead chunk-creation owner leaves the pool guard
--  locked; an external authority may poison the whole pool after establishing
--  owner death and quiescence. Recovery requires exclusive reinitialization
--  of the backing arena followed by the pool; reinitializing only the outer
--  pool would orphan its old chunk allocations. The pool and every local view
--  must be detached before the arena mapping disappears. Every operation
--  taking an arena rejects an arena whose instance identity or incarnation
--  differs from the one the view attached to.
--  Arena_Provider must be configured with a Minimum_Block_Size of at least
--  Minimum_Arena_Alignment so every nested slab has its required alignment.
--  @formal Arena_Provider Compile-time backing allocator instance whose
--    minimum block size is at least Minimum_Arena_Alignment
--  @formal Element Immutable byte-backed element stored in each slot
--  @formal Slots_Per_Chunk Fixed slot count in every allocated slab chunk
--  @formal Maximum_Chunks Maximum number of arena-backed chunks
generic
   with package Arena_Provider is new
     Flyology.Data_Structures.Arenas (<>);
   with package Element is new
     Flyology.Data_Structures.Storage_Types.Elements (<>);
   Slots_Per_Chunk : Positive;
   Maximum_Chunks  : Positive;
package Flyology.Data_Structures.Allocation_Pools.Adaptive
  with Preelaborate is

   --  Smallest backing-arena allocation alignment accepted by this pool.
   Minimum_Arena_Alignment : constant Byte_Count := 64;

   --  Eight-byte magic stored in every adaptive-pool header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5341_504F_4F31#;

   --  Schema binds arena, element, and fixed chunk geometry.
   Schema : constant Interfaces.Unsigned_64 :=
     16#0001_4150_4F4F_0001# xor Arena_Provider.Identity.Magic xor
     Arena_Provider.Identity.Schema xor Element.Signature xor
     Interfaces.Shift_Left
       (Interfaces.Unsigned_64 (Element.Version), 32) xor
     Interfaces.Unsigned_64 (Slots_Per_Chunk) xor
     Interfaces.Shift_Left (Interfaces.Unsigned_64 (Maximum_Chunks), 32);

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 1;

   --  Complete persisted pool identity.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Generation-stamped address-independent slot identity.
   --  @field Chunk One-based chunk table index
   --  @field Slot One-based slot within the chunk slab
   --  @field Stamp Nonzero slab-slot generation
   --  @field Epoch Adaptive-pool initialization incarnation
   type Handle is record
      Chunk : Interfaces.Unsigned_32 := 0;
      Slot  : Handles.Slot_Index := 0;
      Stamp : Handles.Generation := 0;
      Epoch : Interfaces.Unsigned_32 := 0;
   end record;
   for Handle use record
      Chunk at 0 range 0 .. 31;
      Slot  at 4 range 0 .. 31;
      Stamp at 8 range 0 .. 31;
      Epoch at 12 range 0 .. 31;
   end record;
   for Handle'Size use 128;

   --  Null adaptive-pool relationship.
   Null_Handle : constant Handle := (others => <>);

   --  Allocation attempt outcome.
   --  @enum Allocated A slot was initialized and Value names it
   --  @enum Exhausted Every permitted chunk is full
   --  @enum Allocation_Contended Pool or slot metadata is currently owned
   --  @enum Arena_Exhausted The backing arena cannot allocate another chunk
   type Allocation_Result is
     (Allocated, Exhausted, Allocation_Contended, Arena_Exhausted);

   --  Process-local attached view with bounded chunk attachment caches.
   type View is limited private;

   --  Compute the fixed outer pool header and chunk-table extent.
   --  @return Complete stored outer extent; chunk slabs remain arena-backed
   function Required_Storage return Byte_Count;

   --  Destructively create an empty pool. The arena must be attached and the
   --  caller must exclusively own the outer extent. If the outer extent held
   --  an earlier pool incarnation, the caller must first reinitialize or
   --  otherwise reclaim its arena allocations; this operation cannot discover
   --  allocations after overwriting the old chunk table.
   --  @param Item View attached on success
   --  @param Region Caller-owned outer backing region
   --  @param Location Nonzero 64-byte-aligned outer location
   --  @param Arena Attached backing arena
   --  @exception Constraint_Error Arena allocation alignment is insufficient
   procedure Initialize
     (Item     : out View;
      Region   : Region_View;
      Location : Region_Offset;
      Arena    : Arena_Provider.View);

   --  Create in allocation-certified virgin bytes or attach to an exact ready
   --  pool. Arena algorithm, instance, incarnation, element, and chunk
   --  geometry must match.
   --  @param Item Attached view or detached during another initialization
   --  @param Region Caller-owned outer backing region
   --  @param Location Stored pool location
   --  @param Arena Attached backing arena
   --  @param Result Creation, attachment, or in-progress outcome
   --  @exception Constraint_Error Arena allocation alignment is insufficient
   procedure Create_Or_Attach
     (Item     : out View;
      Region   : Region_View;
      Location : Region_Offset;
      Arena    : Arena_Provider.View;
      Result   : out Open_Result);

   --  Attach to a quiescent compatible pool and validate every live chunk.
   --  @param Item View attached on success
   --  @param Region Independently attached outer region
   --  @param Location Stored pool location
   --  @param Arena Independently attached matching arena
   --  @exception Layout_Error Identity, geometry, arena alignment, table, or
   --    chunk is incompatible or corrupt
   --  @exception Busy_Error A chunk creation was active or abandoned
   procedure Attach
     (Item     : out View;
      Region   : Region_View;
      Location : Region_Offset;
      Arena    : Arena_Provider.View);

   --  Detach local chunk caches and the outer view without releasing storage.
   --  @param Item View to detach
   procedure Detach (Item : in out View);

   --  Test process-local attachment.
   --  @param Item View to inspect
   --  @return True while Item retains outer mapping information
   function Is_Attached (Item : View) return Boolean;

   --  Poison the whole pool after external owner-death and quiescence checks.
   --  @param Region Attached outer backing region
   --  @param Location Stored pool location
   procedure Poison (Region : Region_View; Location : Region_Offset);

   --  Allocate from an existing slab or add one arena-backed chunk. The call
   --  never waits; arena exhaustion is distinct from the configured chunk
   --  limit and transient metadata contention.
   --  @param Item Non-shared process-local pool view
   --  @param Arena Matching backing arena view
   --  @param Data Application value accepted by Element
   --  @param Value New handle or Null_Handle
   --  @param Result Allocation outcome
   procedure Try_Allocate
     (Item   : in out View;
      Arena  : in out Arena_Provider.View;
      Data   : Element.Source;
      Value  : out Handle;
      Result : out Allocation_Result);

   --  Observe one live immutable element.
   --  @param Item Non-shared process-local pool view
   --  @param Arena Matching backing arena view
   --  @param Value Live adaptive-pool handle
   --  @param Data Observation assigned on success
   procedure Read
     (Item  : in out View;
      Arena : Arena_Provider.View;
      Value : Handle;
      Data  : out Element.Observed);

   --  Replace one live immutable element.
   --  @param Item Non-shared process-local pool view
   --  @param Arena Matching backing arena view
   --  @param Value Live adaptive-pool handle
   --  @param Data Application value accepted by Element
   procedure Replace
     (Item  : in out View;
      Arena : Arena_Provider.View;
      Value : Handle;
      Data  : Element.Source);

   --  Release one live slot. Every copy of Value becomes stale.
   --  @param Item Non-shared process-local pool view
   --  @param Arena Matching backing arena view
   --  @param Value Live adaptive-pool handle
   procedure Release
     (Item  : in out View;
      Arena : Arena_Provider.View;
      Value : Handle);

   --  Destroy every empty chunk, return its allocation to Arena, invalidate
   --  the outer pool, and detach Item. All views and handles must be
   --  quiescent.
   --  If a later chunk is live, earlier empty chunks may already have been
   --  reclaimed when Program_Error is raised; the remaining pool stays ready.
   --  @param Item Exclusively synchronized pool view
   --  @param Arena Matching exclusively synchronized backing arena view
   --  @exception Program_Error A chunk still contains a live slot
   procedure Destroy
     (Item : in out View; Arena : in out Arena_Provider.View);

private
   package Chunk_Slabs is new Flyology.Data_Structures.Slab_Pools
     (Element => Element);

   type Chunk_Cache is limited record
      Region : Region_View;
      Slab   : Chunk_Slabs.View;
      Allocation : Arena_Provider.Allocation_Handle :=
        Arena_Provider.Null_Allocation;
   end record;
   type Chunk_Cache_Array is
     array (Positive range 1 .. Maximum_Chunks) of Chunk_Cache;
   type View is limited record
      Core          : Layouts.Local_View;
      Guard_Address : System.Address := System.Null_Address;
      Arena_Instance : Interfaces.Unsigned_64 := 0;
      Arena_Epoch    : Interfaces.Unsigned_32 := 0;
      Chunks         : Chunk_Cache_Array;
   end record;
end Flyology.Data_Structures.Allocation_Pools.Adaptive;
