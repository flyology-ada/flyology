with Flyology.Data_Structures.Storage;
with Interfaces.C;

package body Flyology.Data_Structures.Slab_Pools is
   package Bytes renames Flyology.Data_Structures.Storage;

   use type Handles.Generation;
   use type Handles.Slot_Index;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Slot_Metadata_Size : constant Byte_Count := 16;
   Generation_Offset  : constant Byte_Count := 0;
   State_Offset       : constant Byte_Count := 4;
   Next_Offset        : constant Byte_Count := 8;
   Free_State         : constant Interfaces.Unsigned_32 := 0;
   Live_State         : constant Interfaces.Unsigned_32 := 1;

   function U32 (Value : Positive) return Interfaces.Unsigned_32 is
   begin
      return Interfaces.Unsigned_32 (Value);
   end U32;

   procedure Geometry
     (Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive;
      Payload_Offset    : out Byte_Count;
      Stride            : out Byte_Count;
      Extent            : out Byte_Count)
   is
      Alignment : constant Byte_Count := Byte_Count (Element_Alignment);
      Base_Alignment : constant Byte_Count := Byte_Count'Max (8, Alignment);
   begin
      if Alignment > Byte_Count (Interfaces.Unsigned_32'Last) then
         raise Constraint_Error with "slab alignment exceeds 32 bits";
      end if;
      Payload_Offset := Layouts.Align_Up (Slot_Metadata_Size, Alignment);
      Stride := Layouts.Align_Up
        (Layouts.Checked_Add (Payload_Offset, Byte_Count (Element_Size)),
         Base_Alignment);
      Extent := Layouts.Checked_Add
        (Layouts.Header_Size,
         Layouts.Checked_Multiply (Byte_Count (Capacity), Stride));
   end Geometry;

   function Required_Storage
     (Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive := 1) return Byte_Count
   is
      Payload_Offset : Byte_Count;
      Stride         : Byte_Count;
      Extent         : Byte_Count;
   begin
      Geometry
        (Capacity, Element_Size, Element_Alignment,
         Payload_Offset, Stride, Extent);
      return Extent;
   end Required_Storage;

   function Field_Address
     (Item   : View;
      Slot   : Interfaces.Unsigned_32;
      Offset : Byte_Count;
      Extent : Byte_Count;
      Alignment : Byte_Count) return System.Address
   is
      Slot_Relative : constant Byte_Count := Layouts.Checked_Add
        (Layouts.Header_Size,
         Layouts.Checked_Multiply (Byte_Count (Slot - 1), Item.Stride));
   begin
      if Offset > Item.Stride or else Extent > Item.Stride - Offset then
         raise Layout_Error with "slab field exceeds its slot";
      end if;
      return Layouts.Address_At
        (Item.Core, Layouts.Checked_Add (Slot_Relative, Offset),
         Extent, Alignment);
   end Field_Address;

   procedure Set_View
     (Item           : out View;
      Core           : Layouts.Local_View;
      Capacity       : Interfaces.Unsigned_32;
      Element_Size   : Interfaces.Unsigned_32;
      Alignment      : Interfaces.Unsigned_32;
      Payload_Offset : Byte_Count;
      Stride         : Byte_Count) is
   begin
      Item.Core := Core;
      Item.Capacity_Value := Capacity;
      Item.Element_Value := Element_Size;
      Item.Alignment_Value := Alignment;
      Item.Payload_Offset := Payload_Offset;
      Item.Stride := Stride;
      Item.Free_Head_Address := Layouts.Address_At (Core, 56, 8, 8);
   end Set_View;

   procedure Initialize
     (Item              : out View;
      Region            : Region_View;
      Location          : Region_Offset;
      Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive := 1)
   is
      Payload_Offset : Byte_Count;
      Stride         : Byte_Count;
      Extent         : Byte_Count;
      Core           : Layouts.Local_View;
      Capacity_32    : constant Interfaces.Unsigned_32 := U32 (Capacity);
      Element_32     : constant Interfaces.Unsigned_32 := U32 (Element_Size);
      Alignment_32   : constant Interfaces.Unsigned_32 :=
        U32 (Element_Alignment);
   begin
      Geometry
        (Capacity, Element_Size, Element_Alignment,
         Payload_Offset, Stride, Extent);
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity, Extent,
         (Capacity     => Capacity_32,
          Element_Size => Element_32,
          Alignment    => Alignment_32,
          Auxiliary    => Interfaces.Unsigned_32 (Payload_Offset),
          Word_1       => Interfaces.Unsigned_64 (Stride),
          Word_2       => 1),
         Byte_Count'Max (8, Byte_Count (Alignment_32)));
      Set_View
        (Item, Core, Capacity_32, Element_32, Alignment_32,
         Payload_Offset, Stride);

      for Slot in Interfaces.Unsigned_32 range 1 .. Capacity_32 loop
         Bytes.Write_U32
           (Field_Address (Item, Slot, Generation_Offset, 4, 4), 1);
         Bytes.Write_U32
           (Field_Address (Item, Slot, State_Offset, 4, 4), Free_State);
         Bytes.Write_U32
           (Field_Address (Item, Slot, Next_Offset, 4, 4),
            (if Slot = Capacity_32 then 0 else Slot + 1));
      end loop;
      Layouts.Publish (Item.Core);
   end Initialize;

   procedure Validate_Free_List (Item : View) is
      Free_Count : Interfaces.Unsigned_32 := 0;
      Walk_Count : Interfaces.Unsigned_32 := 0;
      Current : Interfaces.Unsigned_64 := Bytes.Read_U64
        (Item.Free_Head_Address);
      State : Interfaces.Unsigned_32;
   begin
      if Current > Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "slab free-list head is out of range";
      end if;
      for Slot in Interfaces.Unsigned_32 range 1 .. Item.Capacity_Value loop
         State := Bytes.Read_U32
           (Field_Address (Item, Slot, State_Offset, 4, 4));
         if Bytes.Read_U32
           (Field_Address (Item, Slot, Generation_Offset, 4, 4)) = 0
           or else State > Live_State
           or else Bytes.Read_U32
             (Field_Address (Item, Slot, Next_Offset, 4, 4)) >
               Item.Capacity_Value
         then
            raise Layout_Error with "slab slot metadata is corrupt";
         elsif State = Free_State then
            Free_Count := Free_Count + 1;
         end if;
      end loop;

      while Current /= 0 loop
         Walk_Count := Walk_Count + 1;
         if Walk_Count > Free_Count
           or else Bytes.Read_U32
             (Field_Address
                (Item, Interfaces.Unsigned_32 (Current), State_Offset, 4, 4))
               /= Free_State
         then
            raise Layout_Error with "slab free list is cyclic or inconsistent";
         end if;
         Current := Interfaces.Unsigned_64
           (Bytes.Read_U32
              (Field_Address
                 (Item, Interfaces.Unsigned_32 (Current), Next_Offset, 4, 4)));
      end loop;
      if Walk_Count /= Free_Count then
         raise Layout_Error with "slab free list omits free slots";
      end if;
   end Validate_Free_List;

   procedure Attach
     (Item              : out View;
      Region            : Region_View;
      Location          : Region_Offset;
      Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive := 1)
   is
      Expected_Payload : Byte_Count;
      Expected_Stride  : Byte_Count;
      Expected_Extent  : Byte_Count;
      Core             : Layouts.Local_View;
      Header           : Layouts.Header_Values;
   begin
      Geometry
        (Capacity, Element_Size, Element_Alignment,
         Expected_Payload, Expected_Stride, Expected_Extent);
      Layouts.Attach
        (Core, Header, Region, Location, Identity,
         Byte_Count'Max (8, Byte_Count (Element_Alignment)));
      if Header.Capacity /= U32 (Capacity)
        or else Header.Element_Size /= U32 (Element_Size)
        or else Header.Alignment /= U32 (Element_Alignment)
        or else Header.Auxiliary /= Interfaces.Unsigned_32 (Expected_Payload)
        or else Header.Word_1 /= Interfaces.Unsigned_64 (Expected_Stride)
        or else Core.Extent /= Expected_Extent
        or else Header.Word_2 > Interfaces.Unsigned_64 (Header.Capacity)
      then
         raise Layout_Error with "slab configuration does not match";
      end if;
      Set_View
        (Item, Core, Header.Capacity, Header.Element_Size, Header.Alignment,
         Expected_Payload, Expected_Stride);
      Validate_Free_List (Item);
   end Attach;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Capacity_Value := 0;
      Item.Element_Value := 0;
      Item.Alignment_Value := 0;
      Item.Payload_Offset := 0;
      Item.Stride := 0;
      Item.Free_Head_Address := System.Null_Address;
   end Detach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   function Current_Metadata (Item : View) return Metadata is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached slab view";
      end if;
      return
        (Capacity          => Item.Capacity_Value,
         Element_Size      => Item.Element_Value,
         Element_Alignment => Item.Alignment_Value,
         Extent            => Item.Core.Extent);
   end Current_Metadata;

   procedure Check_Handle (Item : View; Value : Handles.Handle) is
      Slot : Interfaces.Unsigned_32;
   begin
      Layouts.Require_Ready (Item.Core);
      if Value.Slot = 0 or else Value.Stamp = 0
        or else Interfaces.Unsigned_64 (Value.Slot) >
          Interfaces.Unsigned_64 (Item.Capacity_Value)
      then
         raise Handle_Error with "malformed or out-of-range slab handle";
      end if;
      Slot := Interfaces.Unsigned_32 (Value.Slot);
      if Bytes.Read_U32
        (Field_Address (Item, Slot, Generation_Offset, 4, 4)) /=
          Interfaces.Unsigned_32 (Value.Stamp)
        or else Bytes.Read_U32
          (Field_Address (Item, Slot, State_Offset, 4, 4)) /= Live_State
      then
         raise Handle_Error with "stale or reclaimed slab handle";
      end if;
   end Check_Handle;

   procedure Try_Allocate
     (Item      : in out View;
      Value     : out Handles.Handle;
      Allocated : out Boolean)
   is
      Head : Interfaces.Unsigned_64;
      Slot : Interfaces.Unsigned_32;
      Next : Interfaces.Unsigned_32;
      Generation : Interfaces.Unsigned_32;
   begin
      Layouts.Require_Ready (Item.Core);
      Head := Bytes.Read_U64 (Item.Free_Head_Address);
      if Head = 0 then
         Value := Handles.Null_Handle;
         Allocated := False;
         return;
      elsif Head > Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "slab free-list head is out of range";
      end if;
      Slot := Interfaces.Unsigned_32 (Head);
      Generation := Bytes.Read_U32
        (Field_Address (Item, Slot, Generation_Offset, 4, 4));
      Next := Bytes.Read_U32
        (Field_Address (Item, Slot, Next_Offset, 4, 4));
      if Generation = 0
        or else Next > Item.Capacity_Value
        or else Bytes.Read_U32
          (Field_Address (Item, Slot, State_Offset, 4, 4)) /= Free_State
      then
         raise Layout_Error with "slab free-list slot is corrupt";
      end if;
      Bytes.Write_U64
        (Item.Free_Head_Address, Interfaces.Unsigned_64 (Next));
      Bytes.Write_U32
        (Field_Address (Item, Slot, State_Offset, 4, 4), Live_State);
      Value :=
        (Slot  => Handles.Slot_Index (Slot),
         Stamp => Handles.Generation (Generation));
      Allocated := True;
   end Try_Allocate;

   procedure Release
     (Item  : in out View;
      Value : Handles.Handle)
   is
      Slot : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Value.Slot);
      Generation : Interfaces.Unsigned_32;
      Head : Interfaces.Unsigned_64;
   begin
      Check_Handle (Item, Value);
      Head := Bytes.Read_U64 (Item.Free_Head_Address);
      if Head > Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "slab free-list head is out of range";
      end if;
      Generation := Interfaces.Unsigned_32 (Value.Stamp) + 1;
      if Generation = 0 then
         Generation := 1;
      end if;
      Bytes.Write_U32
        (Field_Address (Item, Slot, Generation_Offset, 4, 4), Generation);
      Bytes.Write_U32
        (Field_Address (Item, Slot, Next_Offset, 4, 4),
         Interfaces.Unsigned_32 (Head));
      Bytes.Write_U32
        (Field_Address (Item, Slot, State_Offset, 4, 4), Free_State);
      Bytes.Write_U64
        (Item.Free_Head_Address, Interfaces.Unsigned_64 (Slot));
   end Release;

   function Payload_Address
     (Item : View; Value : Handles.Handle) return System.Address is
      Slot : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Value.Slot);
   begin
      Check_Handle (Item, Value);
      return Field_Address
        (Item, Slot, Item.Payload_Offset, Byte_Count (Item.Element_Value),
         Byte_Count (Item.Alignment_Value));
   end Payload_Address;

   procedure Check_Length (Item : View; Length : Natural) is
   begin
      if Byte_Count (Length) /= Byte_Count (Item.Element_Value) then
         raise Constraint_Error with "slab payload length does not match";
      end if;
   end Check_Length;

   procedure Read
     (Item  : View;
      Value : Handles.Handle;
      Data  : out Ada.Streams.Stream_Element_Array) is
   begin
      Check_Length (Item, Data'Length);
      Bytes.Copy
        (Data'Address, Payload_Address (Item, Value),
         Interfaces.C.size_t (Data'Length));
   end Read;

   procedure Write
     (Item  : in out View;
      Value : Handles.Handle;
      Data  : Ada.Streams.Stream_Element_Array) is
   begin
      Check_Length (Item, Data'Length);
      Bytes.Copy
        (Payload_Address (Item, Value), Data'Address,
         Interfaces.C.size_t (Data'Length));
   end Write;

   procedure Destroy (Item : in out View) is
   begin
      Layouts.Require_Ready (Item.Core);
      for Slot in Interfaces.Unsigned_32 range 1 .. Item.Capacity_Value loop
         if Bytes.Read_U32
           (Field_Address (Item, Slot, State_Offset, 4, 4)) = Live_State
         then
            raise Program_Error with "cannot destroy a slab with live slots";
         end if;
      end loop;
      Layouts.Mark_Destroyed (Item.Core);
      Detach (Item);
   end Destroy;

end Flyology.Data_Structures.Slab_Pools;
