with Ada.Streams;
with Interfaces;
private with Flyology.Data_Structures.Layouts;

--  Provides bounded open-addressed maps from fixed-size byte keys to
--  fixed-size byte values. Capacity is a power of two and probing is linear
--  over cached fixed-stride entries. Stored data contains only state scalars,
--  hashes, keys, and values. The package is not internally synchronized; all
--  operations across all views require application-level exclusion.
package Flyology.Data_Structures.Hash_Maps with Preelaborate is

   --  Eight-byte magic stored in every map header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5348_4D41_3031#;

   --  Schema identifier for the current FNV-1a/open-addressed layout.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_484D_4150_0001#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 1;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached map view.
   type View is limited private;

   --  Insertion outcome.
   --  @enum Inserted A previously absent key was inserted
   --  @enum Replaced An existing key's value was replaced
   --  @enum Table_Full No empty or deleted slot was available
   type Put_Result is (Inserted, Replaced, Table_Full);

   --  Compute the complete map extent. Capacity must be a power of two.
   --  @param Capacity Maximum occupied entry count
   --  @param Key_Size Bytes in every key
   --  @param Value_Size Bytes in every value
   --  @return Required header, entry metadata, padding, keys, and values
   --  @exception Constraint_Error Capacity is not a power of two
   function Required_Storage
     (Capacity   : Positive;
      Key_Size   : Positive;
      Value_Size : Positive) return Byte_Count;

   --  Initialize an empty map and attach Item.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero eight-byte-aligned stored offset
   --  @param Capacity Power-of-two maximum entry count
   --  @param Key_Size Fixed bytes per key
   --  @param Value_Size Fixed bytes per value
   procedure Initialize
     (Item       : out View;
      Region     : Region_View;
      Location   : Region_Offset;
      Capacity   : Positive;
      Key_Size   : Positive;
      Value_Size : Positive);

   --  Attach to a quiescent map, validating its expected geometry and all
   --  entry-state/count bookkeeping.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored map offset
   --  @param Capacity Expected power-of-two capacity
   --  @param Key_Size Expected key size
   --  @param Value_Size Expected value size
   --  @exception Layout_Error Header, geometry, or entries are corrupt
   procedure Attach
     (Item       : out View;
      Region     : Region_View;
      Location   : Region_Offset;
      Capacity   : Positive;
      Key_Size   : Positive;
      Value_Size : Positive);

   --  Detach Item without modifying the map.
   --  @param Item View to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item View to inspect
   --  @return True only while local mapping information is retained
   function Is_Attached (Item : View) return Boolean;

   --  Return the current occupied entry count.
   --  @param Item Attached synchronized view
   --  @return Number of keys currently present
   function Length (Item : View) return Natural;

   --  Insert Key and Value, or replace the value for an existing key.
   --  @param Item Exclusively synchronized map view
   --  @param Key Fixed-size key bytes
   --  @param Value Fixed-size value bytes
   --  @param Result Insert, replacement, or full-table outcome
   --  @exception Constraint_Error Key or Value has the wrong length
   procedure Put
     (Item   : in out View;
      Key    : Ada.Streams.Stream_Element_Array;
      Value  : Ada.Streams.Stream_Element_Array;
      Result : out Put_Result);

   --  Look up Key and copy its value when present.
   --  @param Item Exclusively synchronized map view
   --  @param Key Fixed-size key bytes
   --  @param Value Fixed-size destination, assigned only when Found is true
   --  @param Found True only when Key is present
   --  @exception Constraint_Error Key or Value has the wrong length
   procedure Get
     (Item  : View;
      Key   : Ada.Streams.Stream_Element_Array;
      Value : out Ada.Streams.Stream_Element_Array;
      Found : out Boolean);

   --  Remove Key when present, retaining a tombstone for probe continuity.
   --  @param Item Exclusively synchronized map view
   --  @param Key Fixed-size key bytes
   --  @param Removed True only when an occupied entry was deleted
   --  @exception Constraint_Error Key has the wrong length
   procedure Remove
     (Item    : in out View;
      Key     : Ada.Streams.Stream_Element_Array;
      Removed : out Boolean);

   --  Reset every entry to empty and set Length to zero.
   --  @param Item Exclusively synchronized map view
   procedure Clear (Item : in out View);

   --  Invalidate a quiescent map and detach Item.
   --  @param Item Exclusively synchronized map view
   procedure Destroy (Item : in out View);

private
   type View is limited record
      Core           : Layouts.Local_View;
      Capacity_Value : Interfaces.Unsigned_32 := 0;
      Key_Value      : Interfaces.Unsigned_32 := 0;
      Value_Value    : Interfaces.Unsigned_32 := 0;
      Mask           : Interfaces.Unsigned_64 := 0;
      Value_Offset   : Byte_Count := 0;
      Stride         : Byte_Count := 0;
   end record;
end Flyology.Data_Structures.Hash_Maps;
