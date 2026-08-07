with Ada.Streams;
with Interfaces;
private with Flyology.Data_Structures.Layouts;

--  Provides a bounded single-producer/single-consumer ring of fixed-size byte
--  elements. Exactly one producer may call Try_Push and exactly one consumer
--  may call Try_Pop at a time; they may be native tasks or processes using
--  different mappings. Acquire/release publication makes payload transfer
--  explicit. Attachment and destruction require quiescence. Operations never
--  wait, allocate, enter the Flyology scheduler, or invoke a blocking syscall.
package Flyology.Data_Structures.Rings.SPSC with Preelaborate is

   --  Eight-byte magic stored in every SPSC header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5350_5343_3031#;

   --  Schema identifier for the current SPSC layout and memory ordering.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_5350_5343_0001#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 1;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached ring view.
   type View is limited private;

   --  Immutable validated SPSC configuration.
   --  @field Capacity Number of usable elements
   --  @field Element_Size Bytes copied by each push or pop
   --  @field Extent Complete stored layout size
   type Metadata is record
      Capacity     : Interfaces.Unsigned_32;
      Element_Size : Interfaces.Unsigned_32;
      Extent       : Byte_Count;
   end record;

   --  Compute the complete SPSC layout extent. Capacity must be a power of
   --  two so hot-path slot selection uses a mask.
   --  @param Capacity Power-of-two number of usable elements
   --  @param Element_Size Bytes per element
   --  @return Required header, padding, and payload bytes
   --  @exception Constraint_Error Capacity or arithmetic is invalid
   function Required_Storage
     (Capacity : Positive; Element_Size : Positive) return Byte_Count;

   --  Initialize a new empty ring and attach Item. The caller exclusively
   --  owns the target extent until ready-state publication completes.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero eight-byte-aligned stored offset
   --  @param Capacity Power-of-two number of usable elements
   --  @param Element_Size Bytes per element
   procedure Initialize
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive);

   --  Attach to a quiescent initialized ring and validate configuration and
   --  producer/consumer indices.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored ring offset
   --  @param Capacity Expected usable element count
   --  @param Element_Size Expected bytes per element
   --  @exception Layout_Error Header, configuration, or indices are corrupt
   procedure Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive);

   --  Detach Item without changing the ring.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item View to inspect
   --  @return True only while local mapping information is retained
   function Is_Attached (Item : View) return Boolean;

   --  Return immutable validated configuration.
   --  @param Item Attached ring view
   --  @return Capacity, element size, and stored extent
   function Current_Metadata (Item : View) return Metadata;

   --  Copy Data into the next element and publish it with a release store.
   --  The sole producer calls this operation. A full ring returns immediately
   --  with Pushed false and leaves Data untouched.
   --  @param Item Producer's attached view
   --  @param Data Source whose length must equal Element_Size
   --  @param Pushed True only when the element was published
   --  @exception Constraint_Error Data has the wrong length
   --  @exception Layout_Error Stored indices are corrupt
   procedure Try_Push
     (Item   : in out View;
      Data   : Ada.Streams.Stream_Element_Array;
      Pushed : out Boolean);

   --  Acquire and copy the next element into Data. The sole consumer calls
   --  this operation. An empty ring returns immediately with Popped false and
   --  does not assign Data.
   --  @param Item Consumer's attached view
   --  @param Data Destination whose length must equal Element_Size
   --  @param Popped True only when an element was consumed
   --  @exception Constraint_Error Data has the wrong length
   --  @exception Layout_Error Stored indices are corrupt
   procedure Try_Pop
     (Item   : in out View;
      Data   : out Ada.Streams.Stream_Element_Array;
      Popped : out Boolean);

   --  Invalidate an empty, quiescent ring and detach Item.
   --  @param Item Exclusively synchronized ring view
   --  @exception Program_Error The ring is not empty
   procedure Destroy (Item : in out View);

   pragma Inline (Try_Push, Try_Pop);

private
   type View is limited record
      Core           : Layouts.Local_View;
      Capacity_Value : Interfaces.Unsigned_32 := 0;
      Element_Value  : Interfaces.Unsigned_32 := 0;
      Mask           : Interfaces.Unsigned_64 := 0;
      Stride         : Byte_Count := 0;
   end record;
end Flyology.Data_Structures.Rings.SPSC;
