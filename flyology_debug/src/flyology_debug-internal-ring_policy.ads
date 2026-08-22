--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Interfaces;
use type Interfaces.Unsigned_64;

--  Proved state transitions for a bounded retention-ordered ring. Storage and
--  synchronization remain in the tracer; this kernel decides only which slot
--  is written and how the logical head/count state changes. Capacity remains
--  an operation parameter so one proof covers every positive tracer capacity.
--  @exclude

package Flyology_Debug.Internal.Ring_Policy
  with SPARK_Mode => On
is
   --  Logical ring state independent from payload storage.
   --  @field Head Oldest occupied slot, or canonical slot one while empty
   --  @field Count Number of occupied slots
   type State is record
      Head  : Positive := 1;
      Count : Natural := 0;
   end record;

   --  Canonical empty state valid for every positive capacity.
   Initial_State : constant State := (Head => 1, Count => 0);

   --  Report whether Value is a well-formed state for Capacity.
   --  @param Value State to inspect
   --  @param Capacity Ring capacity governing Value
   --  @return True when Head and Count fit Capacity
   function Valid (Value : State; Capacity : Positive) return Boolean
   is (Value.Head <= Capacity and then Value.Count <= Capacity);

   --  Report whether a valid state has no unused slot.
   --  @param Value Valid state to inspect
   --  @param Capacity Ring capacity governing Value
   --  @return True when Count equals Capacity
   function Is_Full (Value : State; Capacity : Positive) return Boolean
   is (Value.Count = Capacity)
   with Pre => Valid (Value, Capacity);

   --  Report whether an append may retain a message under the selected
   --  full-ring behavior.
   --  @param Value Valid state to inspect
   --  @param Capacity Ring capacity governing Value
   --  @param Overwrite_When_Full Whether a full ring may replace its oldest
   --  element
   --  @return True for available capacity or permitted overwrite
   function Can_Append (Value : State; Capacity : Positive; Overwrite_When_Full : Boolean) return Boolean
   is (not Is_Full (Value, Capacity) or else Overwrite_When_Full)
   with Pre => Valid (Value, Capacity);

   --  Return the slot written by the next append. A nonfull state selects the
   --  unused tail; a full state selects the oldest element at Head.
   --  @param Value Valid state before append
   --  @param Capacity Ring capacity governing Value
   --  @return One-based payload slot not greater than Capacity
   function Insertion_Index (Value : State; Capacity : Positive) return Positive
   with Pre => Valid (Value, Capacity), Post => Insertion_Index'Result <= Capacity;

   --  Advance Value after writing Insertion_Index. A nonfull append grows
   --  Count without changing Head. A full append advances Head while
   --  preserving Count and reports the overwritten oldest element.
   --  @param Value Valid state updated for one completed payload write
   --  @param Capacity Ring capacity governing Value
   --  @param Overwrote Whether the completed write replaced the oldest slot
   procedure Append (Value : in out State; Capacity : Positive; Overwrote : out Boolean)
   with
     Pre            => Valid (Value, Capacity),
     Post           => Valid (Value, Capacity),
     Contract_Cases =>
       (Value.Count < Capacity =>
          (not Overwrote and then Value.Head = Value.Head'Old and then Value.Count = Value.Count'Old + 1),
        Value.Count = Capacity =>
          (Overwrote
           and then Value.Count = Value.Count'Old
           and then Value.Head = (if Value.Head'Old = Capacity then 1 else Value.Head'Old + 1)));

   --  Restore the empty canonical state.
   --  @param Value State replaced with Initial_State
   procedure Clear (Value : out State)
   with Post => Value = Initial_State;

   --  Increment Value without allowing an observability counter to wrap.
   --  @param Value Counter to increment or preserve at its upper bound
   --  @return Saturating successor of Value
   function Saturating_Increment (Value : Interfaces.Unsigned_64) return Interfaces.Unsigned_64
   with
     Contract_Cases =>
       (Value = Interfaces.Unsigned_64'Last => Saturating_Increment'Result = Value,
        Value < Interfaces.Unsigned_64'Last => Saturating_Increment'Result = Value + 1);

   --  Return the modular successor used for admission sequence numbers.
   --  @param Value Current sequence number
   --  @return Value plus one, wrapping according to Unsigned_64 semantics
   function Next_Sequence (Value : Interfaces.Unsigned_64) return Interfaces.Unsigned_64
   is (Value + 1);
end Flyology_Debug.Internal.Ring_Policy;
