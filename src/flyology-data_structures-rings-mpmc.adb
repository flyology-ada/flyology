with Ada.Unchecked_Conversion;
with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Storage;
with Interfaces.C;

package body Flyology.Data_Structures.Rings.MPMC is
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Bytes renames Flyology.Data_Structures.Storage;

   use type Interfaces.Integer_64;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Enqueue_Offset : constant Byte_Count := 64;
   Dequeue_Offset : constant Byte_Count := 128;
   Slots_Offset   : constant Byte_Count := 192;
   Sequence_Size  : constant Byte_Count := 8;

   function As_Signed is new Ada.Unchecked_Conversion
     (Interfaces.Unsigned_64, Interfaces.Integer_64);

   procedure Geometry
     (Capacity       : Positive;
      Element_Size   : Positive;
      Payload_Offset : out Byte_Count;
      Stride         : out Byte_Count;
      Extent         : out Byte_Count) is
   begin
      if (Interfaces.Unsigned_64 (Capacity) and
          (Interfaces.Unsigned_64 (Capacity) - 1)) /= 0
      then
         raise Constraint_Error with "MPMC capacity must be a power of two";
      end if;
      Payload_Offset := Sequence_Size;
      Stride := Layouts.Align_Up
        (Layouts.Checked_Add (Payload_Offset, Byte_Count (Element_Size)), 8);
      Extent := Layouts.Checked_Add
        (Slots_Offset,
         Layouts.Checked_Multiply (Byte_Count (Capacity), Stride));
   end Geometry;

   function Required_Storage
     (Capacity : Positive; Element_Size : Positive) return Byte_Count
   is
      Payload_Offset, Stride, Extent : Byte_Count;
   begin
      Geometry (Capacity, Element_Size, Payload_Offset, Stride, Extent);
      return Extent;
   end Required_Storage;

   procedure Set_View
     (Item : out View; Core : Layouts.Local_View;
      Capacity, Element_Size : Interfaces.Unsigned_32;
      Payload_Offset, Stride : Byte_Count) is
   begin
      Item.Core := Core;
      Item.Capacity_Value := Capacity;
      Item.Element_Value := Element_Size;
      Item.Mask := Interfaces.Unsigned_64 (Capacity) - 1;
      Item.Payload_Offset := Payload_Offset;
      Item.Stride := Stride;
   end Set_View;

   function Slot_Relative
     (Item : View; Position : Interfaces.Unsigned_64) return Byte_Count is
   begin
      return Layouts.Checked_Add
        (Slots_Offset,
         Layouts.Checked_Multiply
           (Byte_Count (Position and Item.Mask), Item.Stride));
   end Slot_Relative;

   function Sequence_Address
     (Item : View; Position : Interfaces.Unsigned_64) return System.Address is
   begin
      return Layouts.Address_At
        (Item.Core, Slot_Relative (Item, Position), 8, 8);
   end Sequence_Address;

   function Payload_Address
     (Item : View; Position : Interfaces.Unsigned_64) return System.Address is
   begin
      return Layouts.Address_At
        (Item.Core,
         Layouts.Checked_Add
           (Slot_Relative (Item, Position), Item.Payload_Offset),
         Byte_Count (Item.Element_Value), 1);
   end Payload_Address;

   procedure Initialize
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive)
   is
      Core : Layouts.Local_View;
      Payload_Offset, Stride, Extent : Byte_Count;
      Capacity_32 : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Capacity);
   begin
      Geometry (Capacity, Element_Size, Payload_Offset, Stride, Extent);
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity, Extent,
         (Capacity     => Capacity_32,
          Element_Size => Interfaces.Unsigned_32 (Element_Size),
          Alignment    => 8,
          Auxiliary    => Interfaces.Unsigned_32 (Payload_Offset),
          Word_1       => 0,
          Word_2       => 0),
         8);
      Set_View
        (Item, Core, Capacity_32, Interfaces.Unsigned_32 (Element_Size),
         Payload_Offset, Stride);
      Atomic.Store_Release_U64
        (Layouts.Address_At (Item.Core, Enqueue_Offset, 8, 8), 0);
      Atomic.Store_Release_U64
        (Layouts.Address_At (Item.Core, Dequeue_Offset, 8, 8), 0);
      for Slot in Interfaces.Unsigned_32 range 0 .. Capacity_32 - 1 loop
         Atomic.Store_Release_U64
           (Sequence_Address (Item, Interfaces.Unsigned_64 (Slot)),
            Interfaces.Unsigned_64 (Slot));
      end loop;
      Layouts.Publish (Item.Core);
   end Initialize;

   procedure Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive)
   is
      Core : Layouts.Local_View;
      Header : Layouts.Header_Values;
      Payload_Offset, Stride, Extent : Byte_Count;
      Enqueue, Dequeue : Interfaces.Unsigned_64;
      Occupancy : Interfaces.Unsigned_64;
      Position, Expected_Sequence : Interfaces.Unsigned_64;
   begin
      Geometry (Capacity, Element_Size, Payload_Offset, Stride, Extent);
      Layouts.Attach (Core, Header, Region, Location, Identity, 8);
      if Header.Capacity /= Interfaces.Unsigned_32 (Capacity)
        or else Header.Element_Size /= Interfaces.Unsigned_32 (Element_Size)
        or else Header.Alignment /= 8
        or else Header.Auxiliary /= Interfaces.Unsigned_32 (Payload_Offset)
        or else Header.Word_1 /= 0
        or else Header.Word_2 /= 0
        or else Core.Extent /= Extent
      then
         raise Layout_Error with "MPMC ring layout does not match";
      end if;
      Set_View
        (Item, Core, Header.Capacity, Header.Element_Size,
         Payload_Offset, Stride);
      Enqueue := Atomic.Load_Acquire_U64
        (Layouts.Address_At (Item.Core, Enqueue_Offset, 8, 8));
      Dequeue := Atomic.Load_Acquire_U64
        (Layouts.Address_At (Item.Core, Dequeue_Offset, 8, 8));
      Occupancy := Enqueue - Dequeue;
      if Occupancy > Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "MPMC ring claim positions are corrupt";
      end if;
      for Offset in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1
      loop
         Position := Dequeue + Offset;
         Expected_Sequence :=
           (if Offset < Occupancy then Position + 1 else Position);
         if Atomic.Load_Acquire_U64 (Sequence_Address (Item, Position)) /=
           Expected_Sequence
         then
            raise Layout_Error with "MPMC slot sequence is corrupt";
         end if;
      end loop;
   end Attach;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Capacity_Value := 0;
      Item.Element_Value := 0;
      Item.Mask := 0;
      Item.Payload_Offset := 0;
      Item.Stride := 0;
   end Detach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   procedure Check_Data (Item : View; Length : Natural) is
   begin
      if Byte_Count (Length) /= Byte_Count (Item.Element_Value) then
         raise Constraint_Error with "MPMC element length does not match";
      end if;
   end Check_Data;

   procedure Try_Push
     (Item   : in out View;
      Data   : Ada.Streams.Stream_Element_Array;
      Result : out Push_Result)
   is
      Position : Interfaces.Unsigned_64;
      Sequence : Interfaces.Unsigned_64;
      Expected : Interfaces.Unsigned_64;
      Difference : Interfaces.Integer_64;
   begin
      Check_Data (Item, Data'Length);
      Layouts.Require_Ready (Item.Core);
      Position := Atomic.Load_Relaxed_U64
        (Layouts.Address_At (Item.Core, Enqueue_Offset, 8, 8));
      for Attempt in 1 .. Contention_Limit loop
         pragma Unreferenced (Attempt);
         Sequence := Atomic.Load_Acquire_U64
           (Sequence_Address (Item, Position));
         Difference := As_Signed (Sequence - Position);
         if Difference = 0 then
            Expected := Position;
            if Atomic.Compare_Exchange_U64
              (Layouts.Address_At (Item.Core, Enqueue_Offset, 8, 8),
               Expected, Position + 1)
            then
               Bytes.Copy
                 (Payload_Address (Item, Position), Data'Address,
                  Interfaces.C.size_t (Data'Length));
               Atomic.Store_Release_U64
                 (Sequence_Address (Item, Position), Position + 1);
               Result := Pushed;
               return;
            end if;
            Position := Expected;
         elsif Difference < 0 then
            Result := Full;
            return;
         else
            Position := Atomic.Load_Relaxed_U64
              (Layouts.Address_At (Item.Core, Enqueue_Offset, 8, 8));
         end if;
      end loop;
      Result := Push_Contended;
   end Try_Push;

   procedure Try_Pop
     (Item   : in out View;
      Data   : out Ada.Streams.Stream_Element_Array;
      Result : out Pop_Result)
   is
      Position : Interfaces.Unsigned_64;
      Sequence : Interfaces.Unsigned_64;
      Expected : Interfaces.Unsigned_64;
      Difference : Interfaces.Integer_64;
   begin
      Check_Data (Item, Data'Length);
      Layouts.Require_Ready (Item.Core);
      Position := Atomic.Load_Relaxed_U64
        (Layouts.Address_At (Item.Core, Dequeue_Offset, 8, 8));
      for Attempt in 1 .. Contention_Limit loop
         pragma Unreferenced (Attempt);
         Sequence := Atomic.Load_Acquire_U64
           (Sequence_Address (Item, Position));
         Difference := As_Signed (Sequence - (Position + 1));
         if Difference = 0 then
            Expected := Position;
            if Atomic.Compare_Exchange_U64
              (Layouts.Address_At (Item.Core, Dequeue_Offset, 8, 8),
               Expected, Position + 1)
            then
               Bytes.Copy
                 (Data'Address, Payload_Address (Item, Position),
                  Interfaces.C.size_t (Data'Length));
               Atomic.Store_Release_U64
                 (Sequence_Address (Item, Position),
                  Position + Interfaces.Unsigned_64 (Item.Capacity_Value));
               Result := Popped;
               return;
            end if;
            Position := Expected;
         elsif Difference < 0 then
            Result := Empty;
            return;
         else
            Position := Atomic.Load_Relaxed_U64
              (Layouts.Address_At (Item.Core, Dequeue_Offset, 8, 8));
         end if;
      end loop;
      Result := Pop_Contended;
   end Try_Pop;

   procedure Destroy (Item : in out View) is
      Enqueue, Dequeue : Interfaces.Unsigned_64;
   begin
      Layouts.Require_Ready (Item.Core);
      Enqueue := Atomic.Load_Acquire_U64
        (Layouts.Address_At (Item.Core, Enqueue_Offset, 8, 8));
      Dequeue := Atomic.Load_Acquire_U64
        (Layouts.Address_At (Item.Core, Dequeue_Offset, 8, 8));
      if Enqueue /= Dequeue then
         raise Program_Error with "cannot destroy a nonempty MPMC ring";
      end if;
      Layouts.Mark_Destroyed (Item.Core);
      Detach (Item);
   end Destroy;

end Flyology.Data_Structures.Rings.MPMC;
