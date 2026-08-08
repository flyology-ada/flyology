with Ada.Streams;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

--  Provides a bounded single-producer/single-consumer ring of fixed-size byte
--  elements. Exactly one producer may call Try_Push and exactly one consumer
--  may call Try_Pop at a time; they may be native tasks or processes using
--  different mappings. Acquire/release publication makes payload transfer
--  explicit. Attachment and destruction require quiescence. Try operations
--  never wait; timed Push and Pop yield without invoking a blocking syscall.
--  Attach, Create_Or_Attach, Detach, Initialize, Destroy, and backing-lifetime
--  changes must not race with any use of the same local View.
package Flyology.Data_Structures.Rings.SPSC with Preelaborate is

   --  Eight-byte magic stored in every SPSC header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5350_5343_3031#;

   --  Schema identifier for the current SPSC layout and memory ordering.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_5350_5343_0003#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 3;

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
   --  owns the target extent until ready-state publication completes. Every
   --  preexisting view becomes stale and must attach again.
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

   --  Atomically initialize a known-virgin zeroed extent or attach to a ready
   --  compatible ring. Only the exact zero lifecycle sentinel is eligible for
   --  creation; no existing lifecycle is reinitialized. The operation does
   --  not wait for another initializer.
   --  Concurrent calls are permitted only while the allocation protocol
   --  guarantees virgin bytes; if Ready may exist, Attach quiescence applies.
   --  @param Item Attached view, or detached when initialization is in
   --     progress
   --  @param Region Independently attached backing region
   --  @param Location Stored ring offset
   --  @param Capacity Expected power-of-two usable element count
   --  @param Element_Size Expected bytes per element
   --  @param Result Whether this caller initialized, attached, or observed an
   --     initialization in progress
   procedure Create_Or_Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive;
      Result       : out Open_Result);

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

   --  Poison a ready ring after independently establishing that its producer
   --  and consumer are dead or quiescent. Operations and attachment then fail
   --  closed until exclusive reinitialization.
   --  @param Region Attached backing region
   --  @param Location Stored ring offset
   procedure Poison (Region : Region_View; Location : Region_Offset);

   --  Detach Item without changing the ring.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item View to inspect
   --  @return True while local mapping information is retained; this does not
   --     guarantee the cached initialization epoch is still current
   function Is_Attached (Item : View) return Boolean;

   --  Report whether Item's backing ring was explicitly poisoned.
   --  @param Item Attached ring view
   --  @return True only when the shared lifecycle state is Poisoned
   function Is_Poisoned (Item : View) return Boolean;

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

   --  Wait until Data is published or the monotonic timeout expires. The sole
   --  producer yields between full-ring observations.
   --  @param Item Producer's attached view
   --  @param Data Source whose length must equal Element_Size
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @exception Timeout_Error The ring remains full through the deadline
   procedure Push
     (Item    : in out View;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout);

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

   --  Wait until one element is consumed or the monotonic timeout expires.
   --  The sole consumer yields between empty-ring observations.
   --  @param Item Consumer's attached view
   --  @param Data Exact-size destination, assigned only on success
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @exception Timeout_Error The ring remains empty through the deadline
   procedure Pop
     (Item    : in out View;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout);

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
      Head_Address   : System.Address := System.Null_Address;
      Tail_Address   : System.Address := System.Null_Address;
   end record;
end Flyology.Data_Structures.Rings.SPSC;
