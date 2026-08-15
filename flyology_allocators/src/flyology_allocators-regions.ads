with System;

--  Attaches local views to caller-owned contiguous bytes. This package does
--  not create, resize, synchronize, or release storage. A view may describe a
--  static array, a linker-defined range, an Ada storage pool, or any other
--  addressable region whose lifetime the caller owns.
--  Region operations are not synchronized; attachment, detachment, and
--  backing-store lifetime require application-level exclusion.
package Flyology_Allocators.Regions with Preelaborate is

   --  Backing-region view governed by this package.
   subtype View is Region_View;

   --  Attach Item to Length caller-owned bytes beginning at Base. The native
   --  base remains only in Item. Length must be positive and the complete
   --  range must be representable without native address wraparound.
   --  @param Item Local view to attach
   --  @param Base First caller-owned backing byte
   --  @param Length Number of accessible bytes
   --  @exception Region_Error Base is null, Length is zero or too large, or
   --     the native address range overflows
   procedure Attach
     (Item   : in out View;
      Base   : System.Address;
      Length : Byte_Count);

   --  Detach Item without changing or releasing any backing bytes. Existing
   --  structure views captured from Item must be detached separately before
   --  their backing storage is released or repurposed.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item currently names a local backing range.
   --  @param Item Local view to inspect
   --  @return True only after successful attachment and before detachment
   function Is_Attached (Item : View) return Boolean;

   --  Return Item's attached byte length, or zero while detached.
   --  @param Item Local view to inspect
   --  @return Number of bytes in the local backing range
   function Length (Item : View) return Byte_Count;

   --  Return the first native byte of an attached caller-owned region. The
   --  address remains borrowed and becomes invalid when the caller releases
   --  the backing storage.
   function Base_Address (Item : View) return System.Address;

   --  Return a checked address within an attached caller-owned region. Offset
   --  is relative to the first byte and may be zero.
   function Address_At
     (Item      : View;
      Offset    : Byte_Count;
      Extent    : Byte_Count;
      Alignment : Byte_Count := 1) return System.Address;

   --  Validate a persisted relationship without exposing a native address.
   --  Offset zero is rejected as the null sentinel. Alignment must be a
   --  nonzero power of two, and the entire Extent must fit in Item.
   --  @param Item Local view containing the relationship
   --  @param Offset Persisted byte offset from the region base
   --  @param Extent Complete object extent in bytes
   --  @param Alignment Required native alignment
   --  @exception Region_Error Item is detached or the relationship is null,
   --     overflowing, misaligned, out of range, or not natively representable
   procedure Validate
     (Item      : View;
      Offset    : Region_Offset;
      Extent    : Byte_Count;
      Alignment : Byte_Count := 1);

end Flyology_Allocators.Regions;
