with Ada.Streams;
with Interfaces;
private with Flyology.Data_Structures.Layouts;

--  Provides bounded variable-length byte strings in relocatable storage.
--  Values are byte sequences, not text encodings, and never contain hidden
--  Ada metadata. The package is not internally synchronized; all operations
--  on all views of one string require application-level exclusion.
package Flyology.Data_Structures.Byte_Strings with Preelaborate is

   --  Eight-byte magic stored in every byte-string header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5342_5354_3031#;

   --  Schema identifier for the current byte-string layout.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_4253_5452_0001#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 1;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached view.
   type View is limited private;

   --  Compute storage for a string with Maximum_Length payload bytes.
   --  @param Maximum_Length Maximum retained byte count
   --  @return Required header and payload bytes
   function Required_Storage (Maximum_Length : Positive) return Byte_Count;

   --  Initialize an empty string and attach Item.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero eight-byte-aligned stored offset
   --  @param Maximum_Length Fixed payload capacity
   procedure Initialize
     (Item           : out View;
      Region         : Region_View;
      Location       : Region_Offset;
      Maximum_Length : Positive);

   --  Attach to a quiescent existing string and validate its expected
   --  capacity.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored string offset
   --  @param Maximum_Length Expected payload capacity
   --  @exception Layout_Error Header, capacity, or current length is corrupt
   procedure Attach
     (Item           : out View;
      Region         : Region_View;
      Location       : Region_Offset;
      Maximum_Length : Positive);

   --  Detach Item without modifying the string.
   --  @param Item View to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item View to inspect
   --  @return True only while local mapping information is retained
   function Is_Attached (Item : View) return Boolean;

   --  Return the fixed payload capacity.
   --  @param Item Attached view
   --  @return Maximum retained byte count
   function Capacity (Item : View) return Natural;

   --  Return the current retained length.
   --  @param Item Attached synchronized view
   --  @return Number of initialized payload bytes
   function Length (Item : View) return Natural;

   --  Replace the string with Data.
   --  @param Item Exclusively synchronized view
   --  @param Data Replacement bytes
   --  @exception Constraint_Error Data exceeds Capacity
   procedure Assign
     (Item : in out View; Data : Ada.Streams.Stream_Element_Array);

   --  Append Data to the current string.
   --  @param Item Exclusively synchronized view
   --  @param Data Bytes appended in order
   --  @exception Constraint_Error The resulting length exceeds Capacity
   procedure Append
     (Item : in out View; Data : Ada.Streams.Stream_Element_Array);

   --  Copy the current string into Data, whose length must equal Length.
   --  @param Item Exclusively synchronized view
   --  @param Data Exact-size destination
   --  @exception Constraint_Error Data has the wrong length
   procedure Read
     (Item : View; Data : out Ada.Streams.Stream_Element_Array);

   --  Set the current length to zero without rewriting retained payload bytes.
   --  @param Item Exclusively synchronized view
   procedure Clear (Item : in out View);

   --  Invalidate a quiescent string and detach Item.
   --  @param Item Exclusively synchronized view
   procedure Destroy (Item : in out View);

   pragma Inline (Capacity, Length, Assign, Append, Read, Clear);

private
   type View is limited record
      Core           : Layouts.Local_View;
      Capacity_Value : Interfaces.Unsigned_32 := 0;
   end record;
end Flyology.Data_Structures.Byte_Strings;
