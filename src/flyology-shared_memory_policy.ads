with Interfaces;

--  Pure shared-memory validation and protocol classifiers. Syscall adapters
--  gather facts; this SPARK package decides whether those facts are safe.
private package Flyology.Shared_Memory_Policy with SPARK_Mode is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   subtype U8 is Interfaces.Unsigned_8;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   type Descriptor_Validation is
     (Descriptor_Valid, Size_Mismatch, Type_Mismatch, Security_Missing);

   function Is_Regular
     (Mode, Type_Mask, Regular_Type : U32) return Boolean is
     ((Mode and Type_Mask) = Regular_Type);

   function Is_Untyped
     (Mode, Type_Mask : U32) return Boolean is
     ((Mode and Type_Mask) = 0);

   function Owner_Only (Mode, Other_Access_Mask : U32) return Boolean is
     ((Mode and Other_Access_Mask) = 0);

   function Validate_Descriptor
     (Actual_Length      : U64;
      Expected_Length    : U64;
      Mode               : U32;
      Type_Mask          : U32;
      Regular_Type       : U32;
      Allow_Untyped      : Boolean;
      Writable           : Boolean;
      Close_On_Exec      : Boolean;
      Size_Immutable     : Boolean;
      Require_Immutable  : Boolean) return Descriptor_Validation
   with Post =>
     (Validate_Descriptor'Result = Descriptor_Valid) =
       (Actual_Length = Expected_Length
        and then
          (Is_Regular (Mode, Type_Mask, Regular_Type)
           or else (Allow_Untyped and then Is_Untyped (Mode, Type_Mask)))
        and then Writable
        and then Close_On_Exec
        and then (not Require_Immutable or else Size_Immutable));

   type Namespace_Classification is
     (Namespace_Ready, Namespace_In_Progress, Namespace_Size_Mismatch);

   function Classify_Namespace
     (Created         : Boolean;
      Actual_Length   : U64;
      Expected_Length : U64) return Namespace_Classification
   with Post =>
     (Classify_Namespace'Result = Namespace_In_Progress) =
       (not Created and then Actual_Length = 0)
     and then
       (Classify_Namespace'Result = Namespace_Ready) =
         (Actual_Length = Expected_Length
          and then (Created or else Actual_Length /= 0));

   function Valid_Handoff
     (Amount                 : Long_Long_Integer;
      Payload                : U8;
      Descriptor_Count       : U64;
      Structurally_Malformed : Boolean;
      Control_Truncated      : Boolean;
      Payload_Truncated      : Boolean) return Boolean is
     (Amount = 1
      and then Payload = 16#46#
      and then Descriptor_Count = 1
      and then not Structurally_Malformed
      and then not Control_Truncated
      and then not Payload_Truncated);
end Flyology.Shared_Memory_Policy;
