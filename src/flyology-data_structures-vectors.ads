with Flyology.Data_Structures.Storage_Types.Immutable;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with System;

use type Interfaces.Unsigned_64;

--  Provides bounded vectors of immutable fixed-layout values in relocatable
--  storage. Element values own exact byte arrays, so append and replacement
--  copy bytes without encoding. Read operations invoke a caller-supplied
--  action with a zero-copy Const_Ref while the vector guard keeps the element
--  and backing allocation stable. Emplacement constructs directly in an
--  unpublished slot and publishes the new length only after successful
--  construction. Actions and constructors must not block, retain references,
--  reenter this vector, or change its backing lifetime.
--
--  Immediate operations make one process-shared guard attempt and raise
--  Busy_Error on contention. Timed overloads yield between attempts. The
--  application must exclude lifecycle operations and local-view detachment
--  from every use of that same View; separate attached views may perform
--  ordinary operations concurrently.
--  @formal Element Immutable byte-backed value type stored by this vector
generic
   with package Element is new
     Flyology.Data_Structures.Storage_Types.Immutable (<>);
package Flyology.Data_Structures.Vectors is

   --  Eight-byte magic stored in every vector header.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5356_4543_3031#;

   --  Schema identifier composed with the immutable element identity.
   Schema : constant Interfaces.Unsigned_64 :=
     16#0001_5645_4354_0004# xor Element.Signature xor
     Interfaces.Shift_Left (Interfaces.Unsigned_64 (Element.Version), 32);

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 4;

   --  Complete stable layout identity for envelope instances and tooling.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached vector view.
   type View is limited private;

   --  Read-only action invoked synchronously with a published element. Item
   --  is valid only until the action returns.
   --  @param Item Active read-only reference
   type Read_Action is not null access procedure (Item : Element.Const_Ref);

   --  Constructor invoked synchronously with one unpublished element slot.
   --  The slot becomes immutable and visible only after the action returns.
   --  @param Item Active unpublished builder
   type Construct_Action is not null access procedure
     (Item : in out Element.Builder);

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
     (Item     : out View;
      Region   : Region_View;
      Location : Region_Offset;
      Capacity : Positive);

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
   procedure Attach
     (Item     : out View;
      Region   : Region_View;
      Location : Region_Offset;
      Capacity : Positive);

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

   --  Append an immutable value without representation conversion.
   --  @param Item Internally synchronized vector view
   --  @param Data Independent immutable value
   --  @param Appended True only when capacity was available
   procedure Try_Append
     (Item     : in out View;
      Data     : Element.Value;
      Appended : out Boolean);

   --  Append after waiting for the shared guard.
   --  @param Item Internally synchronized vector view
   --  @param Data Independent immutable value
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @param Appended True only when capacity was available
   procedure Try_Append
     (Item     : in out View;
      Data     : Element.Value;
      Timeout  : Wait_Timeout;
      Appended : out Boolean);

   --  Construct an immutable value directly in an unpublished tail slot.
   --  Constructor is not called when the vector is full.
   --  @param Item Internally synchronized vector view
   --  @param Constructor Nonblocking construction action
   --  @param Appended True only when construction completed and was published
   procedure Try_Emplace
     (Item        : in out View;
      Constructor : Construct_Action;
      Appended    : out Boolean);

   --  Invoke Process on the indexed element without copying it.
   --  @param Item Internally synchronized vector view
   --  @param Index One-based initialized element position
   --  @param Process Nonblocking read-only action
   --  @exception Constraint_Error Index is outside the initialized range
   procedure Read
     (Item    : View;
      Index   : Positive;
      Process : Read_Action);

   --  Copy the indexed element into an independent immutable value. Prefer
   --  callback Read when the caller can consume the value synchronously.
   --  @param Item Internally synchronized vector view
   --  @param Index One-based initialized element position
   --  @return Independent immutable value
   function Read (Item : View; Index : Positive) return Element.Value;

   --  Instantiate a statically dispatched zero-copy reader for a hot path.
   --  Process must obey the same nonblocking and reference-lifetime rules as
   --  callback Read. GNAT may inline Process into the guarded operation.
   --  @exclude
   generic
      --  Read-only action invoked synchronously.
      --  @param Item Active read-only reference
      with procedure Process (Item : Element.Const_Ref);
   --  Invoke the statically selected Process on one element without copying.
   --  @param Item Internally synchronized vector view
   --  @param Index One-based initialized element position
   procedure Visit (Item : View; Index : Positive);

   --  Invoke Process after waiting for the shared guard.
   --  @param Item Internally synchronized vector view
   --  @param Index One-based initialized element position
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   --  @param Process Nonblocking read-only action
   procedure Read
     (Item    : View;
      Index   : Positive;
      Timeout : Wait_Timeout;
      Process : Read_Action);

   --  Replace one element with another immutable value. No mutable reference
   --  to the published element is exposed.
   --  @param Item Internally synchronized vector view
   --  @param Index One-based initialized element position
   --  @param Data Replacement immutable value
   procedure Replace
     (Item  : in out View;
      Index : Positive;
      Data  : Element.Value);

   --  Replace after waiting for the shared guard.
   --  @param Item Internally synchronized vector view
   --  @param Index One-based initialized element position
   --  @param Data Replacement immutable value
   --  @param Timeout Maximum wait; zero permits one immediate attempt
   procedure Replace
     (Item    : in out View;
      Index   : Positive;
      Data    : Element.Value;
      Timeout : Wait_Timeout);

   --  Observe and remove the last element without copying it. Process is not
   --  called for an empty vector; a raising Process leaves the element live.
   --  @param Item Internally synchronized vector view
   --  @param Process Nonblocking read-only action
   --  @param Popped True only when Process returned and length was decremented
   procedure Try_Pop
     (Item    : in out View;
      Process : Read_Action;
      Popped  : out Boolean);

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
