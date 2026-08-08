with Ada.Streams;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

--  Provides bounded open-addressed maps from fixed-size byte keys to
--  fixed-size byte values. Capacity is a power of two and probing is linear
--  over cached fixed-stride entries. Stored data contains only state scalars,
--  hashes, keys, and values. Ordinary operations are internally serialized
--  across mappings by one process-capable stored guard. Immediate operations
--  make one acquisition attempt and raise Busy_Error; timed overloads yield
--  and retry through one explicit timeout. Except for concurrent
--  Create_Or_Attach calls on allocation-certified virgin bytes, lifecycle
--  operations require whole-object quiescence.
--  The application must exclude Attach, Create_Or_Attach, Detach, Initialize,
--  Destroy, and backing-lifetime changes from every use of the same local
--  View. Separate attached views may perform ordinary operations concurrently.
package Flyology.Data_Structures.Hash_Maps with Preelaborate is

   --  Eight-byte magic stored in every map header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5348_4D41_3031#;

   --  Schema identifier for the current FNV-1a/open-addressed layout.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_484D_4150_0003#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 3;

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

   --  Initialize an empty map and attach Item. Every preexisting view becomes
   --  stale and must attach again before use.
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

   --  Atomically initialize a known-virgin zeroed extent or attach to a ready
   --  compatible map. Only the exact zero lifecycle sentinel is eligible for
   --  creation; no existing lifecycle is reinitialized. The operation does
   --  not wait for another initializer or for the map guard.
   --  Concurrent calls are permitted only while the allocation protocol
   --  guarantees virgin bytes; if Ready may exist, Attach quiescence applies.
   --  @param Item Attached view, or detached when initialization is in
   --     progress
   --  @param Region Independently attached backing region
   --  @param Location Stored map offset
   --  @param Capacity Expected power-of-two capacity
   --  @param Key_Size Expected key size
   --  @param Value_Size Expected value size
   --  @param Result Whether this caller initialized, attached, or observed an
   --     initialization in progress
   procedure Create_Or_Attach
     (Item       : out View;
      Region     : Region_View;
      Location   : Region_Offset;
      Capacity   : Positive;
      Key_Size   : Positive;
      Value_Size : Positive;
      Result     : out Open_Result);

   --  Attach to a quiescent map, validating its expected geometry, entry
   --  states and count, fixed-key hashes, linear-probe reachability, and key
   --  uniqueness.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored map offset
   --  @param Capacity Expected power-of-two capacity
   --  @param Key_Size Expected key size
   --  @param Value_Size Expected value size
   --  @exception Layout_Error Header, geometry, or entries are corrupt
   --  @exception Busy_Error The map guard is active or abandoned
   --  @exception Poison_Error The map is poisoned
   procedure Attach
     (Item       : out View;
      Region     : Region_View;
      Location   : Region_Offset;
      Capacity   : Positive;
      Key_Size   : Positive;
      Value_Size : Positive);

   --  Poison a ready or abandoned-locked map after independently establishing
   --  that no live owner can still mutate it. This recovery operation
   --  validates the map identity without attaching mutable contents.
   --  Poisoning is permanent until exclusive reinitialization.
   --  @param Region Attached backing region
   --  @param Location Stored map offset
   --  @exception Layout_Error The location is incomplete or has another
   --  identity
   --  @exception Busy_Error The lifecycle changed during the poison attempt
   procedure Poison (Region : Region_View; Location : Region_Offset);

   --  Detach Item without modifying the map.
   --  @param Item View to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item View to inspect
   --  @return True while local mapping information is retained; this does not
   --     guarantee the cached initialization epoch is still current
   function Is_Attached (Item : View) return Boolean;

   --  Report whether Item's backing map was explicitly poisoned.
   --  @param Item Attached map view
   --  @return True only when the shared lifecycle state is Poisoned
   --  @exception Region_Error Item is detached
   function Is_Poisoned (Item : View) return Boolean;

   --  Return the current occupied entry count.
   --  @param Item Attached view
   --  @return Number of keys currently present
   --  @exception Busy_Error Another operation owns the guard
   --  @exception Poison_Error The map is poisoned
   function Length (Item : View) return Natural;

   --  Return Length after waiting for the shared map guard.
   --  @param Item Attached map view
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @return Number of keys currently present
   --  @exception Timeout_Error The guard remains owned through the deadline
   function Length (Item : View; Timeout : Wait_Timeout) return Natural;

   --  Insert Key and Value, or replace the value for an existing key.
   --  @param Item Attached map view
   --  @param Key Fixed-size key bytes
   --  @param Value Fixed-size value bytes
   --  @param Result Insert, replacement, or full-table outcome
   --  @exception Constraint_Error Key or Value has the wrong length
   --  @exception Busy_Error Another operation owns the guard
   --  @exception Poison_Error The map is poisoned
   procedure Put
     (Item   : in out View;
      Key    : Ada.Streams.Stream_Element_Array;
      Value  : Ada.Streams.Stream_Element_Array;
      Result : out Put_Result);

   --  Insert or replace after waiting for the shared guard.
   --  @param Item Attached map view
   --  @param Key Fixed-size key bytes
   --  @param Value Fixed-size value bytes
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @param Result Insert, replacement, or full-table outcome
   --  @exception Timeout_Error The guard remains owned through the deadline
   procedure Put
     (Item    : in out View;
      Key     : Ada.Streams.Stream_Element_Array;
      Value   : Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout;
      Result  : out Put_Result);

   --  Look up Key and copy its value when present.
   --  @param Item Attached map view
   --  @param Key Fixed-size key bytes
   --  @param Value Fixed-size destination, assigned only when Found is true
   --  @param Found True only when Key is present
   --  @exception Constraint_Error Key or Value has the wrong length
   --  @exception Busy_Error Another operation owns the guard
   --  @exception Poison_Error The map is poisoned
   procedure Get
     (Item  : View;
      Key   : Ada.Streams.Stream_Element_Array;
      Value : out Ada.Streams.Stream_Element_Array;
      Found : out Boolean);

   --  Look up Key after waiting for the shared guard.
   --  @param Item Attached map view
   --  @param Key Fixed-size key bytes
   --  @param Value Fixed-size destination
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @param Found True only when Key is present
   --  @exception Timeout_Error The guard remains owned through the deadline
   procedure Get
     (Item    : View;
      Key     : Ada.Streams.Stream_Element_Array;
      Value   : out Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout;
      Found   : out Boolean);

   --  Remove Key when present, retaining a tombstone for probe continuity.
   --  @param Item Attached map view
   --  @param Key Fixed-size key bytes
   --  @param Removed True only when an occupied entry was deleted
   --  @exception Constraint_Error Key has the wrong length
   --  @exception Busy_Error Another operation owns the guard
   --  @exception Poison_Error The map is poisoned
   procedure Remove
     (Item    : in out View;
      Key     : Ada.Streams.Stream_Element_Array;
      Removed : out Boolean);

   --  Remove Key after waiting for the shared guard.
   --  @param Item Attached map view
   --  @param Key Fixed-size key bytes
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @param Removed True only when Key was present
   --  @exception Timeout_Error The guard remains owned through the deadline
   procedure Remove
     (Item    : in out View;
      Key     : Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout;
      Removed : out Boolean);

   --  Reset every entry to empty and set Length to zero.
   --  @param Item Attached map view
   --  @exception Busy_Error Another operation owns the guard
   --  @exception Poison_Error The map is poisoned
   procedure Clear (Item : in out View);

   --  Clear the map after waiting for the shared guard.
   --  @param Item Attached map view
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @exception Timeout_Error The guard remains owned through the deadline
   procedure Clear (Item : in out View; Timeout : Wait_Timeout);

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
      Count_Address   : System.Address := System.Null_Address;
      Guard_Address   : System.Address := System.Null_Address;
      Entries_Address : System.Address := System.Null_Address;
   end record;
end Flyology.Data_Structures.Hash_Maps;
