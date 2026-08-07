with Ada.Streams;
with Flyology.Data_Structures.Handles;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

--  Provides bounded fixed-size byte-slot allocation in relocatable storage.
--  Stored slots contain generation, state, free-list index, and payload bytes;
--  they contain no address or access value. A Slab_Pool is not internally
--  synchronized: initialization, attachment, allocation, access, reclamation,
--  and destruction require application-level exclusion across every view.
package Flyology.Data_Structures.Slab_Pools with Preelaborate is

   --  Eight-byte magic stored in every slab header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_534C_4142_3031#;

   --  Schema identifier for the current fixed-width slab layout.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_534C_4142_0001#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 1;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached view. It owns neither the backing region nor any
   --  allocated slot and must be detached before the backing bytes disappear.
   type View is limited private;

   --  Immutable stored configuration reported by an attached view.
   --  @field Capacity Number of independently allocatable slots
   --  @field Element_Size Payload bytes in each slot
   --  @field Element_Alignment Required payload alignment
   --  @field Extent Complete stored layout size in bytes
   type Metadata is record
      Capacity          : Interfaces.Unsigned_32;
      Element_Size      : Interfaces.Unsigned_32;
      Element_Alignment : Interfaces.Unsigned_32;
      Extent            : Byte_Count;
   end record;

   --  Compute the complete layout extent without touching a region.
   --  @param Capacity Number of slots
   --  @param Element_Size Payload bytes per slot
   --  @param Element_Alignment Power-of-two payload alignment
   --  @return Required header, metadata, padding, and payload bytes
   --  @exception Constraint_Error Alignment or arithmetic is invalid
   function Required_Storage
     (Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive := 1) return Byte_Count;

   --  Create a new slab at Location and attach Item. The caller must
   --  exclusively own the complete target extent. Initialization publishes a
   --  ready state with a release store only after all metadata is complete.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero aligned stored offset
   --  @param Capacity Number of slots
   --  @param Element_Size Payload bytes per slot
   --  @param Element_Alignment Power-of-two payload alignment
   --  @exception Region_Error Region or extent is invalid
   --  @exception Constraint_Error Configuration cannot be represented
   procedure Initialize
     (Item              : out View;
      Region            : Region_View;
      Location          : Region_Offset;
      Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive := 1);

   --  Attach to a quiescent existing slab and validate its complete layout,
   --  free list, generations, and expected configuration.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored slab offset
   --  @param Capacity Expected slot count
   --  @param Element_Size Expected payload size
   --  @param Element_Alignment Expected payload alignment
   --  @exception Layout_Error Stored data is incompatible or corrupt
   --  @exception Region_Error Region or extent is invalid
   procedure Attach
     (Item              : out View;
      Region            : Region_View;
      Location          : Region_Offset;
      Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive := 1);

   --  Detach Item without changing backing bytes or reclaiming live slots.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item View to inspect
   --  @return True only while Item retains local mapping information
   function Is_Attached (Item : View) return Boolean;

   --  Return the immutable stored configuration.
   --  @param Item Attached view
   --  @return Validated slab metadata
   --  @exception Region_Error Item is detached
   function Current_Metadata (Item : View) return Metadata;

   --  Attempt to allocate one free slot without waiting. Success returns the
   --  slot's current generation; failure returns Null_Handle.
   --  @param Item Exclusively synchronized slab view
   --  @param Value New generation-stamped handle or Null_Handle
   --  @param Allocated True only when a slot was acquired
   procedure Try_Allocate
     (Item      : in out View;
      Value     : out Handles.Handle;
      Allocated : out Boolean);

   --  Reclaim Value and advance its generation so every copy becomes stale.
   --  @param Item Exclusively synchronized slab view
   --  @param Value Live handle returned by this slab
   --  @exception Handle_Error Value is null, malformed, stale, or reclaimed
   --  @exception Layout_Error Slot bookkeeping is corrupt
   procedure Release
     (Item  : in out View;
      Value : Handles.Handle);

   --  Copy exactly one slot payload into Data.
   --  @param Item Exclusively synchronized slab view
   --  @param Value Live handle returned by this slab
   --  @param Data Destination whose length must equal Element_Size
   --  @exception Handle_Error Value is invalid or stale
   --  @exception Constraint_Error Data has the wrong length
   procedure Read
     (Item  : View;
      Value : Handles.Handle;
      Data  : out Ada.Streams.Stream_Element_Array);

   --  Replace exactly one slot payload from Data.
   --  @param Item Exclusively synchronized slab view
   --  @param Value Live handle returned by this slab
   --  @param Data Source whose length must equal Element_Size
   --  @exception Handle_Error Value is invalid or stale
   --  @exception Constraint_Error Data has the wrong length
   procedure Write
     (Item  : in out View;
      Value : Handles.Handle;
      Data  : Ada.Streams.Stream_Element_Array);

   --  Invalidate an empty slab and detach Item. Every view and handle must be
   --  quiescent; live slots make destruction fail rather than leak ownership.
   --  @param Item Exclusively synchronized slab view
   --  @exception Program_Error One or more slots remain live
   procedure Destroy (Item : in out View);

   pragma Inline (Try_Allocate, Release, Read, Write);

private
   type View is limited record
      Core              : Layouts.Local_View;
      Capacity_Value    : Interfaces.Unsigned_32 := 0;
      Element_Value     : Interfaces.Unsigned_32 := 0;
      Alignment_Value   : Interfaces.Unsigned_32 := 0;
      Payload_Offset    : Byte_Count := 0;
      Stride            : Byte_Count := 0;
      Free_Head_Address : System.Address := System.Null_Address;
   end record;
end Flyology.Data_Structures.Slab_Pools;
