with Flyology.Data_Structures.Storage_Types.Immutable;
with Interfaces;

--  Binds one immutable byte representation to its application-facing source
--  and observed types. Containers instantiate with this complete contract, so
--  creation and observation are selected statically once rather than supplied
--  on every operation. An optional access-to-procedure hook constructs
--  directly in unpublished storage; a null hook safely falls back to
--  Create_Value plus one representation copy.
--  @formal Representation Immutable bytes and scoped storage bindings
--  @formal Source_Type Application value accepted by insertion operations
--  @formal Observed_Type Application value returned by observation operations
--  @formal Create_Value Create an independent immutable representation
--  @formal Observe_Value Observe published storage without an intermediate
--     representation copy
--  @formal Direct_Constructor Optional direct unpublished-storage constructor
generic
   with package Representation is new
     Flyology.Data_Structures.Storage_Types.Immutable (<>);
   type Source_Type is private;
   type Observed_Type is private;
   with function Create_Value
     (Item : Source_Type) return Representation.Value;
   with function Observe_Value
     (Item : Representation.Const_Ref) return Observed_Type;
   Direct_Constructor : access procedure
     (Item : in out Representation.Builder;
      Data : Source_Type) := null;
package Flyology.Data_Structures.Storage_Types.Elements is
   pragma Preelaborate;

   --  Exact bytes in one stored element.
   Size : constant Positive := Representation.Size;

   --  Required alignment of every stored element.
   Alignment : constant Positive := Representation.Alignment;

   --  Stable nonzero semantic type signature.
   Signature : constant Interfaces.Unsigned_64 := Representation.Signature;

   --  Nonzero representation layout version.
   Version : constant Interfaces.Unsigned_32 := Representation.Version;

   --  Independent immutable byte-backed value.
   subtype Value is Representation.Value;

   --  Scoped reference to published element bytes.
   subtype Const_Ref is Representation.Const_Ref;

   --  Scoped builder for unpublished element bytes.
   subtype Builder is Representation.Builder;

   --  Application value accepted by creation and construction operations.
   subtype Source is Source_Type;

   --  Application value returned by the bound observation operation.
   subtype Observed is Observed_Type;

   --  Create an independent immutable representation.
   --  @param Item Application value to represent
   --  @return Independent immutable bytes
   function Create (Item : Source) return Value;
   pragma Inline_Always (Create);

   --  Construct in unpublished element storage. A bound direct constructor
   --  writes the slot without a temporary; otherwise Create_Value produces one
   --  independent immutable Value which is copied before publication.
   --  @param Item Active unpublished builder
   --  @param Data Application value to construct
   --  @exclude
   procedure Construct
     (Item : in out Builder;
      Data : Source);
   pragma Inline_Always (Construct);

   --  Observe published bytes without first copying their representation.
   --  @param Item Active read-only reference
   --  @return Application observation
   function Observe (Item : Const_Ref) return Observed;
   pragma Inline_Always (Observe);

   --  Copy an immutable Value into validated unpublished storage.
   --  @param Item Independent immutable value
   --  @param Target Validated unpublished element storage
   --  @exclude
   procedure Copy_To
     (Item : Value; Target : Immutable_Storage_View)
     renames Representation.Copy_To;

   --  Copy validated published storage into validated unpublished storage.
   --  @param Source Validated published element storage
   --  @param Target Validated unpublished element storage
   --  @exclude
   procedure Copy
     (Source : Immutable_Storage_View;
      Target : Immutable_Storage_View)
     renames Representation.Copy;

   --  Copy validated published bytes into an independent Value.
   --  @param Source Validated published element storage
   --  @return Independent immutable representation
   --  @exclude
   function Copy_From (Source : Immutable_Storage_View) return Value
     renames Representation.Copy_From;

   --  Bind a scoped read-only reference.
   --  @param Item Reference initialized on success
   --  @param Source Validated published element storage
   --  @exclude
   procedure Bind
     (Item : out Const_Ref; Source : Immutable_Storage_View)
     renames Representation.Bind;

   --  Bind a scoped unpublished builder.
   --  @param Item Builder initialized on success
   --  @param Target Validated unpublished element storage
   --  @exclude
   procedure Bind
     (Item : out Builder; Target : Immutable_Storage_View)
     renames Representation.Bind;

   --  Hash independent immutable bytes.
   --  @param Item Immutable representation
   --  @return Stable 64-bit FNV-1a hash
   --  @exclude
   function Hash (Item : Value) return Interfaces.Unsigned_64
     renames Representation.Hash;

   --  Hash published immutable bytes in place.
   --  @param Item Active published reference
   --  @return Stable 64-bit FNV-1a hash
   --  @exclude
   function Hash (Item : Const_Ref) return Interfaces.Unsigned_64
     renames Representation.Hash;

   --  Compare independent and published immutable bytes.
   --  @param Left Independent representation
   --  @param Right Active published reference
   --  @return True when every representation byte matches
   --  @exclude
   function Equivalent (Left : Value; Right : Const_Ref) return Boolean
     renames Representation.Equivalent;

   --  Compare two published immutable representations.
   --  @param Left First active reference
   --  @param Right Second active reference
   --  @return True when every representation byte matches
   --  @exclude
   function Equivalent
     (Left : Const_Ref; Right : Const_Ref) return Boolean
     renames Representation.Equivalent;
end Flyology.Data_Structures.Storage_Types.Elements;
