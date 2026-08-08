with Ada.Streams;
with Interfaces;
private with Flyology.Data_Structures.Layouts;

--  Provides bounded variable-length byte strings in relocatable storage.
--  Values are byte sequences, not text encodings, and never contain hidden
--  Ada metadata. Immediate operations use one process-shared nonblocking
--  guard and raise Busy_Error on contention. Timed overloads yield and retry
--  that guard through one explicit timeout. An exception after a mutation may
--  have begun poisons the stored
--  object; Poison_Error then persists until exclusive reinitialization.
--  Is_Attached, Capacity, and Is_Poisoned inspect only local or lifecycle
--  metadata and do not acquire the payload guard.
--  The application must exclude Attach, Detach, Initialize, Destroy, and
--  backing-lifetime changes from every use of the same local View. Separate
--  attached views may perform ordinary operations concurrently.
package Flyology.Data_Structures.Byte_Strings with Preelaborate is

   --  Eight-byte magic stored in every byte-string header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5342_5354_3031#;

   --  Schema identifier for the current byte-string layout.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_4253_5452_0003#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 3;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached view.
   type View is limited private;

   --  Compute storage for a string with Maximum_Length payload bytes.
   --  @param Maximum_Length Maximum retained byte count
   --  @return Required header and payload bytes
   function Required_Storage (Maximum_Length : Positive) return Byte_Count;

   --  Initialize an empty string and attach Item. Exclusive reinitialization
   --  is the only recovery from a poisoned lifecycle state and makes every
   --  preexisting view stale; each peer must attach again.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero eight-byte-aligned stored offset
   --  @param Maximum_Length Fixed payload capacity
   procedure Initialize
     (Item           : out View;
      Region         : Region_View;
      Location       : Region_Offset;
      Maximum_Length : Positive);

   --  Attach to a quiescent existing string and validate its expected
   --  capacity.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored string offset
   --  @param Maximum_Length Expected payload capacity
   --  @exception Layout_Error Header, capacity, or current length is corrupt
   procedure Attach
     (Item           : out View;
      Region         : Region_View;
      Location       : Region_Offset;
      Maximum_Length : Positive);

   --  Detach Item without modifying the string.
   --  @param Item View to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item View to inspect
   --  @return True while local mapping information is retained; this does not
   --     guarantee the cached initialization epoch is still current
   function Is_Attached (Item : View) return Boolean;

   --  Return the fixed payload capacity.
   --  @param Item Attached view
   --  @return Maximum retained byte count
   function Capacity (Item : View) return Natural;

   --  Return the current retained length.
   --  @param Item Attached synchronized view
   --  @return Number of initialized payload bytes
   function Length (Item : View) return Natural;

   --  Return the retained length after waiting for the shared guard. The
   --  caller yields between attempts and one monotonic deadline spans them.
   --  @param Item Attached synchronized view
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @return Number of initialized payload bytes
   --  @exception Timeout_Error The guard remains owned through the deadline
   function Length (Item : View; Timeout : Wait_Timeout) return Natural;

   --  Report whether an attached string requires reinitialization.
   --  @param Item Attached view
   --  @return True only when the persisted lifecycle state is poisoned
   function Is_Poisoned (Item : View) return Boolean;

   --  Mark a quiescent string poisoned. Before calling, the application must
   --  independently establish that no operation is active, including that a
   --  process or task which left the guard locked has terminated. Flyology
   --  performs no owner-death detection.
   --  @param Region Attached backing region
   --  @param Location Stored string offset
   --  @exception Layout_Error The stored identity or lifecycle is invalid
   --  @exception Busy_Error The lifecycle changed during the poison attempt
   procedure Poison (Region : Region_View; Location : Region_Offset);

   --  Replace the string with Data. Overlap between Data and the stored
   --  payload is supported.
   --  @param Item Internally synchronized attached view
   --  @param Data Replacement bytes
   --  @exception Constraint_Error Data exceeds Capacity
   procedure Assign
     (Item : in out View; Data : Ada.Streams.Stream_Element_Array);

   --  Replace the string after waiting for the shared guard.
   --  @param Item Internally synchronized attached view
   --  @param Data Replacement bytes; payload overlap is supported
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @exception Timeout_Error The guard remains owned through the deadline
   --  @exception Constraint_Error Data exceeds Capacity
   procedure Assign
     (Item    : in out View;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout);

   --  Append Data to the current string. Overlap between Data and the stored
   --  payload is supported.
   --  @param Item Internally synchronized attached view
   --  @param Data Bytes appended in order
   --  @exception Constraint_Error The resulting length exceeds Capacity
   procedure Append
     (Item : in out View; Data : Ada.Streams.Stream_Element_Array);

   --  Append Data after waiting for the shared guard.
   --  @param Item Internally synchronized attached view
   --  @param Data Bytes appended in order; payload overlap is supported
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @exception Timeout_Error The guard remains owned through the deadline
   --  @exception Constraint_Error The resulting length exceeds Capacity
   procedure Append
     (Item    : in out View;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout);

   --  Copy the current string into Data, whose length must equal Length.
   --  @param Item Internally synchronized attached view
   --  @param Data Exact-size destination
   --  @exception Constraint_Error Data has the wrong length
   procedure Read
     (Item : View; Data : out Ada.Streams.Stream_Element_Array);

   --  Copy the string after waiting for the shared guard.
   --  @param Item Internally synchronized attached view
   --  @param Data Exact-size destination
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @exception Timeout_Error The guard remains owned through the deadline
   --  @exception Constraint_Error Data has the wrong length
   procedure Read
     (Item    : View;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout);

   --  Set the current length to zero without rewriting retained payload bytes.
   --  @param Item Internally synchronized attached view
   procedure Clear (Item : in out View);

   --  Clear the string after waiting for the shared guard.
   --  @param Item Internally synchronized attached view
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @exception Timeout_Error The guard remains owned through the deadline
   procedure Clear (Item : in out View; Timeout : Wait_Timeout);

   --  Invalidate a quiescent string and detach Item.
   --  @param Item Internally synchronized attached view
   procedure Destroy (Item : in out View);

   pragma Inline
     (Capacity, Length, Is_Poisoned, Assign, Append, Read, Clear);

private
   type View is limited record
      Core            : Layouts.Local_View;
      Guard_Address   : System.Address := System.Null_Address;
      Length_Address  : System.Address := System.Null_Address;
      Payload_Address : System.Address := System.Null_Address;
      Capacity_Value  : Interfaces.Unsigned_32 := 0;
   end record;
end Flyology.Data_Structures.Byte_Strings;
