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

   function Validate_Replacement
     (Source_Extent      : U64;
      Target_Extent      : U64;
      Frontier           : U64;
      Data_Start         : U64;
      Alignment          : U64;
      Native_Index_Limit : U64;
      Source_Ready       : Boolean;
      Same_Configuration : Boolean;
      Target_Mapped      : Boolean;
      Target_Exclusive   : Boolean;
      Target_Virgin      : Boolean;
      Distinct_Mappings  : Boolean) return Replacement_Validation is
   begin
      if not Source_Ready
        or else Data_Start < 4
        or else Frontier < Data_Start
        or else Frontier > Source_Extent
        or else Source_Extent > Native_Index_Limit
        or else Frontier mod Alignment /= 0
      then
         return Source_Invalid;
      elsif not Same_Configuration then
         return Configuration_Mismatch;
      elsif not Target_Mapped then
         return Target_Unmapped;
      elsif not Target_Exclusive then
         return Target_Not_Exclusive;
      elsif not Target_Virgin then
         return Target_Not_Virgin;
      elsif Target_Extent > Native_Index_Limit then
         return Target_Not_Indexable;
      elsif Target_Extent <= Source_Extent then
         return Target_Not_Larger;
      elsif not Distinct_Mappings then
         return Mapping_Aliased;
      else
         return Replacement_Valid;
      end if;
   end Validate_Replacement;

   function Valid_Replacement_Slot
     (State       : Replacement_Slot_State;
      Generation  : U64;
      Name_Length : U32;
      Name_Limit  : U32;
      Location    : U64;
      Length      : U64;
      Reserved    : U64;
      Failure     : U32;
      Data_Start  : U64;
      Frontier    : U64;
      Alignment   : U64) return Boolean is
   begin
      return
        State = Slot_Free
        or else
          (State /= Slot_Invalid
           and then Generation /= 0
           and then Name_Length /= 0
           and then Name_Length <= Name_Limit
           and then Location >= Data_Start
           and then Location mod Alignment = 0
           and then Length /= 0
           and then Reserved /= 0
           and then Length <= Reserved
           and then Reserved mod Alignment = 0
           and then Location <= Frontier
           and then Reserved <= Frontier - Location
           and then
             (if State = Slot_Failed then Failure /= 0 else True));
   end Valid_Replacement_Slot;
end Flyology.Shared_Memory_Policy;
