with Flyology.Data_Structures.Arenas;
with Flyology.Data_Structures.Storage_Types.Elements;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

use type Interfaces.Unsigned_64;

--  Provides growable vectors of immutable fixed-layout elements. The vector
--  header remains at one relocatable region offset while payload storage is a
--  generation-stamped arena allocation. Growth allocates and copies before
--  publishing the replacement handle. Operations are serialized across
--  mappings by the vector's persisted nonblocking guard; arena contention is
--  reported separately through Growth_Result. Neither guard spins or waits.
--  Callers must exclude lifecycle operations and local View detachment from
--  ordinary use of that same View, and must keep the supplied arena attached.
--  A vector and its arena may be mapped at different native addresses.
--  @formal Arena_Provider Statically selected relocatable arena instance
--  @formal Element Immutable element adapter bound once for this vector type

generic
   with package Arena_Provider is new Flyology.Data_Structures.Arenas (<>);
   with package Element is new Flyology.Data_Structures.Storage_Types.Elements (<>);
package Flyology.Data_Structures.Dynamic.Vectors with Preelaborate is

   --  Eight-byte magic stored in every dynamic-vector header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_4456_4543_3031#;

   --  Schema identifier for the arena-backed vector layout and growth policy.
   Schema : constant Interfaces.Unsigned_64 :=
     16#0001_4456_4543_0003#
     xor Element.Signature
     xor Interfaces.Shift_Left (Interfaces.Unsigned_64 (Element.Version), 32)
     xor Arena_Provider.Identity.Schema
     xor Interfaces.Rotate_Left (Arena_Provider.Identity.Magic, 19)
     xor Interfaces.Unsigned_64 (Arena_Provider.Identity.Version);

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 3;

   --  Complete stable layout identity for envelopes and tooling.
   Identity : constant Layout_Identity := (Magic => Magic, Version => Layout_Version, Schema => Schema);

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
   procedure Initialize
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive);

   --  Initialize allocation-certified virgin bytes or attach to a compatible
   --  ready vector. Initial capacity, element contract, and arena instance
   --  identity must exactly match an existing header.
   --  @param Item Attached view or detached view during another initialization
   --  @param Region Region containing the fixed vector header
   --  @param Location Stored vector-header offset
   --  @param Arena Expected attached arena instance
   --  @param Initial_Capacity Expected first-growth capacity
   --  @param Result Creation, attachment, or in-progress outcome
   procedure Create_Or_Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive;
      Result           : out Open_Result);

   --  Attach to a quiescent vector and validate its header plus every current
   --  or deferred arena allocation handle.
   --  @param Item View attached on success
   --  @param Region Region containing the vector header
   --  @param Location Stored vector-header offset
   --  @param Arena Expected attached arena instance and incarnation
   --  @param Initial_Capacity Expected first-growth capacity
   --  @exception Layout_Error Configuration or mutable state is incompatible
   --  @exception Busy_Error The vector guard is active or abandoned
   procedure Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive);

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
   --  @param Data Application element value
   --  @param Result Completion, arena exhaustion, or arena contention
   --  @exception Busy_Error Another caller owns the vector guard
   procedure Try_Append
     (Item   : in out View;
      Arena  : in out Arena_Provider.View;
      Data   : Element.Source;
      Result : out Growth_Result);

   --  Observe the one-based initialized element at Index.
   --  @param Item Internally synchronized vector view
   --  @param Arena Matching attached arena view
   --  @param Index One-based initialized element position
   --  @return Bound immutable observation
   function Read (Item : View; Arena : Arena_Provider.View; Index : Positive) return Element.Observed;

   --  Replace the one-based initialized element at Index.
   --  @param Item Internally synchronized vector view
   --  @param Arena Matching attached arena view
   --  @param Index One-based initialized element position
   --  @param Data Application element value
   procedure Replace
     (Item : in out View; Arena : Arena_Provider.View; Index : Positive; Data : Element.Source);

   --  Copy and remove the last element. Empty vectors return Popped false and
   --  do not assign Data or release their retained allocation.
   --  @param Item Internally synchronized vector view
   --  @param Arena Matching attached arena view
   --  @param Data Observation assigned only when Popped is true
   --  @param Popped True only when an element was removed
   procedure Try_Pop
     (Item : in out View; Arena : Arena_Provider.View; Data : out Element.Observed; Popped : out Boolean);

   --  Set Length to zero without releasing current payload capacity.
   --  @param Item Internally synchronized vector view
   procedure Clear (Item : in out View);

   --  Release current and deferred allocations, destroy the quiescent header,
   --  and detach Item. Arena contention raises Busy_Error before an allocation
   --  that could not be reclaimed is forgotten; the ready vector remains
   --  retryable.
   --  @param Item Exclusively synchronized vector view
   --  @param Arena Matching attached arena view
   --  @exception Busy_Error Arena metadata is currently owned
   procedure Destroy (Item : in out View; Arena : in out Arena_Provider.View);

private
   type View is limited record
      Core                   : Layouts.Local_View;
      Guard_Address          : System.Address := System.Null_Address;
      Length_Address         : System.Address := System.Null_Address;
      Capacity_Address       : System.Address := System.Null_Address;
      Capacity_Check_Address : System.Address := System.Null_Address;
      Current_Address        : System.Address := System.Null_Address;
      Retired_Address        : System.Address := System.Null_Address;
      Initial_Value          : Interfaces.Unsigned_32 := 0;
      Element_Value          : Interfaces.Unsigned_32 := 0;
      Stride_Value           : Byte_Count := 0;
      Arena_ID_Value         : Interfaces.Unsigned_64 := 0;
      Arena_Epoch_Value      : Interfaces.Unsigned_32 := 0;
   end record;
end Flyology.Data_Structures.Dynamic.Vectors;
