package body Flyology.Data_Structures.Policy
  with SPARK_Mode => On
is
   function Valid_Lifecycle (Value : Lifecycle_Code) return Boolean is
     (Value = 1 or else Value = 2 or else Value = 3 or else Value = 5);

   function Make_State
     (Value : Epoch; Lifecycle : Lifecycle_Code)
      return Interfaces.Unsigned_32 is
     (Value * (2 ** Lifecycle_Bits) + Lifecycle);

   function State_Epoch
     (Word : Interfaces.Unsigned_32) return Interfaces.Unsigned_32 is
     (Word / (2 ** Lifecycle_Bits));

   function State_Lifecycle
     (Word : Interfaces.Unsigned_32) return Lifecycle_Code is
     (Lifecycle_Code (Word and Lifecycle_Mask));

   function Valid_State (Word : Interfaces.Unsigned_32) return Boolean is
     (State_Epoch (Word) in Epoch
      and then Valid_Lifecycle (State_Lifecycle (Word)));

   function Epoch_Can_Advance
     (Word : Interfaces.Unsigned_32) return Boolean is
     (State_Epoch (Word) in Epoch
      and then State_Epoch (Word) < Maximum_Epoch);

   function Next_Epoch (Value : Epoch) return Epoch is
     (Value + 1);

   function Addition_Fits (Left, Right : Byte_Count) return Boolean is
     (Right <= Byte_Count'Last - Left);

   function Add (Left, Right : Byte_Count) return Byte_Count is
     (Left + Right);

   function Multiplication_Fits (Left, Right : Byte_Count) return Boolean is
     (Left = 0 or else Right <= Byte_Count'Last / Left);

   function Is_Power_Of_Two (Value : Byte_Count) return Boolean is
     (Value > 0 and then (Value and (Value - 1)) = 0);

   function Alignment_Fits
     (Value, Alignment : Byte_Count) return Boolean is
     (Is_Power_Of_Two (Alignment)
      and then
        (Value mod Alignment = 0
         or else Value <=
           Byte_Count'Last - (Alignment - Value mod Alignment)));

   function Slice_Fits
     (Container, Offset, Extent : Byte_Count) return Boolean is
     (Extent > 0
      and then Offset <= Container
      and then Extent <= Container - Offset);

   function Within_Capacity
     (Produced, Consumed : Interfaces.Unsigned_64;
      Capacity           : Interfaces.Unsigned_32) return Boolean is
     (Produced - Consumed <= Interfaces.Unsigned_64 (Capacity));

   function Classify_Sequence
     (Observed, Expected : Interfaces.Unsigned_64) return Sequence_Relation is
     (if Observed = Expected then Sequence_Ready
      elsif Observed - Expected >= 16#8000_0000_0000_0000# then
         Sequence_Behind
      else Sequence_Ahead);

   function Masked_Index
     (Value    : Interfaces.Unsigned_64;
      Capacity : Positive_U32) return Interfaces.Unsigned_64 is
     (Value and (Interfaces.Unsigned_64 (Capacity) - 1));

   function Allocation_Slot
     (Cursor   : Interfaces.Unsigned_64;
      Offset   : Interfaces.Unsigned_32;
      Capacity : Positive_U32) return Positive_U32 is
     (Positive_U32
        ((Cursor + Interfaces.Unsigned_64 (Offset)) mod
           Interfaces.Unsigned_64 (Capacity) + 1));

   function Generation_Can_Advance
     (Value : Interfaces.Unsigned_32) return Boolean is
     (Value > 0 and then Value < Interfaces.Unsigned_32'Last);

   function Next_Generation
     (Value : Interfaces.Unsigned_32) return Positive_U32 is
     (Value + 1);
end Flyology.Data_Structures.Policy;
