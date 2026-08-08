with Interfaces;

--  Proved scalar policy shared by the relocatable layouts. Native addresses,
--  atomic operations, and byte copying remain outside this package.
private package Flyology.Data_Structures.Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   subtype Positive_U32 is Interfaces.Unsigned_32 range
     1 .. Interfaces.Unsigned_32'Last;
   subtype Non_Root_Node is Interfaces.Unsigned_32 range
     1 .. Interfaces.Unsigned_32'Last - 1;

   Lifecycle_Bits : constant := 3;
   Lifecycle_Mask : constant Interfaces.Unsigned_32 := 7;
   Maximum_Epoch  : constant Interfaces.Unsigned_32 :=
     16#1FFF_FFFF#;
   subtype Lifecycle_Code is Interfaces.Unsigned_32 range 0 .. Lifecycle_Mask;
   subtype Epoch is Interfaces.Unsigned_32 range 1 .. Maximum_Epoch;

   type Sequence_Relation is
     (Sequence_Ready, Sequence_Behind, Sequence_Ahead);

   function Valid_Lifecycle (Value : Lifecycle_Code) return Boolean
   with Global => null,
        Post   => Valid_Lifecycle'Result =
          (Value = 1 or else Value = 2 or else Value = 3 or else Value = 5);

   function State_Epoch
     (Word : Interfaces.Unsigned_32) return Interfaces.Unsigned_32
   with Global => null,
        Post   => State_Epoch'Result = Word / (2 ** Lifecycle_Bits);

   function State_Lifecycle
     (Word : Interfaces.Unsigned_32) return Lifecycle_Code
   with Global => null,
        Post   => State_Lifecycle'Result =
          Lifecycle_Code (Word and Lifecycle_Mask);

   function Make_State
     (Value : Epoch; Lifecycle : Lifecycle_Code)
      return Interfaces.Unsigned_32
   with Global => null,
        Pre    => Valid_Lifecycle (Lifecycle),
        Post   => State_Epoch (Make_State'Result) = Value
          and then State_Lifecycle (Make_State'Result) = Lifecycle;

   function Valid_State (Word : Interfaces.Unsigned_32) return Boolean
   with Global => null,
        Post   => Valid_State'Result =
          (State_Epoch (Word) in Epoch
           and then Valid_Lifecycle (State_Lifecycle (Word)));

   function Epoch_Can_Advance
     (Word : Interfaces.Unsigned_32) return Boolean
   with Global => null,
        Post   => Epoch_Can_Advance'Result =
          (State_Epoch (Word) in Epoch
           and then State_Epoch (Word) < Maximum_Epoch);

   function Next_Epoch (Value : Epoch) return Epoch
   with Global => null,
        Pre    => Value < Maximum_Epoch,
        Post   => Next_Epoch'Result = Value + 1
          and then Next_Epoch'Result > Value;

   function Addition_Fits (Left, Right : Byte_Count) return Boolean
   with Global => null,
        Post   => Addition_Fits'Result =
          (Right <= Byte_Count'Last - Left);

   function Add (Left, Right : Byte_Count) return Byte_Count
   with Global => null,
        Pre    => Addition_Fits (Left, Right),
        Post   => Add'Result = Left + Right
          and then Add'Result >= Left
          and then Add'Result >= Right;

   function Multiplication_Fits (Left, Right : Byte_Count) return Boolean
   with Global => null,
        Post   => Multiplication_Fits'Result =
          (Left = 0 or else Right <= Byte_Count'Last / Left);

   function Is_Power_Of_Two (Value : Byte_Count) return Boolean
   with Global => null,
        Post   => Is_Power_Of_Two'Result =
          (Value > 0 and then (Value and (Value - 1)) = 0);

   function Buddy_Node_Count_Fits (Leaves : Byte_Count) return Boolean
   with Global => null,
        Post   => Buddy_Node_Count_Fits'Result =
          (Leaves > 0
           and then Leaves <=
             (Byte_Count (Interfaces.Unsigned_32'Last) + 1) / 2);

   function Buddy_Node_Count (Leaves : Byte_Count) return Positive_U32
   with Global => null,
        Pre    => Buddy_Node_Count_Fits (Leaves),
        Post   => Byte_Count (Buddy_Node_Count'Result) = Leaves * 2 - 1;

   function Buddy_Parent
     (Node : Non_Root_Node) return Interfaces.Unsigned_32
   with Global => null,
        Post   => Buddy_Parent'Result = (Node - 1) / 2
          and then Buddy_Parent'Result < Node;

   function Buddy_Sibling (Node : Non_Root_Node) return Positive_U32
   with Global => null,
        Post   => Buddy_Sibling'Result =
          (if Node mod 2 = 1 then Node + 1 else Node - 1)
          and then Buddy_Sibling'Result /= Node
          and then Buddy_Parent (Buddy_Sibling'Result) =
            Buddy_Parent (Node);

   function Alignment_Fits
     (Value, Alignment : Byte_Count) return Boolean
   with Global => null,
        Post   => Alignment_Fits'Result =
          (Is_Power_Of_Two (Alignment)
           and then
             (Value mod Alignment = 0
              or else Value <=
                Byte_Count'Last - (Alignment - Value mod Alignment)));

   function Slice_Fits
     (Container, Offset, Extent : Byte_Count) return Boolean
   with Global => null,
        Post   => Slice_Fits'Result =
          (Extent > 0
           and then Offset <= Container
           and then Extent <= Container - Offset);

   function Within_Capacity
     (Produced, Consumed : Interfaces.Unsigned_64;
      Capacity           : Interfaces.Unsigned_32) return Boolean
   with Global => null,
        Post   => Within_Capacity'Result =
          (Produced - Consumed <= Interfaces.Unsigned_64 (Capacity));

   function Classify_Sequence
     (Observed, Expected : Interfaces.Unsigned_64) return Sequence_Relation
   with Global => null,
        Post   =>
          (if Observed = Expected then
              Classify_Sequence'Result = Sequence_Ready
           elsif Observed - Expected >= 16#8000_0000_0000_0000# then
              Classify_Sequence'Result = Sequence_Behind
           else
              Classify_Sequence'Result = Sequence_Ahead);

   function Masked_Index
     (Value    : Interfaces.Unsigned_64;
      Capacity : Positive_U32) return Interfaces.Unsigned_64
   with Global => null,
        Pre    => Is_Power_Of_Two (Byte_Count (Capacity)),
        Post   => Masked_Index'Result < Interfaces.Unsigned_64 (Capacity)
          and then Masked_Index'Result =
            (Value and (Interfaces.Unsigned_64 (Capacity) - 1));

   function Allocation_Slot
     (Cursor   : Interfaces.Unsigned_64;
      Offset   : Interfaces.Unsigned_32;
      Capacity : Positive_U32) return Positive_U32
   with Global => null,
        Pre    => Offset < Capacity,
        Post   => Allocation_Slot'Result <= Capacity
          and then Allocation_Slot'Result =
            Positive_U32
              ((Cursor + Interfaces.Unsigned_64 (Offset)) mod
                 Interfaces.Unsigned_64 (Capacity) + 1);

   function Generation_Can_Advance
     (Value : Interfaces.Unsigned_32) return Boolean
   with Global => null,
        Post   => Generation_Can_Advance'Result =
          (Value > 0 and then Value < Interfaces.Unsigned_32'Last);

   function Next_Generation
     (Value : Interfaces.Unsigned_32) return Positive_U32
   with Global => null,
        Pre    => Generation_Can_Advance (Value),
        Post   => Next_Generation'Result = Value + 1
          and then Next_Generation'Result > Value;

   pragma Inline_Always
     (Valid_Lifecycle, Make_State, State_Epoch, State_Lifecycle,
      Valid_State, Epoch_Can_Advance, Next_Epoch,
      Addition_Fits, Add, Multiplication_Fits,
      Is_Power_Of_Two, Buddy_Node_Count_Fits, Buddy_Node_Count,
      Buddy_Parent, Buddy_Sibling, Alignment_Fits, Slice_Fits,
      Within_Capacity, Classify_Sequence, Masked_Index, Allocation_Slot,
      Generation_Can_Advance, Next_Generation);
end Flyology.Data_Structures.Policy;
