with Ada.Streams;
with Flyology.Data_Structures.Arenas;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

--  Provides growable open-addressed maps from fixed-size byte keys to
--  fixed-size byte values. The fixed map header stores an arena incarnation,
--  current table geometry, and generation-stamped allocation handles. Linear
--  probing uses cached native addresses only for the duration of one checked
--  process-local allocation view. Insertion grows and rehashes before
--  publishing a replacement table. One persisted nonblocking map guard
--  serializes operations across mappings; arena contention is reported in the
--  insertion result. Lifecycle operations and detachment require exclusion.
package Flyology.Data_Structures.Dynamic.Hash_Maps with Preelaborate is

   --  Eight-byte magic stored in every dynamic-map header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_4448_4D41_3031#;

   --  Schema for the FNV-1a, linear-probe, arena-backed map contract.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_4448_4D41_0001#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 1;

   --  Complete stable layout identity for envelopes and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached dynamic-map view.
   type View is limited private;

   --  Insertion outcome.
   --  @enum Put_Inserted A previously absent key was inserted
   --  @enum Put_Replaced An existing key's value was replaced
   --  @enum Put_Arena_Exhausted No arena block can satisfy table growth
   --  @enum Put_Arena_Contended Another caller owns arena metadata
   type Put_Result is
     (Put_Inserted, Put_Replaced, Put_Arena_Exhausted,
      Put_Arena_Contended);

   --  Return the fixed outer header extent.
   --  @return Complete dynamic-map header bytes
   function Required_Storage return Byte_Count;

   --  Destructively initialize an empty map bound to Arena.
   --  @param Item View attached on success
   --  @param Region Region containing the fixed map header
   --  @param Location Nonzero eight-byte-aligned map-header offset
   --  @param Arena Attached arena used for table allocations
   --  @param Initial_Capacity Power-of-two first table capacity, at least two
   --  @param Key_Size Fixed bytes in every key
   --  @param Value_Size Fixed bytes in every value
   procedure Initialize
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arenas.View;
      Initial_Capacity : Positive;
      Key_Size         : Positive;
      Value_Size       : Positive);

   --  Initialize virgin bytes or attach to an exact compatible map. Initial
   --  capacity, key/value sizes, and arena identity/incarnation must match.
   --  @param Item Attached view or detached view during another initialization
   --  @param Region Region containing the fixed map header
   --  @param Location Stored map-header offset
   --  @param Arena Expected attached arena
   --  @param Initial_Capacity Expected first table capacity
   --  @param Key_Size Expected fixed key bytes
   --  @param Value_Size Expected fixed value bytes
   --  @param Result Creation, attachment, or in-progress outcome
   procedure Create_Or_Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arenas.View;
      Initial_Capacity : Positive;
      Key_Size         : Positive;
      Value_Size       : Positive;
      Result           : out Open_Result);

   --  Attach to a quiescent map and validate its complete probe table and any
   --  deferred allocation handle.
   --  @param Item View attached on success
   --  @param Region Region containing the fixed map header
   --  @param Location Stored map-header offset
   --  @param Arena Expected attached arena and incarnation
   --  @param Initial_Capacity Expected first table capacity
   --  @param Key_Size Expected fixed key bytes
   --  @param Value_Size Expected fixed value bytes
   --  @exception Layout_Error Configuration or table contents are corrupt
   --  @exception Busy_Error The map guard is active or abandoned
   procedure Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arenas.View;
      Initial_Capacity : Positive;
      Key_Size         : Positive;
      Value_Size       : Positive);

   --  Detach Item without changing its header or allocations.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item retains local mapping information.
   --  @param Item View to inspect
   --  @return True while the local header view is attached
   function Is_Attached (Item : View) return Boolean;

   --  Report whether the map lifecycle is poisoned.
   --  @param Item Attached map view
   --  @return True only for a persisted poisoned lifecycle
   function Is_Poisoned (Item : View) return Boolean;

   --  Poison a quiescent or abandoned-locked map after external recovery
   --  authority establishes owner death and quiescence.
   --  @param Region Region containing the fixed map header
   --  @param Location Stored map-header offset
   procedure Poison (Region : Region_View; Location : Region_Offset);

   --  Return the current table capacity.
   --  @param Item Internally synchronized map view
   --  @return Current power-of-two slot capacity, initially zero
   function Capacity (Item : View) return Natural;

   --  Return the occupied entry count.
   --  @param Item Internally synchronized map view
   --  @return Number of keys currently present
   function Length (Item : View) return Natural;

   --  Insert Key and Value or replace an existing value. New keys trigger
   --  growth before the table exceeds three-quarters occupancy.
   --  @param Item Internally synchronized map view
   --  @param Arena Matching attached arena view
   --  @param Key Fixed-size key bytes
   --  @param Value Fixed-size value bytes
   --  @param Result Insert, replacement, exhaustion, or arena contention
   procedure Put
     (Item   : in out View;
      Arena  : in out Arenas.View;
      Key    : Ada.Streams.Stream_Element_Array;
      Value  : Ada.Streams.Stream_Element_Array;
      Result : out Put_Result);

   --  Look up Key and copy its value when present.
   --  @param Item Internally synchronized map view
   --  @param Arena Matching attached arena view
   --  @param Key Fixed-size key bytes
   --  @param Value Fixed-size destination assigned only when Found is true
   --  @param Found True only when Key is present
   procedure Get
     (Item  : View;
      Arena : Arenas.View;
      Key   : Ada.Streams.Stream_Element_Array;
      Value : out Ada.Streams.Stream_Element_Array;
      Found : out Boolean);

   --  Remove Key while retaining a tombstone for probe continuity.
   --  @param Item Internally synchronized map view
   --  @param Arena Matching attached arena view
   --  @param Key Fixed-size key bytes
   --  @param Removed True only when Key was present
   procedure Remove
     (Item    : in out View;
      Arena   : Arenas.View;
      Key     : Ada.Streams.Stream_Element_Array;
      Removed : out Boolean);

   --  Reset every current slot to empty without releasing table capacity.
   --  @param Item Internally synchronized map view
   --  @param Arena Matching attached arena view
   procedure Clear (Item : in out View; Arena : Arenas.View);

   --  Release current and deferred tables, destroy the quiescent header, and
   --  detach Item.
   --  @param Item Exclusively synchronized map view
   --  @param Arena Matching attached arena view
   procedure Destroy (Item : in out View; Arena : in out Arenas.View);

private
   type View is limited record
      Core             : Layouts.Local_View;
      Guard_Address    : System.Address := System.Null_Address;
      Count_Address    : System.Address := System.Null_Address;
      Capacity_Address : System.Address := System.Null_Address;
      Capacity_Check_Address : System.Address := System.Null_Address;
      Current_Address  : System.Address := System.Null_Address;
      Retired_Address  : System.Address := System.Null_Address;
      Initial_Value    : Interfaces.Unsigned_32 := 0;
      Key_Value        : Interfaces.Unsigned_32 := 0;
      Value_Value      : Interfaces.Unsigned_32 := 0;
      Arena_ID_Value   : Interfaces.Unsigned_64 := 0;
      Arena_Epoch_Value : Interfaces.Unsigned_32 := 0;
      Value_Offset     : Byte_Count := 0;
      Stride           : Byte_Count := 0;
   end record;
end Flyology.Data_Structures.Dynamic.Hash_Maps;
