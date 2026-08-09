with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Policy;
with Flyology.Data_Structures.Waits;
with System.Storage_Elements;

package body Flyology.Data_Structures.Rings.MPMC is
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Policy renames Flyology.Data_Structures.Policy;
   package Waiting renames Flyology.Data_Structures.Waits;
   package Native renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Policy.Sequence_Relation;

   Enqueue_Offset : constant Byte_Count := 64;
   Dequeue_Offset : constant Byte_Count := 128;
   Slots_Offset   : constant Byte_Count := 192;
   Sequence_Size  : constant Byte_Count := 8;

   function Storage_Alignment return Byte_Count is
     (Byte_Count'Max (8, Byte_Count (Element.Alignment)));

   procedure Geometry
     (Capacity       : Positive;
      Payload_Offset : out Byte_Count;
      Stride         : out Byte_Count;
      Extent         : out Byte_Count) is
   begin
      if Element.Signature = 0
        or else Element.Version = 0
        or else Element.Alignment not in 1 | 2 | 4 | 8 | 16 | 32 | 64
      then
         raise Constraint_Error with "invalid immutable MPMC element contract";
      elsif Capacity < 2 then
         raise Constraint_Error with "MPMC capacity must be at least two";
      elsif not Policy.Is_Power_Of_Two (Byte_Count (Capacity))
      then
         raise Constraint_Error with "MPMC capacity must be a power of two";
      end if;
      Payload_Offset := Layouts.Align_Up
        (Sequence_Size, Byte_Count (Element.Alignment));
      Stride := Layouts.Align_Up
        (Layouts.Checked_Add
           (Payload_Offset, Byte_Count (Element.Size)),
         Storage_Alignment);
      Extent := Layouts.Checked_Add
        (Slots_Offset,
         Layouts.Checked_Multiply (Byte_Count (Capacity), Stride));
   end Geometry;

   function Required_Storage (Capacity : Positive) return Byte_Count
   is
      Payload_Offset, Stride, Extent : Byte_Count;
   begin
      Geometry (Capacity, Payload_Offset, Stride, Extent);
      return Extent;
   end Required_Storage;

   procedure Set_View
     (Item : out View; Core : Layouts.Local_View;
      Capacity : Interfaces.Unsigned_32;
      Payload_Offset, Stride : Byte_Count) is
   begin
      Item.Core := Core;
      Item.Capacity_Value := Capacity;
      Item.Element_Value := Interfaces.Unsigned_32 (Element.Size);
      Item.Mask := Interfaces.Unsigned_64 (Capacity) - 1;
      Item.Payload_Offset := Payload_Offset;
      Item.Stride := Stride;
      Item.Enqueue_Address :=
        Layouts.Address_At (Core, Enqueue_Offset, 8, 8);
      Item.Dequeue_Address :=
        Layouts.Address_At (Core, Dequeue_Offset, 8, 8);
   end Set_View;

   function Slot_Relative
     (Item : View; Position : Interfaces.Unsigned_64) return Byte_Count is
   begin
      return Layouts.Checked_Add
        (Slots_Offset,
         Layouts.Checked_Multiply
           (Byte_Count
              (Policy.Masked_Index
                 (Position, Policy.Positive_U32 (Item.Capacity_Value))),
            Item.Stride));
   end Slot_Relative;

   function Slot_Address
     (Item : View; Position : Interfaces.Unsigned_64) return System.Address is
   begin
      return Layouts.Address_At
        (Item.Core, Slot_Relative (Item, Position), Item.Stride,
         Storage_Alignment);
   end Slot_Address;

   function Payload_Address
     (Item : View; Slot : System.Address) return System.Address
   is
   begin
      --  Slot_Address has checked the null sentinel, complete slot extent,
      --  alignment, and native conversion. Initialize or Attach has checked
      --  that Payload_Offset and Element_Value fit within the validated
      --  stride,
      --  so this process-local subaddress cannot escape that slot.
      return Native."+"
        (Slot, Native.Storage_Offset (Item.Payload_Offset));
   end Payload_Address;

   pragma Inline_Always
     (Slot_Relative, Slot_Address, Payload_Address);

   procedure Finish_Initialize
     (Item           : out View;
      Core           : Layouts.Local_View;
      Capacity       : Interfaces.Unsigned_32;
      Payload_Offset : Byte_Count;
      Stride         : Byte_Count) is
   begin
      Set_View
        (Item, Core, Capacity, Payload_Offset, Stride);
      Atomic.Store_Release_U64 (Item.Enqueue_Address, 0);
      Atomic.Store_Release_U64 (Item.Dequeue_Address, 0);
      for Slot in Interfaces.Unsigned_32 range 0 .. Capacity - 1 loop
         Atomic.Store_Release_U64
           (Slot_Address (Item, Interfaces.Unsigned_64 (Slot)),
            Interfaces.Unsigned_64 (Slot));
      end loop;
      Layouts.Publish (Item.Core);
   end Finish_Initialize;

   procedure Validate_Sequences
     (Item : View; Enqueue, Dequeue : Interfaces.Unsigned_64)
   is
      Occupancy : constant Interfaces.Unsigned_64 := Enqueue - Dequeue;
      Position, Expected_Sequence : Interfaces.Unsigned_64;
   begin
      if not Policy.Within_Capacity
        (Enqueue, Dequeue, Item.Capacity_Value)
      then
         raise Layout_Error with "MPMC ring claim positions are corrupt";
      end if;
      for Offset in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1
      loop
         Position := Dequeue + Offset;
         Expected_Sequence :=
           (if Offset < Occupancy then Position + 1 else Position);
         if Atomic.Load_Acquire_U64 (Slot_Address (Item, Position)) /=
           Expected_Sequence
         then
            raise Layout_Error with "MPMC slot sequence is corrupt";
         end if;
      end loop;
   end Validate_Sequences;

   procedure Initialize
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive)
   is
      Core : Layouts.Local_View;
      Payload_Offset, Stride, Extent : Byte_Count;
      Capacity_32 : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Capacity);
   begin
      Detach (Item);
      Geometry (Capacity, Payload_Offset, Stride, Extent);
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity, Extent,
         (Capacity     => Capacity_32,
          Element_Size => Interfaces.Unsigned_32 (Element.Size),
          Alignment    => Interfaces.Unsigned_32 (Element.Alignment),
          Auxiliary    => Interfaces.Unsigned_32 (Payload_Offset),
          Word_1       => 0,
          Word_2       => Element.Signature),
         Storage_Alignment);
      Finish_Initialize
        (Item, Core, Capacity_32, Payload_Offset, Stride);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Initialize;

   procedure Create_Or_Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Result       : out Open_Result)
   is
      Core : Layouts.Local_View;
      Claim : Layouts.Initialization_Claim;
      Payload_Offset, Stride, Extent : Byte_Count;
      Capacity_32 : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Capacity);
   begin
      Detach (Item);
      Geometry (Capacity, Payload_Offset, Stride, Extent);
      Layouts.Try_Begin_Initialize
        (Core, Claim, Region, Location, Identity, Extent,
         (Capacity     => Capacity_32,
          Element_Size => Interfaces.Unsigned_32 (Element.Size),
          Alignment    => Interfaces.Unsigned_32 (Element.Alignment),
          Auxiliary    => Interfaces.Unsigned_32 (Payload_Offset),
          Word_1       => 0,
          Word_2       => Element.Signature),
         Storage_Alignment);
      case Claim is
         when Layouts.Claimed_Virgin =>
            Finish_Initialize
              (Item, Core, Capacity_32, Payload_Offset, Stride);
            Result := Initialized_New;
         when Layouts.Existing_Ready =>
            Attach (Item, Region, Location, Capacity);
            Result := Attached_Existing;
         when Layouts.Claim_In_Progress =>
            Result := Initialization_In_Progress;
      end case;
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Create_Or_Attach;

   procedure Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive)
   is
      Core : Layouts.Local_View;
      Header : Layouts.Header_Values;
      Payload_Offset, Stride, Extent : Byte_Count;
   begin
      Detach (Item);
      Geometry (Capacity, Payload_Offset, Stride, Extent);
      Layouts.Attach
        (Core, Header, Region, Location, Identity, Storage_Alignment);
      if Header.Capacity /= Interfaces.Unsigned_32 (Capacity)
        or else Header.Element_Size /= Interfaces.Unsigned_32 (Element.Size)
        or else Header.Alignment /=
          Interfaces.Unsigned_32 (Element.Alignment)
        or else Header.Auxiliary /= Interfaces.Unsigned_32 (Payload_Offset)
        or else Header.Word_1 /= 0
        or else Header.Word_2 /= Element.Signature
        or else Core.Extent /= Extent
      then
         raise Layout_Error with "MPMC ring layout does not match";
      end if;
      Set_View
        (Item, Core, Header.Capacity, Payload_Offset, Stride);
      --  Do not validate the mutable claim positions or slot sequences here.
      --  A producer publishes its position before its slot sequence, while a
      --  consumer publishes its position before releasing that slot.  Either
      --  legitimate in-flight state would look corrupt to an independently
      --  attaching view.  Destroy performs the deep sequence validation only
      --  after the caller has established quiescence.
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Attach;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Capacity_Value := 0;
      Item.Element_Value := 0;
      Item.Mask := 0;
      Item.Payload_Offset := 0;
      Item.Stride := 0;
      Item.Enqueue_Address := System.Null_Address;
      Item.Dequeue_Address := System.Null_Address;
   end Detach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   procedure Poison (Region : Region_View; Location : Region_Offset) is
   begin
      Layouts.Poison_At
        (Region, Location, Identity, Storage_Alignment);
   end Poison;

   function Is_Poisoned (Item : View) return Boolean is
     (Layouts.Is_Poisoned (Item.Core));

   function Binding
     (Item : View;
      Slot : System.Address;
      Writable : Boolean) return Immutable_Storage_View is
     (Base      => Payload_Address (Item, Slot),
      Extent    => Byte_Count (Element.Size),
      Signature => Element.Signature,
      Version   => Element.Version,
      Writable  => Writable);
   pragma Inline_Always (Binding);

   procedure Try_Push
     (Item   : in out View;
      Data   : Element.Source;
      Result : out Push_Result)
   is
      Stored   : constant Element.Value := Element.Create (Data);
      Position : Interfaces.Unsigned_64;
      Sequence : Interfaces.Unsigned_64;
      Expected : Interfaces.Unsigned_64;
      Relation : Policy.Sequence_Relation;
      Slot     : System.Address;
   begin
      Layouts.Require_Ready (Item.Core);
      Position := Atomic.Load_Relaxed_U64
        (Item.Enqueue_Address);
      for Attempt in 1 .. Contention_Limit loop
         pragma Unreferenced (Attempt);
         Slot := Slot_Address (Item, Position);
         Sequence := Atomic.Load_Acquire_U64 (Slot);
         Relation := Policy.Classify_Sequence (Sequence, Position);
         if Relation = Policy.Sequence_Ready then
            Expected := Position;
            if Atomic.Compare_Exchange_U64
              (Item.Enqueue_Address, Expected, Position + 1)
            then
               Element.Copy_To (Stored, Binding (Item, Slot, True));
               Atomic.Store_Release_U64
                 (Slot, Position + 1);
               Result := Pushed;
               return;
            end if;
            Position := Expected;
         elsif Relation = Policy.Sequence_Behind then
            Result := Full;
            return;
         else
            Position := Atomic.Load_Relaxed_U64
              (Item.Enqueue_Address);
         end if;
      end loop;
      Result := Push_Contended;
   end Try_Push;

   procedure Push
     (Item    : in out View;
      Data    : Element.Source;
      Timeout : Wait_Timeout)
   is
      Wait   : Waiting.Context := Waiting.Start (Timeout);
      Result : Push_Result;
   begin
      loop
         Try_Push (Item, Data, Result);
         exit when Result = Pushed;
         Waiting.Retry (Wait);
      end loop;
   end Push;

   procedure Try_Pop
     (Item   : in out View;
      Data   : out Element.Observed;
      Result : out Pop_Result)
   is
      Position : Interfaces.Unsigned_64;
      Sequence : Interfaces.Unsigned_64;
      Expected : Interfaces.Unsigned_64;
      Relation : Policy.Sequence_Relation;
      Slot     : System.Address;
      Source   : Element.Const_Ref;
   begin
      Layouts.Require_Ready (Item.Core);
      Position := Atomic.Load_Relaxed_U64
        (Item.Dequeue_Address);
      for Attempt in 1 .. Contention_Limit loop
         pragma Unreferenced (Attempt);
         Slot := Slot_Address (Item, Position);
         Sequence := Atomic.Load_Acquire_U64 (Slot);
         Relation := Policy.Classify_Sequence (Sequence, Position + 1);
         if Relation = Policy.Sequence_Ready then
            Expected := Position;
            if Atomic.Compare_Exchange_U64
              (Item.Dequeue_Address, Expected, Position + 1)
            then
               Element.Bind (Source, Binding (Item, Slot, False));
               begin
                  Data := Element.Observe (Source);
               exception
                  when others =>
                     Layouts.Poison (Item.Core);
                     raise;
               end;
               Atomic.Store_Release_U64
                 (Slot,
                  Position + Interfaces.Unsigned_64 (Item.Capacity_Value));
               Result := Popped;
               return;
            end if;
            Position := Expected;
         elsif Relation = Policy.Sequence_Behind then
            Result := Empty;
            return;
         else
            Position := Atomic.Load_Relaxed_U64
              (Item.Dequeue_Address);
         end if;
      end loop;
      Result := Pop_Contended;
   end Try_Pop;

   procedure Pop
     (Item    : in out View;
      Data    : out Element.Observed;
      Timeout : Wait_Timeout)
   is
      Wait   : Waiting.Context := Waiting.Start (Timeout);
      Result : Pop_Result;
   begin
      loop
         Try_Pop (Item, Data, Result);
         exit when Result = Popped;
         Waiting.Retry (Wait);
      end loop;
   end Pop;

   procedure Destroy (Item : in out View) is
      Enqueue, Dequeue : Interfaces.Unsigned_64;
   begin
      Layouts.Require_Ready (Item.Core);
      Enqueue := Atomic.Load_Acquire_U64
        (Item.Enqueue_Address);
      Dequeue := Atomic.Load_Acquire_U64
        (Item.Dequeue_Address);
      if Enqueue /= Dequeue then
         raise Program_Error with "cannot destroy a nonempty MPMC ring";
      end if;
      Validate_Sequences (Item, Enqueue, Dequeue);
      Layouts.Mark_Destroyed (Item.Core);
      Detach (Item);
   end Destroy;

end Flyology.Data_Structures.Rings.MPMC;
