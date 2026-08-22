with Flyology.Data_Structures.Storage_Types.Elements;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

use type Interfaces.Unsigned_64;

--  Provides bounded open-addressed maps between immutable fixed-layout keys
--  and values. Their creation and observation contracts are
--  bound once by generic adapters. Capacity is a power of two and probing is
--  linear over cached fixed-stride entries. Stored data contains only state
--  scalars, hashes, keys, and values. Ordinary operations are internally
--  serialized
--  across mappings by one process-capable stored guard. Immediate operations
--  make one acquisition attempt and raise Busy_Error; timed overloads yield
--  and retry through one explicit timeout. Initialization, destruction, and
--  backing-lifetime changes require whole-object quiescence.
--  Attach and ready-object Create_Or_Attach acquire the stored guard while
--  validating mutable contents. The application must exclude Detach,
--  Initialize, Destroy, and backing-lifetime changes from every use of the
--  same local View. Separate views may attach or perform ordinary operations
--  concurrently.
--  @formal Key Immutable key adapter
--  @formal Element Immutable mapped-value adapter

generic
   with package Key is new Flyology.Data_Structures.Storage_Types.Elements (<>);
   with package Element is new Flyology.Data_Structures.Storage_Types.Elements (<>);
package Flyology.Data_Structures.Hash_Maps with Preelaborate is

   --  Eight-byte magic stored in every map header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5348_4D41_3031#;

   --  Schema identifier for the current FNV-1a/open-addressed layout.
   Schema : constant Interfaces.Unsigned_64 :=
     16#0001_484D_4150_0004#
     xor Key.Signature
     xor Interfaces.Shift_Left (Interfaces.Unsigned_64 (Key.Version), 32)
     xor Interfaces.Rotate_Left (Element.Signature, 17)
     xor Interfaces.Shift_Left (Interfaces.Unsigned_64 (Element.Version), 48);

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 4;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity := (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached map view.
   type View is limited private;

   --  Insertion outcome.
   --  @enum Inserted A previously absent key was inserted
   --  @enum Replaced An existing key's value was replaced
   --  @enum Table_Full No empty or deleted slot was available
   type Put_Result is (Inserted, Replaced, Table_Full);

   --  Compute the complete map extent. Capacity must be a power of two.
   --  @param Capacity Maximum occupied entry count
   --  @return Required header, entry metadata, padding, keys, and values
   --  @exception Constraint_Error Capacity is not a power of two
   function Required_Storage (Capacity : Positive) return Byte_Count;

   --  Initialize an empty map and attach Item. Every preexisting view becomes
   --  stale and must attach again before use.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero eight-byte-aligned stored offset
   --  @param Capacity Power-of-two maximum entry count
   procedure Initialize
     (Item : out View; Region : Region_View; Location : Region_Offset; Capacity : Positive);

   --  Atomically initialize a known-virgin zeroed extent or attach to a ready
   --  compatible map. Only the exact zero lifecycle sentinel is eligible for
   --  creation; no existing lifecycle is reinitialized. The operation does
   --  not wait for another initializer or for the map guard.
   --  Concurrent calls may race on allocation-certified virgin bytes or on a
   --  ready map; ready attachment acquires the shared guard without waiting.
   --  @param Item Attached view, or detached when initialization is in
   --     progress
   --  @param Region Independently attached backing region
   --  @param Location Stored map offset
   --  @param Capacity Expected power-of-two capacity
   --  @param Result Whether this caller initialized, attached, or observed an
   --     initialization in progress
   procedure Create_Or_Attach
     (Item     : out View;
      Region   : Region_View;
      Location : Region_Offset;
      Capacity : Positive;
      Result   : out Open_Result);

   --  Attach to a map, acquiring its shared guard without waiting while
   --  validating expected geometry, entry states and count, fixed-key hashes,
   --  linear-probe reachability, and key uniqueness. This may race operations
   --  through other views; exclude concurrent use of Item itself.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored map offset
   --  @param Capacity Expected power-of-two capacity
   --  @exception Layout_Error Header, geometry, or entries are corrupt
   --  @exception Busy_Error The map guard is active or abandoned
   --  @exception Poison_Error The map is poisoned
   procedure Attach (Item : out View; Region : Region_View; Location : Region_Offset; Capacity : Positive);

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
   --  @param Key_Data Application key value
   --  @param Value Application mapped value
   --  @param Result Insert, replacement, or full-table outcome
   --  @exception Busy_Error Another operation owns the guard
   --  @exception Poison_Error The map is poisoned
   procedure Put (Item : in out View; Key_Data : Key.Source; Value : Element.Source; Result : out Put_Result);

   --  Insert or replace after waiting for the shared guard.
   --  @param Item Attached map view
   --  @param Key_Data Application key value
   --  @param Value Application mapped value
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @param Result Insert, replacement, or full-table outcome
   --  @exception Timeout_Error The guard remains owned through the deadline
   procedure Put
     (Item     : in out View;
      Key_Data : Key.Source;
      Value    : Element.Source;
      Timeout  : Wait_Timeout;
      Result   : out Put_Result);

   --  Look up Key and copy its value when present.
   --  @param Item Attached map view
   --  @param Key_Data Application key value
   --  @param Value Observation assigned only when Found is true
   --  @param Found True only when Key is present
   --  @exception Busy_Error Another operation owns the guard
   --  @exception Poison_Error The map is poisoned
   procedure Get (Item : View; Key_Data : Key.Source; Value : out Element.Observed; Found : out Boolean);

   --  Look up Key after waiting for the shared guard.
   --  @param Item Attached map view
   --  @param Key_Data Application key value
   --  @param Value Observation assigned only when Found is true
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @param Found True only when Key is present
   --  @exception Timeout_Error The guard remains owned through the deadline
   procedure Get
     (Item     : View;
      Key_Data : Key.Source;
      Value    : out Element.Observed;
      Timeout  : Wait_Timeout;
      Found    : out Boolean);

   --  Remove Key when present, retaining a tombstone for probe continuity.
   --  @param Item Attached map view
   --  @param Key_Data Application key value
   --  @param Removed True only when an occupied entry was deleted
   --  @exception Busy_Error Another operation owns the guard
   --  @exception Poison_Error The map is poisoned
   procedure Remove (Item : in out View; Key_Data : Key.Source; Removed : out Boolean);

   --  Remove Key after waiting for the shared guard.
   --  @param Item Attached map view
   --  @param Key_Data Application key value
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @param Removed True only when Key was present
   --  @exception Timeout_Error The guard remains owned through the deadline
   procedure Remove
     (Item : in out View; Key_Data : Key.Source; Timeout : Wait_Timeout; Removed : out Boolean);

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
      Core            : Layouts.Local_View;
      Capacity_Value  : Interfaces.Unsigned_32 := 0;
      Key_Value       : Interfaces.Unsigned_32 := 0;
      Value_Value     : Interfaces.Unsigned_32 := 0;
      Mask            : Interfaces.Unsigned_64 := 0;
      Key_Offset      : Byte_Count := 0;
      Value_Offset    : Byte_Count := 0;
      Stride          : Byte_Count := 0;
      Count_Address   : System.Address := System.Null_Address;
      Guard_Address   : System.Address := System.Null_Address;
      Entries_Address : System.Address := System.Null_Address;
   end record;
end Flyology.Data_Structures.Hash_Maps;
