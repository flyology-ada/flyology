package body Flyology.Shared_Memory_Policy with SPARK_Mode is
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
      Require_Immutable  : Boolean) return Descriptor_Validation is
   begin
      if Actual_Length /= Expected_Length then
         return Size_Mismatch;
      elsif not Is_Regular (Mode, Type_Mask, Regular_Type)
        and then not (Allow_Untyped and then Is_Untyped (Mode, Type_Mask))
      then
         return Type_Mismatch;
      elsif not Writable then
         return Type_Mismatch;
      elsif not Close_On_Exec
        or else (Require_Immutable and then not Size_Immutable)
      then
         return Security_Missing;
      else
         return Descriptor_Valid;
      end if;
   end Validate_Descriptor;

   function Classify_Namespace
     (Created         : Boolean;
      Actual_Length   : U64;
      Expected_Length : U64) return Namespace_Classification is
   begin
      if not Created and then Actual_Length = 0 then
         return Namespace_In_Progress;
      elsif Actual_Length /= Expected_Length then
         return Namespace_Size_Mismatch;
      else
         return Namespace_Ready;
      end if;
   end Classify_Namespace;
end Flyology.Shared_Memory_Policy;
