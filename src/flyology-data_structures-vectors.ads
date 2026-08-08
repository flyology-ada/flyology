with Ada.Streams;
with Interfaces;
private with Flyology.Data_Structures.Layouts;

--  Provides bounded vectors of fixed-size byte elements in relocatable
--  storage. Elements are explicit byte representations rather than arbitrary
--  Ada private values. Operations use one process-shared nonblocking
--  guard. Contention raises Busy_Error immediately; no operation waits or
--  retries. An exception after a mutation may have begun poisons the stored
--  object; Poison_Error then persists until exclusive reinitialization.
--  Is_Attached, Capacity, and Is_Poisoned inspect only local or lifecycle
--  metadata and do not acquire the payload guard.
package Flyology.Data_Structures.Vectors with Preelaborate is

   --  Eight-byte magic stored in every vector header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5356_4543_3031#;

   --  Schema identifier for the current vector layout.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_5645_4354_0002#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 2;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached vector view.
   type View is limited private;

   --  Compute the complete fixed-capacity vector extent.
   --  @param Capacity Maximum element count
   --  @param Element_Size Bytes per element
   --  @return Required header, padding, and element bytes
   function Required_Storage
     (Capacity : Positive; Element_Size : Positive) return Byte_Count;

   --  Initialize an empty vector and attach Item. Exclusive reinitialization
   --  is the only recovery from a poisoned lifecycle state.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero eight-byte-aligned stored offset
   --  @param Capacity Maximum element count
   --  @param Element_Size Bytes per element
   procedure Initialize
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive);

   --  Attach to a quiescent vector with the expected configuration.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored vector offset
   --  @param Capacity Expected maximum element count
   --  @param Element_Size Expected bytes per element
   --  @exception Layout_Error Header, geometry, or current length is corrupt
   procedure Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive);

   --  Detach Item without modifying the vector.
   --  @param Item View to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item View to inspect
   --  @return True only while local mapping information is retained
   function Is_Attached (Item : View) return Boolean;

   --  Return the maximum element count.
   --  @param Item Attached view
   --  @return Fixed vector capacity
   function Capacity (Item : View) return Natural;

   --  Return the current element count.
   --  @param Item Attached synchronized view
   --  @return Number of initialized elements
   function Length (Item : View) return Natural;

   --  Report whether an attached vector requires reinitialization.
   --  @param Item Attached view
   --  @return True only when the persisted lifecycle state is poisoned
   function Is_Poisoned (Item : View) return Boolean;

   --  Mark a quiescent vector poisoned. Before calling, the application must
   --  independently establish that no operation is active, including that a
   --  process or task which left the guard locked has terminated. Flyology
   --  performs no owner-death detection.
   --  @param Region Attached backing region
   --  @param Location Stored vector offset
   --  @exception Layout_Error The stored identity or lifecycle is invalid
   --  @exception Busy_Error The lifecycle changed during the poison attempt
   procedure Poison (Region : Region_View; Location : Region_Offset);

   --  Append one element without waiting.
   --  @param Item Internally synchronized attached vector view
   --  @param Data Source whose length must equal Element_Size
   --  @param Appended True only when capacity was available
   --  @exception Constraint_Error Data has the wrong length
   procedure Try_Append
     (Item     : in out View;
      Data     : Ada.Streams.Stream_Element_Array;
      Appended : out Boolean);

   --  Copy the one-based element at Index into Data.
   --  @param Item Internally synchronized attached vector view
   --  @param Index One-based initialized element position
   --  @param Data Destination whose length must equal Element_Size
   --  @exception Constraint_Error Index or Data length is invalid
   procedure Read
     (Item  : View;
      Index : Positive;
      Data  : out Ada.Streams.Stream_Element_Array);

   --  Replace the one-based element at Index.
   --  @param Item Internally synchronized attached vector view
   --  @param Index One-based initialized element position
   --  @param Data Source whose length must equal Element_Size
   --  @exception Constraint_Error Index or Data length is invalid
   procedure Replace
     (Item  : in out View;
      Index : Positive;
      Data  : Ada.Streams.Stream_Element_Array);

   --  Copy and remove the last element without waiting. Empty vectors return
   --  Popped false and do not assign Data.
   --  @param Item Internally synchronized attached vector view
   --  @param Data Destination whose length must equal Element_Size
   --  @param Popped True only when an element was removed
   procedure Try_Pop
     (Item   : in out View;
      Data   : out Ada.Streams.Stream_Element_Array;
      Popped : out Boolean);

   --  Set Length to zero without rewriting payload bytes.
   --  @param Item Internally synchronized attached vector view
   procedure Clear (Item : in out View);

   --  Invalidate a quiescent vector and detach Item.
   --  @param Item Exclusively synchronized vector view
   procedure Destroy (Item : in out View);

   pragma Inline
     (Capacity, Length, Is_Poisoned, Try_Append, Read, Replace, Try_Pop,
      Clear);

private
   type View is limited record
      Core            : Layouts.Local_View;
      Guard_Address   : System.Address := System.Null_Address;
      Length_Address  : System.Address := System.Null_Address;
      Payload_Address : System.Address := System.Null_Address;
      Payload_Extent  : Byte_Count := 0;
      Capacity_Value  : Interfaces.Unsigned_32 := 0;
      Element_Value   : Interfaces.Unsigned_32 := 0;
      Stride          : Byte_Count := 0;
   end record;
end Flyology.Data_Structures.Vectors;
