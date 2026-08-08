with Ada.Streams;
with Flyology.Data_Structures.Arenas;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

--  Provides growable vectors of fixed-size byte representations. The vector
--  header remains at one relocatable region offset while payload storage is a
--  generation-stamped arena allocation. Growth allocates and copies before
--  publishing the replacement handle. Operations are serialized across
--  mappings by the vector's persisted nonblocking guard; arena contention is
--  reported separately through Growth_Result. Neither guard spins or waits.
--  Callers must exclude lifecycle operations and local View detachment from
--  ordinary use of that same View, and must keep the supplied arena attached.
--  A vector and its arena may be mapped at different native addresses.
package Flyology.Data_Structures.Dynamic.Vectors with Preelaborate is

   --  Eight-byte magic stored in every dynamic-vector header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_4456_4543_3031#;

   --  Schema identifier for the arena-backed vector layout and growth policy.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_4456_4543_0001#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 1;

   --  Complete stable layout identity for envelopes and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached dynamic-vector view.
   type View is limited private;

   --  Return the fixed header extent. Payload bytes are allocated separately
   --  from the receiving arena.
   --  @return Complete stored dynamic-vector header bytes
   function Required_Storage return Byte_Count;

   --  Destructively initialize an empty vector. Existing payload allocations
   --  are not inferred or reclaimed from overwritten bytes; the caller must
   --  retire dependent views and allocations before recovery initialization.
   --  @param Item View attached on success
   --  @param Region Region containing the fixed vector header
   --  @param Location Nonzero eight-byte-aligned vector-header offset
   --  @param Arena Attached arena used for all future payload allocations
   --  @param Initial_Capacity First element capacity requested on growth
   --  @param Element_Size Bytes in every explicit element representation
   procedure Initialize
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arenas.View;
      Initial_Capacity : Positive;
      Element_Size     : Positive);

   --  Initialize allocation-certified virgin bytes or attach to a compatible
   --  ready vector. Initial capacity, element size, and arena instance
   --  identity must exactly match an existing header.
   --  @param Item Attached view or detached view during another initialization
   --  @param Region Region containing the fixed vector header
   --  @param Location Stored vector-header offset
   --  @param Arena Expected attached arena instance
   --  @param Initial_Capacity Expected first-growth capacity
   --  @param Element_Size Expected fixed element bytes
   --  @param Result Creation, attachment, or in-progress outcome
   procedure Create_Or_Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arenas.View;
      Initial_Capacity : Positive;
      Element_Size     : Positive;
      Result           : out Open_Result);

   --  Attach to a quiescent vector and validate its header plus every current
   --  or deferred arena allocation handle.
   --  @param Item View attached on success
   --  @param Region Region containing the vector header
   --  @param Location Stored vector-header offset
   --  @param Arena Expected attached arena instance and incarnation
   --  @param Initial_Capacity Expected first-growth capacity
   --  @param Element_Size Expected element representation size
   --  @exception Layout_Error Configuration or mutable state is incompatible
   --  @exception Busy_Error The vector guard is active or abandoned
   procedure Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arenas.View;
      Initial_Capacity : Positive;
      Element_Size     : Positive);

   --  Detach Item without modifying its header or arena allocations.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item retains local mapping information.
   --  @param Item View to inspect
   --  @return True while the local header view is attached
   function Is_Attached (Item : View) return Boolean;

   --  Report whether the vector lifecycle is poisoned.
   --  @param Item Attached vector view
   --  @return True only for a persisted poisoned lifecycle
   function Is_Poisoned (Item : View) return Boolean;

   --  Poison a ready or abandoned-locked vector after independently proving
   --  operation quiescence and owner death where applicable.
   --  @param Region Region containing the fixed vector header
   --  @param Location Stored vector-header offset
   procedure Poison (Region : Region_View; Location : Region_Offset);

   --  Return the currently allocated element capacity. This operation takes
   --  the vector guard because capacity changes during growth.
   --  @param Item Internally synchronized vector view
   --  @return Current element capacity, initially zero
   function Capacity (Item : View) return Natural;

   --  Return the current initialized element count.
   --  @param Item Internally synchronized vector view
   --  @return Number of initialized elements
   function Length (Item : View) return Natural;

   --  Append one element, growing through Arena when required.
   --  @param Item Internally synchronized vector view
   --  @param Arena Matching attached arena view
   --  @param Data Source whose length must equal Element_Size
   --  @param Result Completion, arena exhaustion, or arena contention
   --  @exception Busy_Error Another caller owns the vector guard
   procedure Try_Append
     (Item   : in out View;
      Arena  : in out Arenas.View;
      Data   : Ada.Streams.Stream_Element_Array;
      Result : out Growth_Result);

   --  Copy the one-based initialized element at Index into Data.
   --  @param Item Internally synchronized vector view
   --  @param Arena Matching attached arena view
   --  @param Index One-based initialized element position
   --  @param Data Destination whose length must equal Element_Size
   procedure Read
     (Item  : View;
      Arena : Arenas.View;
      Index : Positive;
      Data  : out Ada.Streams.Stream_Element_Array);

   --  Replace the one-based initialized element at Index.
   --  @param Item Internally synchronized vector view
   --  @param Arena Matching attached arena view
   --  @param Index One-based initialized element position
   --  @param Data Source whose length must equal Element_Size
   procedure Replace
     (Item  : in out View;
      Arena : Arenas.View;
      Index : Positive;
      Data  : Ada.Streams.Stream_Element_Array);

   --  Copy and remove the last element. Empty vectors return Popped false and
   --  do not assign Data or release their retained allocation.
   --  @param Item Internally synchronized vector view
   --  @param Arena Matching attached arena view
   --  @param Data Destination whose length must equal Element_Size
   --  @param Popped True only when an element was removed
   procedure Try_Pop
     (Item   : in out View;
      Arena  : Arenas.View;
      Data   : out Ada.Streams.Stream_Element_Array;
      Popped : out Boolean);

   --  Set Length to zero without releasing current payload capacity.
   --  @param Item Internally synchronized vector view
   procedure Clear (Item : in out View);

   --  Release current and deferred allocations, destroy the quiescent header,
   --  and detach Item. Arena contention raises Busy_Error before an allocation
   --  that could not be reclaimed is forgotten.
   --  @param Item Exclusively synchronized vector view
   --  @param Arena Matching attached arena view
   procedure Destroy (Item : in out View; Arena : in out Arenas.View);

private
   type View is limited record
      Core             : Layouts.Local_View;
      Guard_Address    : System.Address := System.Null_Address;
      Length_Address   : System.Address := System.Null_Address;
      Capacity_Address : System.Address := System.Null_Address;
      Capacity_Check_Address : System.Address := System.Null_Address;
      Current_Address  : System.Address := System.Null_Address;
      Retired_Address  : System.Address := System.Null_Address;
      Initial_Value    : Interfaces.Unsigned_32 := 0;
      Element_Value    : Interfaces.Unsigned_32 := 0;
      Arena_ID_Value   : Interfaces.Unsigned_64 := 0;
      Arena_Epoch_Value : Interfaces.Unsigned_32 := 0;
   end record;
end Flyology.Data_Structures.Dynamic.Vectors;
