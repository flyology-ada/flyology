with Interfaces;
private with System;

--  Creates one immutable fixed-size byte-backed element type. Value owns its
--  bytes and may be copied into a container without representation conversion.
--  Const_Ref borrows published container bytes without copying. Builder may
--  modify only unpublished container storage, while Value_Builder constructs
--  an independent Value before it is published. Scalar accessors use the
--  native fixed-width representation exercised by Flyology's tested targets;
--  Type_Signature and Layout_Version define the stable semantic contract.
--  @formal Byte_Size Exact stored bytes in one value
--  @formal Required_Alignment Power-of-two alignment for each stored value
--  @formal Type_Signature Stable nonzero semantic type identifier
--  @formal Layout_Version Nonzero version of the value's byte layout

generic
   Byte_Size : Positive;
   Required_Alignment : Positive := 1;
   Type_Signature : Interfaces.Unsigned_64;
   Layout_Version : Interfaces.Unsigned_32;
package Flyology.Data_Structures.Storage_Types.Immutable is
   pragma Preelaborate;
   --  Exact stored bytes in one immutable value.
   Size : constant Positive := Byte_Size;

   --  Required alignment of each stored value.
   Alignment : constant Positive := Required_Alignment;

   --  Stable semantic type identifier persisted by receiving containers.
   Signature : constant Interfaces.Unsigned_64 := Type_Signature;

   --  Version of the immutable value's byte layout.
   Version : constant Interfaces.Unsigned_32 := Layout_Version;

   --  Independent immutable byte-backed value accepted by containers.
   type Value is private;

   --  Read-only process-local reference to one published stored value. A
   --  reference is valid only during the bound observer invocation that
   --  received it.
   type Const_Ref is limited private;

   --  Mutable process-local reference to an unpublished container slot. A
   --  builder is valid only during the container operation that bound it.
   type Builder is limited private;

   --  Local builder for constructing an independent immutable Value.
   type Value_Builder is limited private;

   --  Begin a zero-filled independent value construction.
   --  @return Builder whose bytes are initially zero
   function Start return Value_Builder;

   --  Freeze an independent builder. Item must not be used again.
   --  @param Item Completed local builder
   --  @return Immutable byte-backed value
   function Freeze (Item : in out Value_Builder) return Value;

   --  Return one byte from a published reference.
   --  @param Item Active read-only reference
   --  @param Offset Zero-based byte offset
   --  @return Stored byte
   function Load_U8 (Item : Const_Ref; Offset : Natural) return Interfaces.Unsigned_8;

   --  Return an aligned native 32-bit field from a published reference.
   --  @param Item Active read-only reference
   --  @param Offset Zero-based field offset
   --  @return Stored fixed-width value
   function Load_U32 (Item : Const_Ref; Offset : Natural) return Interfaces.Unsigned_32;

   --  Return an aligned native 64-bit field from a published reference.
   --  @param Item Active read-only reference
   --  @param Offset Zero-based field offset
   --  @return Stored fixed-width value
   function Load_U64 (Item : Const_Ref; Offset : Natural) return Interfaces.Unsigned_64;

   --  Write one byte in an unpublished container slot.
   --  @param Item Active unpublished builder
   --  @param Offset Zero-based byte offset
   --  @param Data Byte to store
   procedure Store_U8 (Item : in out Builder; Offset : Natural; Data : Interfaces.Unsigned_8);

   --  Write an aligned native 32-bit field in an unpublished container slot.
   --  @param Item Active unpublished builder
   --  @param Offset Zero-based field offset
   --  @param Data Fixed-width value to store
   procedure Store_U32 (Item : in out Builder; Offset : Natural; Data : Interfaces.Unsigned_32);

   --  Write an aligned native 64-bit field in an unpublished container slot.
   --  @param Item Active unpublished builder
   --  @param Offset Zero-based field offset
   --  @param Data Fixed-width value to store
   procedure Store_U64 (Item : in out Builder; Offset : Natural; Data : Interfaces.Unsigned_64);

   --  Write one byte in a local independent value builder.
   --  @param Item Active local builder
   --  @param Offset Zero-based byte offset
   --  @param Data Byte to store
   procedure Store_U8 (Item : in out Value_Builder; Offset : Natural; Data : Interfaces.Unsigned_8);

   --  Write an aligned native 32-bit field in a local value builder.
   --  @param Item Active local builder
   --  @param Offset Zero-based field offset
   --  @param Data Fixed-width value to store
   procedure Store_U32 (Item : in out Value_Builder; Offset : Natural; Data : Interfaces.Unsigned_32);

   --  Write an aligned native 64-bit field in a local value builder.
   --  @param Item Active local builder
   --  @param Offset Zero-based field offset
   --  @param Data Fixed-width value to store
   procedure Store_U64 (Item : in out Value_Builder; Offset : Natural; Data : Interfaces.Unsigned_64);

   --  Copy an immutable Value into a validated unpublished storage binding.
   --  @param Item Independent immutable value
   --  @param Target Validated unpublished element storage
   --  @exclude
   procedure Copy_To (Item : Value; Target : Immutable_Storage_View);

   --  Assign an independent immutable value through an unpublished builder.
   --  @param Item Active unpublished builder
   --  @param Data Independent immutable representation
   --  @exclude
   procedure Assign (Item : in out Builder; Data : Value);
   pragma Inline_Always (Assign);

   --  Copy one validated immutable storage binding to unpublished storage.
   --  @param Source Validated published element storage
   --  @param Target Validated unpublished element storage
   --  @exclude
   procedure Copy (Source : Immutable_Storage_View; Target : Immutable_Storage_View);

   --  Copy a validated published storage binding into an independent value.
   --  @param Source Validated published element storage
   --  @return Independent immutable value
   --  @exclude
   function Copy_From (Source : Immutable_Storage_View) return Value;

   --  Bind a read-only reference to validated published storage.
   --  @param Item Reference initialized on success
   --  @param Source Validated published element storage
   --  @exclude
   procedure Bind (Item : out Const_Ref; Source : Immutable_Storage_View);

   --  Bind a builder to validated unpublished storage.
   --  @param Item Builder initialized on success
   --  @param Target Validated unpublished element storage
   --  @exclude
   procedure Bind (Item : out Builder; Target : Immutable_Storage_View);

   --  Compute the stable FNV-1a hash of an independent representation.
   --  @param Item Immutable bytes to hash
   --  @return 64-bit representation hash
   --  @exclude
   function Hash (Item : Value) return Interfaces.Unsigned_64;

   --  Compute the stable FNV-1a hash of published bytes in place.
   --  @param Item Active read-only reference
   --  @return 64-bit representation hash
   --  @exclude
   function Hash (Item : Const_Ref) return Interfaces.Unsigned_64;

   --  Compare an independent representation with published bytes.
   --  @param Left Independent immutable bytes
   --  @param Right Active published reference
   --  @return True when every representation byte matches
   --  @exclude
   function Equivalent (Left : Value; Right : Const_Ref) return Boolean;

   --  Compare two published representations in place.
   --  @param Left First active published reference
   --  @param Right Second active published reference
   --  @return True when every representation byte matches
   --  @exclude
   function Equivalent (Left : Const_Ref; Right : Const_Ref) return Boolean;

private
   subtype Byte_Index is Natural range 0 .. Byte_Size - 1;
   type Byte_Array is array (Byte_Index) of Interfaces.Unsigned_8 with Component_Size => 8;

   type Value is new Byte_Array;

   type Const_Ref is limited record
      Base   : System.Address := System.Null_Address;
      Active : Boolean := False;
   end record;

   type Builder is limited record
      Base   : System.Address := System.Null_Address;
      Active : Boolean := False;
   end record;

   type Value_Builder is limited record
      Data   : Value := (others => 0);
      Active : Boolean := True;
   end record;
end Flyology.Data_Structures.Storage_Types.Immutable;
