with Flyology.Data_Structures.Storage_Types.Elements;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

use type Interfaces.Unsigned_64;

--  Provides a bounded multi-producer/multi-consumer ring of immutable
--  fixed-layout elements. Element creation and observation are bound once by
--  the generic adapter. Per-slot sequence counters and acquire/release/CAS
--  operations permit concurrent native tasks or processes to use distinct
--  mappings.
--  Try operations perform at most Contention_Limit claims and never wait on a
--  tasking primitive or syscall; Contended is a bounded failure outcome.
--  Timed Push and Pop yield between bounded claim campaigns until success or
--  one explicit timeout.
--  A participant that terminates after claiming a slot but before publishing
--  it can prevent later progress. Core does not detect participant death; an
--  external recovery authority may poison the ring and reinitialize it after
--  establishing quiescence. Attachment validates immutable identity and
--  geometry and may run while other attached views transfer elements;
--  destruction still requires quiescence and deeply validates mutable state.
--  Signed modular sequence ordering assumes that no paused operation is
--  overtaken by 2**63 completed claims; ordinary 64-bit counter wrap remains
--  supported within that horizon.
--  Attach, Create_Or_Attach, Detach, Initialize, Destroy, and backing-lifetime
--  changes must not race with any use of the same local View.
--  @formal Element Immutable byte-backed element adapter stored by this ring
generic
   with package Element is new
     Flyology.Data_Structures.Storage_Types.Elements (<>);
package Flyology.Data_Structures.Rings.MPMC with Preelaborate is

   --  Eight-byte magic stored in every MPMC header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_4D50_4D43_3031#;

   --  Schema identifier for the current per-slot-sequence algorithm.
   Schema : constant Interfaces.Unsigned_64 :=
     16#0001_4D50_4D43_0004# xor Element.Signature xor
     Interfaces.Shift_Left (Interfaces.Unsigned_64 (Element.Version), 32);

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 4;

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
   --  two and at least two so ready and free slot sequences remain distinct.
   --  @param Capacity Number of usable elements
   --  @return Required header, sequence counters, padding, and payload bytes
   --  @exception Constraint_Error Capacity is below two, not a power of two,
   --     or cannot be represented in the stored layout
   function Required_Storage (Capacity : Positive) return Byte_Count;

   --  Initialize an empty MPMC ring and attach Item. Every preexisting view
   --  becomes stale and must attach again.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero eight-byte-aligned stored offset
   --  @param Capacity Power-of-two usable element count
   procedure Initialize
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive);

   --  Atomically initialize a known-virgin zeroed extent or attach to a ready
   --  compatible ring. Only the exact zero lifecycle sentinel is eligible for
   --  creation; no existing lifecycle is reinitialized. The operation does
   --  not wait for another initializer.
   --  Concurrent calls are permitted while the allocation protocol guarantees
   --  virgin bytes or the existing ring is ready. A ready ring may be active.
   --  @param Item Attached view, or detached when initialization is in
   --     progress
   --  @param Region Independently attached backing region
   --  @param Location Stored ring offset
   --  @param Capacity Expected power-of-two usable element count
   --  @param Result Whether this caller initialized, attached, or observed an
   --     initialization in progress
   procedure Create_Or_Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Result       : out Open_Result);

   --  Attach to an existing MPMC ring and validate its published immutable
   --  identity, configuration, and complete extent. Other views may transfer
   --  elements concurrently; mutable positions and slot sequences therefore
   --  receive their deep validation only during quiescent destruction.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored ring offset
   --  @param Capacity Expected power-of-two element count
   --  @exception Layout_Error Header or geometry is corrupt or incompatible
   procedure Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive);

   --  Poison a ring after independently establishing that every participant
   --  is dead or quiescent. This is the fail-closed response to an abandoned
   --  slot claim; exclusive reinitialization is the recovery operation.
   --  @param Region Attached backing region
   --  @param Location Stored ring offset
   procedure Poison (Region : Region_View; Location : Region_Offset);

   --  Detach Item without modifying the ring.
   --  @param Item View to detach
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

   --  Attempt to claim and publish Data.
   --  @param Item Any concurrently attached producer view
   --  @param Data Application value accepted by the bound creator
   --  @param Result Published, full, or bounded-contention outcome
   procedure Try_Push
     (Item   : in out View;
      Data   : Element.Source;
      Result : out Push_Result);

   --  Wait through full or contended observations until Data is published or
   --  the monotonic timeout expires. The caller yields between campaigns.
   --  @param Item Any concurrently attached producer view
   --  @param Data Application value accepted by the bound creator
   --  @param Timeout Maximum wait; zero permits one bounded claim campaign
   --  @exception Timeout_Error No element is published by the deadline
   procedure Push
     (Item    : in out View;
      Data    : Element.Source;
      Timeout : Wait_Timeout);

   --  Attempt to claim and consume the oldest published element.
   --  @param Item Any concurrently attached consumer view
   --  @param Data Observation assigned only after a successful claim
   --  @param Result Consumed, empty, or bounded-contention outcome
   procedure Try_Pop
     (Item   : in out View;
      Data   : out Element.Observed;
      Result : out Pop_Result);

   --  Wait through empty or contended observations until one element is
   --  consumed or the monotonic timeout expires.
   --  @param Item Any concurrently attached consumer view
   --  @param Data Observation assigned only on success
   --  @param Timeout Maximum wait; zero permits one bounded claim campaign
   --  @exception Timeout_Error No element is consumed by the deadline
   procedure Pop
     (Item    : in out View;
      Data    : out Element.Observed;
      Timeout : Wait_Timeout);

   --  Invalidate an empty, quiescent ring and detach Item.
   --  @param Item Exclusively synchronized view
   --  @exception Program_Error The ring is not empty
   procedure Destroy (Item : in out View);

   pragma Inline (Try_Push, Try_Pop);

private
   type View is limited record
      Core            : Layouts.Local_View;
      Capacity_Value  : Interfaces.Unsigned_32 := 0;
      Element_Value   : Interfaces.Unsigned_32 := 0;
      Mask            : Interfaces.Unsigned_64 := 0;
      Payload_Offset  : Byte_Count := 0;
      Stride          : Byte_Count := 0;
      Enqueue_Address : System.Address := System.Null_Address;
      Dequeue_Address : System.Address := System.Null_Address;
   end record;
end Flyology.Data_Structures.Rings.MPMC;
