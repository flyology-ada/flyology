with Ada.Streams;
with Interfaces;
private with Flyology.Data_Structures.Layouts;

--  Provides a bounded multi-producer/multi-consumer ring of fixed-size byte
--  elements. Per-slot sequence counters and acquire/release/CAS operations
--  permit concurrent native tasks or processes to use distinct mappings.
--  Try operations perform at most Contention_Limit claims and never wait on a
--  tasking primitive or syscall; Contended is a bounded failure outcome.
--  A participant that terminates after claiming a slot but before publishing
--  it can prevent later progress, so this package provides no process-death
--  recovery. Attachment and destruction require quiescence.
package Flyology.Data_Structures.Rings.MPMC with Preelaborate is

   --  Eight-byte magic stored in every MPMC header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_4D50_4D43_3031#;

   --  Schema identifier for the current per-slot-sequence algorithm.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_4D50_4D43_0001#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 1;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Maximum compare/exchange claim attempts in one operation.
   Contention_Limit : constant Positive := 64;

   --  Process-local attached MPMC view.
   type View is limited private;

   --  Producer outcome.
   --  @enum Pushed The element was claimed and published
   --  @enum Full Every usable slot was occupied
   --  @enum Push_Contended The bounded claim-attempt budget was exhausted
   type Push_Result is (Pushed, Full, Push_Contended);

   --  Consumer outcome.
   --  @enum Popped One element was claimed and consumed
   --  @enum Empty No published element was available
   --  @enum Pop_Contended The bounded claim-attempt budget was exhausted
   type Pop_Result is (Popped, Empty, Pop_Contended);

   --  Compute the complete MPMC layout extent. Capacity must be a power of
   --  two so hot-path slot selection uses a mask.
   --  @param Capacity Number of usable elements
   --  @param Element_Size Bytes per element
   --  @return Required header, sequence counters, padding, and payload bytes
   --  @exception Constraint_Error Capacity is not a power of two
   function Required_Storage
     (Capacity : Positive; Element_Size : Positive) return Byte_Count;

   --  Initialize an empty MPMC ring and attach Item.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero eight-byte-aligned stored offset
   --  @param Capacity Power-of-two usable element count
   --  @param Element_Size Bytes per element
   procedure Initialize
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive);

   --  Attach to a quiescent existing MPMC ring and validate configuration and
   --  claim positions.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored ring offset
   --  @param Capacity Expected power-of-two element count
   --  @param Element_Size Expected bytes per element
   --  @exception Layout_Error Header, geometry, or positions are corrupt
   procedure Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive);

   --  Detach Item without modifying the ring.
   --  @param Item View to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item View to inspect
   --  @return True only while local mapping information is retained
   function Is_Attached (Item : View) return Boolean;

   --  Attempt to claim and publish Data.
   --  @param Item Any concurrently attached producer view
   --  @param Data Source whose length must equal Element_Size
   --  @param Result Published, full, or bounded-contention outcome
   --  @exception Constraint_Error Data has the wrong length
   procedure Try_Push
     (Item   : in out View;
      Data   : Ada.Streams.Stream_Element_Array;
      Result : out Push_Result);

   --  Attempt to claim and consume the oldest published element.
   --  @param Item Any concurrently attached consumer view
   --  @param Data Destination whose length must equal Element_Size
   --  @param Result Consumed, empty, or bounded-contention outcome
   --  @exception Constraint_Error Data has the wrong length
   procedure Try_Pop
     (Item   : in out View;
      Data   : out Ada.Streams.Stream_Element_Array;
      Result : out Pop_Result);

   --  Invalidate an empty, quiescent ring and detach Item.
   --  @param Item Exclusively synchronized view
   --  @exception Program_Error The ring is not empty
   procedure Destroy (Item : in out View);

   pragma Inline (Try_Push, Try_Pop);

private
   type View is limited record
      Core           : Layouts.Local_View;
      Capacity_Value : Interfaces.Unsigned_32 := 0;
      Element_Value  : Interfaces.Unsigned_32 := 0;
      Mask           : Interfaces.Unsigned_64 := 0;
      Payload_Offset : Byte_Count := 0;
      Stride         : Byte_Count := 0;
   end record;
end Flyology.Data_Structures.Rings.MPMC;
