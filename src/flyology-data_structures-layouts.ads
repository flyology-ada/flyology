with Interfaces;
with System;

--  Shared private header and checked-layout operations.
private package Flyology.Data_Structures.Layouts with Preelaborate is
   --  @exclude Internal layout implementation, not part of the public API.

   --  Shared fixed-width header size.
   Header_Size : constant Byte_Count := 64;

   --  Cached process-local region geometry.
   --  @field Base Validated native structure base, never persisted
   --  @field Location Stored structure offset retained for nested layouts
   --  @field Extent Validated structure extent
   --  @field Epoch_Value Initialization epoch cached for stale-view rejection
   --  @field Attached Whether the local view remains active
   type Local_View is record
      Base          : System.Address := System.Null_Address;
      Location      : Region_Offset := Null_Offset;
      Extent        : Byte_Count := 0;
      Epoch_Value   : Interfaces.Unsigned_32 := 0;
      Attached      : Boolean := False;
   end record;

   --  Structure-specific fields in the shared header.
   --  @field Capacity Primary bounded capacity
   --  @field Element_Size Primary fixed payload size
   --  @field Alignment Primary stored alignment
   --  @field Auxiliary Structure-specific 32-bit geometry or guard state
   --  @field Word_1 Structure-specific 64-bit state or geometry
   --  @field Word_2 Structure-specific 64-bit state or geometry
   type Header_Values is record
      Capacity    : Interfaces.Unsigned_32;
      Element_Size : Interfaces.Unsigned_32;
      Alignment   : Interfaces.Unsigned_32;
      Auxiliary   : Interfaces.Unsigned_32;
      Word_1      : Interfaces.Unsigned_64;
      Word_2      : Interfaces.Unsigned_64;
   end record;

   --  Add two layout values with explicit overflow rejection.
   --  @param Left First addend
   --  @param Right Second addend
   --  @return Exact sum
   function Checked_Add (Left, Right : Byte_Count) return Byte_Count;

   --  Multiply two layout values with explicit overflow rejection.
   --  @param Left First factor
   --  @param Right Second factor
   --  @return Exact product
   function Checked_Multiply (Left, Right : Byte_Count) return Byte_Count;

   --  Round Value upward to a power-of-two alignment.
   --  @param Value Unaligned byte count
   --  @param Alignment Required power-of-two boundary
   --  @return Smallest aligned value not below Value
   function Align_Up
     (Value, Alignment : Byte_Count) return Byte_Count;

   --  Capture validated local geometry without persisting the native base.
   --  @param Region Attached caller-owned region
   --  @param Location Nonzero stored structure offset
   --  @param Extent Complete structure extent
   --  @param Alignment Required base alignment
   --  @return Cached local view
   function Capture
     (Region    : Region_View;
      Location  : Region_Offset;
      Extent    : Byte_Count;
      Alignment : Byte_Count) return Local_View;

   --  Convert a structure-relative slice only after complete validation.
   --  @param Item Cached local view
   --  @param Relative Structure-relative byte offset
   --  @param Extent Complete accessed extent
   --  @param Alignment Required native alignment
   --  @return Validated process-local address
   function Address_At
     (Item      : Local_View;
      Relative  : Byte_Count;
      Extent    : Byte_Count;
      Alignment : Byte_Count := 1) return System.Address;

   --  Mark initialization incomplete and write immutable shared metadata.
   --  @param Item Captured view returned to the leaf
   --  @param Region Attached target region
   --  @param Location Stored structure offset
   --  @param Identity Leaf-specific magic, version, and schema
   --  @param Extent Complete structure extent
   --  @param Header Leaf-specific common-header fields
   --  @param Base_Alignment Required structure alignment
   procedure Begin_Initialize
     (Item         : out Local_View;
      Region       : Region_View;
      Location     : Region_Offset;
      Identity     : Layout_Identity;
      Extent       : Byte_Count;
      Header       : Header_Values;
      Base_Alignment : Byte_Count);

   --  Publish complete initialization with a release store.
   --  @param Item Initialized local view
   procedure Publish (Item : Local_View);

   --  Atomically mark a nested leaf incomplete before its containing layout
   --  is published. Relative must identify the nested shared-header state.
   --  @param Item Initialized containing view
   --  @param Relative Structure-relative nested leaf location
   procedure Invalidate_Nested
     (Item : Local_View; Relative : Byte_Count);

   --  Acquire and validate the shared header of an existing structure.
   --  @param Item Captured full view returned to the leaf
   --  @param Header Validated leaf-specific common-header fields
   --  @param Region Independently attached backing region
   --  @param Location Stored structure offset
   --  @param Identity Expected leaf-specific magic, version, and schema
   --  @param Base_Alignment Required structure alignment
   procedure Attach
     (Item           : out Local_View;
      Header         : out Header_Values;
      Region         : Region_View;
      Location       : Region_Offset;
      Identity       : Layout_Identity;
      Base_Alignment : Byte_Count);

   --  Reject a detached, incomplete, or destroyed view.
   --  @param Item Local view to validate
   procedure Require_Ready (Item : Local_View);

   --  Atomically poison a ready object. The caller must have
   --  independently established exclusive recovery authority, such as known
   --  owner death or whole-region quiescence.
   --  @param Item Attached local view to invalidate
   procedure Poison (Item : Local_View);

   --  Validate a stored identity and poison an object without first attaching
   --  its potentially inconsistent mutable contents. This is the recovery
   --  entry point for a supervisor that did not retain an earlier leaf view.
   --  @param Region Attached backing region
   --  @param Location Stored structure offset
   --  @param Identity Expected leaf identity
   --  @param Base_Alignment Required structure alignment
   procedure Poison_At
     (Region         : Region_View;
      Location       : Region_Offset;
      Identity       : Layout_Identity;
      Base_Alignment : Byte_Count);

   --  Report whether an attached object is poisoned.
   --  @param Item Attached local view
   --  @return True only for the stored Poisoned lifecycle state
   function Is_Poisoned (Item : Local_View) return Boolean;

   --  Publish destroyed state and detach Item.
   --  @param Item Exclusively synchronized active view
   procedure Mark_Destroyed (Item : in out Local_View);

   --  Clear all process-local mapping geometry.
   --  @param Item Local view to detach
   procedure Detach (Item : in out Local_View);
   pragma Inline_Always
     (Checked_Add, Checked_Multiply, Align_Up, Address_At, Require_Ready,
      Invalidate_Nested, Is_Poisoned);
end Flyology.Data_Structures.Layouts;
