--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_Debug.Internal.Ring_Policy
  with SPARK_Mode => On
is
   function Next_Index (Value : Positive; Capacity : Positive) return Positive
   is (if Value = Capacity then 1 else Value + 1)
   with Pre => Value <= Capacity, Post => Next_Index'Result <= Capacity;

   function Insertion_Index (Value : State; Capacity : Positive) return Positive is
   begin
      if Value.Count = Capacity then
         return Value.Head;
      elsif Value.Count <= Capacity - Value.Head then
         return Value.Head + Value.Count;
      else
         return Value.Count - (Capacity - Value.Head);
      end if;
   end Insertion_Index;

   procedure Append (Value : in out State; Capacity : Positive; Overwrote : out Boolean) is
   begin
      if Value.Count = Capacity then
         Value.Head := Next_Index (Value.Head, Capacity);
         Overwrote := True;
      else
         Value.Count := Value.Count + 1;
         Overwrote := False;
      end if;
   end Append;

   procedure Clear (Value : out State) is
   begin
      Value := Initial_State;
   end Clear;

   function Saturating_Increment (Value : Interfaces.Unsigned_64) return Interfaces.Unsigned_64 is
   begin
      if Value = Interfaces.Unsigned_64'Last then
         return Value;
      else
         return Value + 1;
      end if;
   end Saturating_Increment;
end Flyology_Debug.Internal.Ring_Policy;
