with Flyology.Data_Structures.Arenas;
with Flyology.Data_Structures.Storage_Types.Elements;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

use type Interfaces.Unsigned_64;

--  Provides growable open-addressed maps from immutable fixed-layout keys to
--  immutable fixed-layout values. The fixed map header stores an arena
--  incarnation, current table geometry, and generation-stamped allocation
--  handles. Linear
--  probing uses cached native addresses only for the duration of one checked
--  process-local allocation view. Insertion grows and rehashes before
--  publishing a replacement table. One persisted nonblocking map guard
--  serializes operations across mappings; arena contention is reported in the
--  insertion result. Initialization, destruction, backing-lifetime changes,
--  and concurrent use of one local view require exclusion. Attachment acquires
--  the persisted map guard without waiting while it validates a stable table
--  generation, so another local view may attach while ordinary operations
--  continue.
--  @formal Arena_Provider Statically selected relocatable arena instance
--  @formal Key Immutable key adapter bound once for this map type
--  @formal Element Immutable mapped-value adapter bound once for this map type

generic
   with package Arena_Provider is new Flyology.Data_Structures.Arenas (<>);
   with package Key is new Flyology.Data_Structures.Storage_Types.Elements (<>);
   with package Element is new Flyology.Data_Structures.Storage_Types.Elements (<>);
package Flyology.Data_Structures.Dynamic.Hash_Maps with Preelaborate is

   --  Eight-byte magic stored in every dynamic-map header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_4448_4D41_3031#;

   --  Schema for the FNV-1a, linear-probe, arena-backed map contract.
   Schema : constant Interfaces.Unsigned_64 :=
     16#0001_4448_4D41_0003#
     xor Key.Signature
     xor Interfaces.Shift_Left (Interfaces.Unsigned_64 (Key.Version), 32)
     xor Interfaces.Rotate_Left (Element.Signature, 17)
     xor Interfaces.Shift_Left (Interfaces.Unsigned_64 (Element.Version), 48)
     xor Arena_Provider.Identity.Schema
     xor Interfaces.Rotate_Left (Arena_Provider.Identity.Magic, 19)
     xor Interfaces.Rotate_Left (Interfaces.Unsigned_64 (Arena_Provider.Identity.Version), 41);

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 3;

   --  Complete stable layout identity for envelopes and tooling.
   Identity : constant Layout_Identity := (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached dynamic-map view.
   type View is limited private;

   --  Insertion outcome.
   --  @enum Put_Inserted A previously absent key was inserted
   --  @enum Put_Replaced An existing key's value was replaced
   --  @enum Put_Arena_Exhausted No arena block can satisfy table growth
   --  @enum Put_Arena_Contended Another caller owns arena metadata
   type Put_Result is (Put_Inserted, Put_Replaced, Put_Arena_Exhausted, Put_Arena_Contended);

   --  Return the fixed outer header extent.
   --  @return Complete dynamic-map header bytes
   function Required_Storage return Byte_Count;

   --  Destructively initialize an empty map bound to Arena_Provider.
   --  @param Item View attached on success
   --  @param Region Region containing the fixed map header
   --  @param Location Nonzero eight-byte-aligned map-header offset
   --  @param Arena Attached arena used for table allocations
   --  @param Initial_Capacity Power-of-two first table capacity, at least two
   procedure Initialize
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive);

   --  Initialize virgin bytes or attach to an exact compatible map. Initial
   --  capacity, key/value contracts, and arena identity/incarnation must
   --  match.
   --  @param Item Attached view or detached view during another initialization
   --  @param Region Region containing the fixed map header
   --  @param Location Stored map-header offset
   --  @param Arena Expected attached arena
   --  @param Initial_Capacity Expected first table capacity
   --  @param Result Creation, attachment, or in-progress outcome
   --  @exception Busy_Error A ready map's guard is active or abandoned
   procedure Create_Or_Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive;
      Result           : out Open_Result);

   --  Attach to a map, acquiring its shared guard without waiting while
   --  validating the complete probe table and any deferred allocation handle.
   --  This may race operations through other views; exclude concurrent use of
   --  Item itself.
   --  @param Item View attached on success
   --  @param Region Region containing the fixed map header
   --  @param Location Stored map-header offset
   --  @param Arena Expected attached arena and incarnation
   --  @param Initial_Capacity Expected first table capacity
   --  @exception Layout_Error Configuration or table contents are corrupt
   --  @exception Busy_Error The map guard is active or abandoned
   procedure Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive);

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
   --  @param Key_Data Application key value
   --  @param Value Application mapped value
   --  @param Result Insert, replacement, exhaustion, or arena contention
   procedure Put
     (Item     : in out View;
      Arena    : in out Arena_Provider.View;
      Key_Data : Key.Source;
      Value    : Element.Source;
      Result   : out Put_Result);

   --  Look up Key and copy its value when present.
   --  @param Item Internally synchronized map view
   --  @param Arena Matching attached arena view
   --  @param Key_Data Application key value
   --  @param Value Observation assigned only when Found is true
   --  @param Found True only when Key is present
   procedure Get
     (Item     : View;
      Arena    : Arena_Provider.View;
      Key_Data : Key.Source;
      Value    : out Element.Observed;
      Found    : out Boolean);

   --  Remove Key while retaining a tombstone for probe continuity.
   --  @param Item Internally synchronized map view
   --  @param Arena Matching attached arena view
   --  @param Key_Data Application key value
   --  @param Removed True only when Key was present
   procedure Remove
     (Item : in out View; Arena : Arena_Provider.View; Key_Data : Key.Source; Removed : out Boolean);

   --  Reset every current slot to empty without releasing table capacity.
   --  @param Item Internally synchronized map view
   --  @param Arena Matching attached arena view
   procedure Clear (Item : in out View; Arena : Arena_Provider.View);

   --  Release current and deferred tables, destroy the quiescent header, and
   --  detach Item.
   --  @param Item Exclusively synchronized map view
   --  @param Arena Matching attached arena view
   procedure Destroy (Item : in out View; Arena : in out Arena_Provider.View);

private
   type View is limited record
      Core                   : Layouts.Local_View;
      Guard_Address          : System.Address := System.Null_Address;
      Count_Address          : System.Address := System.Null_Address;
      Capacity_Address       : System.Address := System.Null_Address;
      Capacity_Check_Address : System.Address := System.Null_Address;
      Current_Address        : System.Address := System.Null_Address;
      Retired_Address        : System.Address := System.Null_Address;
      Initial_Value          : Interfaces.Unsigned_32 := 0;
      Key_Value              : Interfaces.Unsigned_32 := 0;
      Value_Value            : Interfaces.Unsigned_32 := 0;
      Arena_ID_Value         : Interfaces.Unsigned_64 := 0;
      Arena_Epoch_Value      : Interfaces.Unsigned_32 := 0;
      Key_Offset             : Byte_Count := 0;
      Value_Offset           : Byte_Count := 0;
      Stride                 : Byte_Count := 0;
   end record;
end Flyology.Data_Structures.Dynamic.Hash_Maps;
