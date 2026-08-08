with Ada.Streams;
with Flyology.Data_Structures.Arenas;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

use type Interfaces.Unsigned_64;

--  Provides growable byte sequences backed by relocatable arena allocations.
--  The fixed header stores only scalar metadata and generation-stamped arena
--  handles. Assign and append allocate a replacement block before publishing
--  it, and memmove-compatible copying supports overlapping Ada byte sources.
--  One persisted nonblocking guard serializes ordinary operations across
--  mappings; arena contention is reported through Growth_Result. Lifecycle
--  operations and detachment of one local View require application exclusion.
--  @formal Arena_Provider Statically selected relocatable arena instance
generic
   with package Arena_Provider is new Flyology.Data_Structures.Arenas (<>);
package Flyology.Data_Structures.Dynamic.Byte_Strings with Preelaborate is

   --  Eight-byte magic stored in every dynamic byte-string header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_4442_5354_3031#;

   --  Schema identifier for the arena-backed byte-string growth contract.
   Schema : constant Interfaces.Unsigned_64 :=
     16#0001_4442_5354_0002# xor Arena_Provider.Identity.Schema xor
     Interfaces.Rotate_Left (Arena_Provider.Identity.Magic, 19) xor
     Interfaces.Shift_Left
       (Interfaces.Unsigned_64 (Arena_Provider.Identity.Version), 32);

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 2;

   --  Complete stable layout identity for envelopes and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached dynamic byte-string view.
   type View is limited private;

   --  Return the fixed header extent; payload is allocated from an arena.
   --  @return Complete dynamic byte-string header bytes
   function Required_Storage return Byte_Count;

   --  Destructively initialize an empty byte string for Arena_Provider.
   --  @param Item View attached on success
   --  @param Region Region containing the fixed string header
   --  @param Location Nonzero eight-byte-aligned string-header offset
   --  @param Arena Attached arena used for payload growth
   --  @param Initial_Capacity First byte capacity requested on growth
   procedure Initialize
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive);

   --  Initialize allocation-certified virgin bytes or attach to a compatible
   --  ready string. Initial capacity and arena identity/incarnation must
   --  match.
   --  @param Item Attached view or detached view during another initialization
   --  @param Region Region containing the fixed string header
   --  @param Location Stored string-header offset
   --  @param Arena Expected attached arena
   --  @param Initial_Capacity Expected first-growth byte capacity
   --  @param Result Creation, attachment, or in-progress outcome
   procedure Create_Or_Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive;
      Result           : out Open_Result);

   --  Attach to a quiescent string and validate its arena allocations.
   --  @param Item View attached on success
   --  @param Region Region containing the fixed string header
   --  @param Location Stored string-header offset
   --  @param Arena Expected attached arena and incarnation
   --  @param Initial_Capacity Expected first-growth capacity
   --  @exception Layout_Error Configuration or mutable state is incompatible
   --  @exception Busy_Error The string guard is active or abandoned
   procedure Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive);

   --  Detach Item without modifying its header or allocations.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item retains local mapping information.
   --  @param Item View to inspect
   --  @return True while the local header view is attached
   function Is_Attached (Item : View) return Boolean;

   --  Report whether the string lifecycle is poisoned.
   --  @param Item Attached string view
   --  @return True only for a persisted poisoned lifecycle
   function Is_Poisoned (Item : View) return Boolean;

   --  Poison a quiescent or abandoned-locked string after external recovery
   --  authority establishes owner death and quiescence.
   --  @param Region Region containing the fixed string header
   --  @param Location Stored string-header offset
   procedure Poison (Region : Region_View; Location : Region_Offset);

   --  Return the currently allocated byte capacity.
   --  @param Item Internally synchronized string view
   --  @return Current byte capacity, initially zero
   function Capacity (Item : View) return Natural;

   --  Return the current retained byte count.
   --  @param Item Internally synchronized string view
   --  @return Current byte length
   function Length (Item : View) return Natural;

   --  Replace the string, growing through Arena when required.
   --  @param Item Internally synchronized string view
   --  @param Arena Matching attached arena view
   --  @param Data Replacement bytes
   --  @param Result Completion, arena exhaustion, or arena contention
   procedure Try_Assign
     (Item   : in out View;
      Arena  : in out Arena_Provider.View;
      Data   : Ada.Streams.Stream_Element_Array;
      Result : out Growth_Result);

   --  Append Data, growing through Arena when required.
   --  @param Item Internally synchronized string view
   --  @param Arena Matching attached arena view
   --  @param Data Bytes appended in order
   --  @param Result Completion, arena exhaustion, or arena contention
   procedure Try_Append
     (Item   : in out View;
      Arena  : in out Arena_Provider.View;
      Data   : Ada.Streams.Stream_Element_Array;
      Result : out Growth_Result);

   --  Copy the complete value into an exact-length destination.
   --  @param Item Internally synchronized string view
   --  @param Arena Matching attached arena view
   --  @param Data Destination whose length must equal Length
   procedure Read
     (Item  : View;
      Arena : Arena_Provider.View;
      Data  : out Ada.Streams.Stream_Element_Array);

   --  Set Length to zero without releasing retained payload capacity.
   --  @param Item Internally synchronized string view
   procedure Clear (Item : in out View);

   --  Release current and deferred allocations, destroy the quiescent header,
   --  and detach Item.
   --  @param Item Exclusively synchronized string view
   --  @param Arena Matching attached arena view
   procedure Destroy (Item : in out View; Arena : in out Arena_Provider.View);

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
end Flyology.Data_Structures.Dynamic.Byte_Strings;
