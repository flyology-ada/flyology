with Flyology.Data_Structures.Storage_Types.Elements;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

use type Interfaces.Unsigned_64;

--  Provides bounded vectors of immutable fixed-layout values in relocatable
--  storage. Element creation and observation are selected once by the generic
--  adapter. Append creates independent immutable bytes before acquiring the
--  guard, observation reads a scoped Const_Ref without an intermediate
--  representation copy, and emplacement delays creation until capacity is
--  known to be available. Adapter operations must not block, retain
--  references, reenter this vector, or change its backing lifetime.
--
--  Immediate operations make one process-shared guard attempt and raise
--  Busy_Error on contention. Timed overloads yield between attempts. The
--  application must exclude lifecycle operations and local-view detachment
--  from every use of that same View; separate attached views may perform
--  ordinary operations concurrently.
--  @formal Element Immutable byte-backed element adapter stored by this vector

generic
   with package Element is new Flyology.Data_Structures.Storage_Types.Elements (<>);
package Flyology.Data_Structures.Vectors is

   --  Eight-byte magic stored in every vector header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5356_4543_3031#;

   --  Schema identifier composed with the immutable element identity.
   Schema : constant Interfaces.Unsigned_64 :=
     16#0001_5645_4354_0004#
     xor Element.Signature
     xor Interfaces.Shift_Left (Interfaces.Unsigned_64 (Element.Version), 32);

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 4;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity := (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached vector view.
   type View is limited private;

   --  Compute the complete fixed-capacity vector extent.
   --  @param Capacity Maximum element count
   --  @return Required header, padding, and immutable element bytes
   function Required_Storage (Capacity : Positive) return Byte_Count;

   --  Initialize an empty vector and attach Item. Exclusive initialization
   --  invalidates every earlier view of the same extent.
   --  @param Item View attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero stored offset aligned for this element type
   --  @param Capacity Maximum element count
   procedure Initialize
     (Item : out View; Region : Region_View; Location : Region_Offset; Capacity : Positive);

   --  Initialize certified virgin bytes or attach to an exactly compatible
   --  vector. Capacity and the generic element identity must match.
   --  @param Item Attached view or detached view while initialization proceeds
   --  @param Region Independently attached backing region
   --  @param Location Stored vector offset
   --  @param Capacity Expected maximum element count
   --  @param Result Creation, attachment, or in-progress outcome
   procedure Create_Or_Attach
     (Item     : out View;
      Region   : Region_View;
      Location : Region_Offset;
      Capacity : Positive;
      Result   : out Open_Result);

   --  Attach to a quiescent vector with the expected capacity and immutable
   --  element contract.
   --  @param Item View attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored vector offset
   --  @param Capacity Expected maximum element count
   --  @exception Layout_Error Identity, geometry, or length is incompatible
   procedure Attach (Item : out View; Region : Region_View; Location : Region_Offset; Capacity : Positive);

   --  Detach Item without modifying stored bytes.
   --  @param Item Local view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item retains local mapping information.
   --  @param Item View to inspect
   --  @return True while the process-local view is attached
   function Is_Attached (Item : View) return Boolean;

   --  Return the fixed element capacity.
   --  @param Item Attached view
   --  @return Maximum initialized element count
   function Capacity (Item : View) return Natural;

   --  Return the initialized element count without waiting.
   --  @param Item Attached synchronized view
   --  @return Current element count
   function Length (Item : View) return Natural;

   --  Return the initialized element count after waiting for the guard.
   --  @param Item Attached synchronized view
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @return Current element count
   --  @exception Timeout_Error The guard remains owned through the deadline
   function Length (Item : View; Timeout : Wait_Timeout) return Natural;

   --  Report whether the vector lifecycle is poisoned.
   --  @param Item Attached vector view
   --  @return True only for the persisted poisoned lifecycle
   function Is_Poisoned (Item : View) return Boolean;

   --  Poison a quiescent ready or abandoned-locked vector after external
   --  owner-death and quiescence authorization.
   --  @param Region Region containing the vector
   --  @param Location Stored vector offset
   procedure Poison (Region : Region_View; Location : Region_Offset);

   --  Create and append an immutable value. Creation completes before guard
   --  acquisition, so a raising creator cannot mutate shared storage.
   --  @param Item Internally synchronized vector view
   --  @param Data Application value accepted by the element adapter
   --  @param Appended True only when capacity was available
   procedure Try_Append (Item : in out View; Data : Element.Source; Appended : out Boolean);

   --  Append after waiting for the shared guard.
   --  @param Item Internally synchronized vector view
   --  @param Data Application value accepted by the element adapter
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @param Appended True only when capacity was available
   procedure Try_Append
     (Item : in out View; Data : Element.Source; Timeout : Wait_Timeout; Appended : out Boolean);

   --  Create an immutable value only after finding an unpublished tail slot.
   --  The bound creator is not called when the vector is full.
   --  @param Item Internally synchronized vector view
   --  @param Data Application value accepted by the bound creator
   --  @param Appended True only when creation completed and was published
   procedure Try_Emplace (Item : in out View; Data : Element.Source; Appended : out Boolean);

   --  Observe the indexed element without copying its representation.
   --  @param Item Internally synchronized vector view
   --  @param Index One-based initialized element position
   --  @return Application observation returned by the bound observer
   --  @exception Constraint_Error Index is outside the initialized range
   function Read (Item : View; Index : Positive) return Element.Observed;

   --  Copy the indexed element into an independent immutable representation.
   --  @param Item Internally synchronized vector view
   --  @param Index One-based initialized element position
   --  @return Independent immutable value
   function Read_Value (Item : View; Index : Positive) return Element.Value;

   --  Observe one element after waiting for the shared guard.
   --  @param Item Internally synchronized vector view
   --  @param Index One-based initialized element position
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @return Application observation returned by the bound observer
   function Read (Item : View; Index : Positive; Timeout : Wait_Timeout) return Element.Observed;

   --  Replace one element with another immutable value. No mutable reference
   --  to the published element is exposed.
   --  @param Item Internally synchronized vector view
   --  @param Index One-based initialized element position
   --  @param Data Application value accepted by the element adapter
   procedure Replace (Item : in out View; Index : Positive; Data : Element.Source);

   --  Replace after waiting for the shared guard.
   --  @param Item Internally synchronized vector view
   --  @param Index One-based initialized element position
   --  @param Data Application value accepted by the element adapter
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   procedure Replace (Item : in out View; Index : Positive; Data : Element.Source; Timeout : Wait_Timeout);

   --  Observe and remove the last element without copying its representation.
   --  The bound observer is not called for an empty vector; a raising observer
   --  leaves the element live.
   --  @param Item Internally synchronized vector view
   --  @param Data Observation assigned only when an element is consumed
   --  @param Popped True only when observation returned and length decremented
   procedure Try_Pop (Item : in out View; Data : out Element.Observed; Popped : out Boolean);

   --  Set Length to zero without rewriting immutable payload bytes.
   --  @param Item Internally synchronized vector view
   procedure Clear (Item : in out View);

   --  Invalidate a quiescent vector and detach Item.
   --  @param Item Exclusively synchronized vector view
   procedure Destroy (Item : in out View);

private
   type View is limited record
      Core            : Layouts.Local_View;
      Guard_Address   : System.Address := System.Null_Address;
      Length_Address  : System.Address := System.Null_Address;
      Payload_Address : System.Address := System.Null_Address;
      Payload_Extent  : Byte_Count := 0;
      Capacity_Value  : Interfaces.Unsigned_32 := 0;
      Stride          : Byte_Count := 0;
   end record;
end Flyology.Data_Structures.Vectors;
