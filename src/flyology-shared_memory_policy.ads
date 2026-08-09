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

   --  Classify one received carrier and ancillary record. This SPARK function
   --  proves structural acceptance only: kernel send acceptance does not prove
   --  that a remote receiver has validated, mapped, or attached the object.
   --  A higher-level protocol must retain any peer-liveness precondition until
   --  its own receiver-acceptance acknowledgment.
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

   type Replacement_Validation is
     (Replacement_Valid,
      Source_Invalid,
      Configuration_Mismatch,
      Target_Unmapped,
      Target_Not_Exclusive,
      Target_Not_Virgin,
      Target_Not_Indexable,
      Target_Not_Larger,
      Mapping_Aliased);

   type Replacement_Slot_State is
     (Slot_Free,
      Slot_Initializing,
      Slot_Ready,
      Slot_Failed,
      Slot_Removed,
      Slot_Invalid);

   --  Classify the scalar facts required before cloning a quiescent segment.
   --  The postcondition proves that an accepted copy frontier is within both
   --  mappings and aligned to the unchanged segment configuration.
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
      Distinct_Mappings  : Boolean) return Replacement_Validation
   with
     Pre  => Alignment /= 0,
     Post =>
       (Validate_Replacement'Result = Replacement_Valid) =
         (Source_Ready
          and then Same_Configuration
          and then Target_Mapped
          and then Target_Exclusive
          and then Target_Virgin
          and then Distinct_Mappings
          and then Source_Extent <= Native_Index_Limit
          and then Target_Extent <= Native_Index_Limit
          and then Target_Extent > Source_Extent
          and then Data_Start >= 4
          and then Data_Start <= Frontier
          and then Frontier <= Source_Extent
          and then Frontier mod Alignment = 0)
       and then
         (if Validate_Replacement'Result = Replacement_Valid then
             Frontier >= 4
             and then Frontier <= Source_Extent
             and then Frontier < Target_Extent
             and then Target_Extent <= Native_Index_Limit);

   --  Validate the scalar metadata of one registry slot before replacement.
   --  Free slots have no live metadata. Every other accepted slot has a
   --  nonzero identity, aligned nonempty reservation wholly below Frontier,
   --  and a nonzero failure code exactly when that state requires one.
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
      Alignment   : U64) return Boolean
   with
     Pre  => Alignment /= 0,
     Post =>
       Valid_Replacement_Slot'Result =
         (State = Slot_Free
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
               (if State = Slot_Failed then Failure /= 0 else True)));
end Flyology.Shared_Memory_Policy;
