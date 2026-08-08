with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Policy;
with Flyology.Data_Structures.Storage;
with Flyology.Data_Structures.Waits;
with Interfaces.C;

package body Flyology.Data_Structures.Slab_Pools is
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Policy renames Flyology.Data_Structures.Policy;
   package Bytes renames Flyology.Data_Structures.Storage;
   package Waiting renames Flyology.Data_Structures.Waits;

   use type Handles.Generation;
   use type Handles.Slot_Index;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Slot_Metadata_Size : constant Byte_Count := 16;
   Generation_Offset  : constant Byte_Count := 0;
   State_Offset       : constant Byte_Count := 4;
   Next_Offset        : constant Byte_Count := 8;

   Free_State       : constant Interfaces.Unsigned_32 := 0;
   Live_State       : constant Interfaces.Unsigned_32 := 1;
   Allocating_State : constant Interfaces.Unsigned_32 := 2;
   Accessing_State  : constant Interfaces.Unsigned_32 := 3;
   Releasing_State  : constant Interfaces.Unsigned_32 := 4;
   Poisoned_State   : constant Interfaces.Unsigned_32 := 5;
   Timed_Contention_Limit : constant Positive := 16;

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
     (Item      : View;
      Slot      : Interfaces.Unsigned_32;
      Offset    : Byte_Count;
      Extent    : Byte_Count;
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

   function Generation_Address
     (Item : View; Slot : Interfaces.Unsigned_32) return System.Address is
     (Field_Address (Item, Slot, Generation_Offset, 4, 4));

   function State_Address
     (Item : View; Slot : Interfaces.Unsigned_32) return System.Address is
     (Field_Address (Item, Slot, State_Offset, 4, 4));

   function Next_Address
     (Item : View; Slot : Interfaces.Unsigned_32) return System.Address is
     (Field_Address (Item, Slot, Next_Offset, 4, 4));

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
      Item.Allocation_Cursor_Address := Layouts.Address_At (Core, 56, 8, 8);
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
      Detach (Item);
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
          Word_2       => 0),
         Byte_Count'Max (8, Byte_Count (Alignment_32)));
      Set_View
        (Item, Core, Capacity_32, Element_32, Alignment_32,
         Payload_Offset, Stride);

      for Slot in Interfaces.Unsigned_32 range 1 .. Capacity_32 loop
         Bytes.Write_U32 (Generation_Address (Item, Slot), 1);
         Bytes.Write_U32 (State_Address (Item, Slot), Free_State);
         Bytes.Write_U32 (Next_Address (Item, Slot), 0);
      end loop;
      Layouts.Publish (Item.Core);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Initialize;

   procedure Validate_Slots (Item : View) is
      State : Interfaces.Unsigned_32;
   begin
      for Slot in Interfaces.Unsigned_32 range 1 .. Item.Capacity_Value loop
         State := Atomic.Load_Acquire_U32 (State_Address (Item, Slot));
         if Bytes.Read_U32 (Generation_Address (Item, Slot)) = 0
           or else State > Poisoned_State
           or else Bytes.Read_U32 (Next_Address (Item, Slot)) /= 0
         then
            raise Layout_Error with "slab slot metadata is corrupt";
         end if;
      end loop;
   end Validate_Slots;

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
      Detach (Item);
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
      then
         raise Layout_Error with "slab configuration does not match";
      end if;
      Set_View
        (Item, Core, Header.Capacity, Header.Element_Size, Header.Alignment,
         Expected_Payload, Expected_Stride);
      Validate_Slots (Item);
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
      Item.Alignment_Value := 0;
      Item.Payload_Offset := 0;
      Item.Stride := 0;
      Item.Allocation_Cursor_Address := System.Null_Address;
   end Detach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   function Current_Metadata (Item : View) return Metadata is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached slab view";
      end if;
      Layouts.Require_Ready (Item.Core);
      return
        (Capacity          => Item.Capacity_Value,
         Element_Size      => Item.Element_Value,
         Element_Alignment => Item.Alignment_Value,
         Extent            => Item.Core.Extent);
   end Current_Metadata;

   procedure Check_Slot
     (Item : View;
      Slot : Handles.Slot_Index;
      Value : out Interfaces.Unsigned_32) is
   begin
      Layouts.Require_Ready (Item.Core);
      if Slot = 0
        or else Interfaces.Unsigned_64 (Slot) >
          Interfaces.Unsigned_64 (Item.Capacity_Value)
      then
         raise Handle_Error with "null or out-of-range slab slot";
      end if;
      Value := Interfaces.Unsigned_32 (Slot);
   end Check_Slot;

   procedure Check_Handle_Shape
     (Item  : View;
      Value : Handles.Handle;
      Slot  : out Interfaces.Unsigned_32) is
   begin
      Check_Slot (Item, Value.Slot, Slot);
      if Value.Stamp = 0 then
         raise Handle_Error with "zero-generation slab handle";
      end if;
   end Check_Handle_Shape;

   procedure Acquire_Live
     (Item          : View;
      Value         : Handles.Handle;
      Desired_State : Interfaces.Unsigned_32;
      Slot          : out Interfaces.Unsigned_32;
      Attempts      : Positive := Contention_Limit)
   is
      State    : Interfaces.Unsigned_32;
      Expected : Interfaces.Unsigned_32;
   begin
      Check_Handle_Shape (Item, Value, Slot);
      for Attempt in 1 .. Attempts loop
         pragma Unreferenced (Attempt);
         State := Atomic.Load_Acquire_U32 (State_Address (Item, Slot));
         if State = Poisoned_State then
            raise Poison_Error with "slab slot is poisoned";
         elsif State = Free_State then
            raise Handle_Error with "stale or reclaimed slab handle";
         elsif State = Live_State then
            Expected := Live_State;
            if Atomic.Compare_Exchange_U32
              (State_Address (Item, Slot), Expected, Desired_State)
            then
               if Bytes.Read_U32 (Generation_Address (Item, Slot)) /=
                 Interfaces.Unsigned_32 (Value.Stamp)
               then
                  Atomic.Store_Release_U32
                    (State_Address (Item, Slot), Live_State);
                  raise Handle_Error with "stale slab handle";
               end if;
               return;
            end if;
         elsif State > Poisoned_State then
            raise Layout_Error with "slab slot state is corrupt";
         end if;
      end loop;
      raise Busy_Error with "slab slot claim budget exhausted";
   end Acquire_Live;

   procedure Acquire_Live
     (Item          : View;
      Value         : Handles.Handle;
      Desired_State : Interfaces.Unsigned_32;
      Timeout       : Wait_Timeout;
      Slot          : out Interfaces.Unsigned_32)
   is
      Wait : Waiting.Context := Waiting.Start (Timeout);
   begin
      loop
         begin
            Acquire_Live
              (Item, Value, Desired_State, Slot,
               Attempts => Timed_Contention_Limit);
            return;
         exception
            when Busy_Error =>
               Waiting.Retry (Wait);
         end;
      end loop;
   end Acquire_Live;

   procedure Try_Allocate
     (Item   : in out View;
      Value  : out Handles.Handle;
      Result : out Allocation_Result)
   is
      Cursor     : Interfaces.Unsigned_64;
      Expected_Cursor : Interfaces.Unsigned_64;
      Slot       : Interfaces.Unsigned_32;
      State      : Interfaces.Unsigned_32;
      State_Expected : Interfaces.Unsigned_32;
      Generation : Interfaces.Unsigned_32;
      Saw_Free_Contention : Boolean := False;
   begin
      Layouts.Require_Ready (Item.Core);
      Value := Handles.Null_Handle;
      Cursor := Atomic.Load_Relaxed_U64 (Item.Allocation_Cursor_Address);
      Expected_Cursor := Cursor;
      if not Atomic.Compare_Exchange_U64
        (Item.Allocation_Cursor_Address, Expected_Cursor, Cursor + 1)
      then
         Cursor := Expected_Cursor;
      end if;
      for Offset in Interfaces.Unsigned_32 range
        0 .. Item.Capacity_Value - 1
      loop
         Slot := Policy.Allocation_Slot
           (Cursor, Offset, Policy.Positive_U32 (Item.Capacity_Value));
         State := Atomic.Load_Acquire_U32 (State_Address (Item, Slot));
         if State = Free_State then
            State_Expected := Free_State;
            if Atomic.Compare_Exchange_U32
              (State_Address (Item, Slot), State_Expected, Allocating_State)
            then
               Generation := Bytes.Read_U32 (Generation_Address (Item, Slot));
               if Generation = 0 then
                  State_Expected := Allocating_State;
                  if Atomic.Compare_Exchange_U32
                    (State_Address (Item, Slot), State_Expected,
                     Poisoned_State)
                  then
                     null;
                  end if;
                  raise Layout_Error with "slab allocation generation is zero";
               end if;
               State_Expected := Allocating_State;
               if not Atomic.Compare_Exchange_U32
                 (State_Address (Item, Slot), State_Expected, Live_State)
               then
                  if State_Expected = Poisoned_State then
                     raise Poison_Error with "slab allocation was poisoned";
                  else
                     raise Layout_Error with "slab allocation state changed";
                  end if;
               end if;
               Value :=
                 (Slot  => Handles.Slot_Index (Slot),
                  Stamp => Handles.Generation (Generation));
               Result := Allocated;
               return;
            else
               Saw_Free_Contention := True;
            end if;
         elsif State > Poisoned_State then
            raise Layout_Error with "slab slot state is corrupt";
         end if;
      end loop;
      Result :=
        (if Saw_Free_Contention then Allocation_Contended else Exhausted);
   end Try_Allocate;

   procedure Try_Allocate
     (Item    : in out View;
      Timeout : Wait_Timeout;
      Value   : out Handles.Handle;
      Result  : out Allocation_Result)
   is
      Wait : Waiting.Context := Waiting.Start (Timeout);
   begin
      loop
         Try_Allocate (Item, Value, Result);
         exit when Result /= Allocation_Contended;
         Waiting.Retry (Wait);
      end loop;
   end Try_Allocate;

   procedure Release
     (Item  : in out View;
      Value : Handles.Handle)
   is
      Slot : Interfaces.Unsigned_32;
      Expected : Interfaces.Unsigned_32 := Releasing_State;
      Generation : Interfaces.Unsigned_32;
   begin
      Acquire_Live (Item, Value, Releasing_State, Slot);
      if not Policy.Generation_Can_Advance
        (Interfaces.Unsigned_32 (Value.Stamp))
      then
         if not Atomic.Compare_Exchange_U32
           (State_Address (Item, Slot), Expected, Poisoned_State)
         then
            if Expected = Poisoned_State then
               raise Poison_Error with "slab generation was retired";
            else
               raise Layout_Error with "slab retirement state changed";
            end if;
         end if;
         raise Poison_Error with
           "slab generation is exhausted; exclusive reinitialization required";
      end if;
      Generation := Policy.Next_Generation
        (Interfaces.Unsigned_32 (Value.Stamp));
      Bytes.Write_U32 (Generation_Address (Item, Slot), Generation);
      if not Atomic.Compare_Exchange_U32
        (State_Address (Item, Slot), Expected, Free_State)
      then
         if Expected = Poisoned_State then
            raise Poison_Error with "slab release was poisoned";
         else
            raise Layout_Error with "slab release state changed";
         end if;
      end if;
   end Release;

   procedure Release
     (Item    : in out View;
      Value   : Handles.Handle;
      Timeout : Wait_Timeout)
   is
      Slot : Interfaces.Unsigned_32;
      Expected : Interfaces.Unsigned_32 := Releasing_State;
      Generation : Interfaces.Unsigned_32;
   begin
      Acquire_Live (Item, Value, Releasing_State, Timeout, Slot);
      if not Policy.Generation_Can_Advance
        (Interfaces.Unsigned_32 (Value.Stamp))
      then
         if not Atomic.Compare_Exchange_U32
           (State_Address (Item, Slot), Expected, Poisoned_State)
         then
            if Expected = Poisoned_State then
               raise Poison_Error with "slab generation was retired";
            else
               raise Layout_Error with "slab retirement state changed";
            end if;
         end if;
         raise Poison_Error with
           "slab generation is exhausted; exclusive reinitialization required";
      end if;
      Generation := Policy.Next_Generation
        (Interfaces.Unsigned_32 (Value.Stamp));
      Bytes.Write_U32 (Generation_Address (Item, Slot), Generation);
      if not Atomic.Compare_Exchange_U32
        (State_Address (Item, Slot), Expected, Free_State)
      then
         if Expected = Poisoned_State then
            raise Poison_Error with "slab release was poisoned";
         else
            raise Layout_Error with "slab release state changed";
         end if;
      end if;
   end Release;

   function Payload_Address
     (Item : View; Slot : Interfaces.Unsigned_32) return System.Address is
   begin
      return Field_Address
        (Item, Slot, Item.Payload_Offset, Byte_Count (Item.Element_Value),
         Byte_Count (Item.Alignment_Value));
   end Payload_Address;

   procedure Check_Length (Item : View; Length : Natural) is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached slab view";
      elsif Byte_Count (Length) /= Byte_Count (Item.Element_Value) then
         raise Constraint_Error with "slab payload length does not match";
      end if;
   end Check_Length;

   procedure Read
     (Item  : View;
      Value : Handles.Handle;
      Data  : out Ada.Streams.Stream_Element_Array)
   is
      Slot     : Interfaces.Unsigned_32 := 0;
      Acquired : Boolean := False;
      Expected : Interfaces.Unsigned_32;
   begin
      Check_Length (Item, Data'Length);
      Acquire_Live (Item, Value, Accessing_State, Slot);
      Acquired := True;
      Bytes.Copy
        (Data'Address, Payload_Address (Item, Slot),
         Interfaces.C.size_t (Data'Length));
      Expected := Accessing_State;
      if not Atomic.Compare_Exchange_U32
        (State_Address (Item, Slot), Expected, Live_State)
      then
         if Expected = Poisoned_State then
            raise Poison_Error with "slab read was poisoned";
         else
            raise Layout_Error with "slab read state changed";
         end if;
      end if;
   exception
      when others =>
         if Acquired
           and then Atomic.Load_Acquire_U32 (State_Address (Item, Slot)) =
             Accessing_State
         then
            Expected := Accessing_State;
            if Atomic.Compare_Exchange_U32
              (State_Address (Item, Slot), Expected, Live_State)
            then
               null;
            end if;
         end if;
         raise;
   end Read;

   procedure Read
     (Item    : View;
      Value   : Handles.Handle;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout)
   is
      Slot     : Interfaces.Unsigned_32 := 0;
      Acquired : Boolean := False;
      Expected : Interfaces.Unsigned_32;
   begin
      Check_Length (Item, Data'Length);
      Acquire_Live (Item, Value, Accessing_State, Timeout, Slot);
      Acquired := True;
      Bytes.Copy
        (Data'Address, Payload_Address (Item, Slot),
         Interfaces.C.size_t (Data'Length));
      Expected := Accessing_State;
      if not Atomic.Compare_Exchange_U32
        (State_Address (Item, Slot), Expected, Live_State)
      then
         if Expected = Poisoned_State then
            raise Poison_Error with "slab read was poisoned";
         else
            raise Layout_Error with "slab read state changed";
         end if;
      end if;
   exception
      when others =>
         if Acquired
           and then Atomic.Load_Acquire_U32 (State_Address (Item, Slot)) =
             Accessing_State
         then
            Expected := Accessing_State;
            if Atomic.Compare_Exchange_U32
              (State_Address (Item, Slot), Expected, Live_State)
            then
               null;
            end if;
         end if;
         raise;
   end Read;

   procedure Write
     (Item  : in out View;
      Value : Handles.Handle;
      Data  : Ada.Streams.Stream_Element_Array)
   is
      Slot     : Interfaces.Unsigned_32 := 0;
      Target   : System.Address := System.Null_Address;
      Acquired : Boolean := False;
      Mutated  : Boolean := False;
      Expected : Interfaces.Unsigned_32;
   begin
      Check_Length (Item, Data'Length);
      Acquire_Live (Item, Value, Accessing_State, Slot);
      Acquired := True;
      Target := Payload_Address (Item, Slot);
      Mutated := True;
      Bytes.Copy
        (Target, Data'Address,
         Interfaces.C.size_t (Data'Length));
      Expected := Accessing_State;
      if not Atomic.Compare_Exchange_U32
        (State_Address (Item, Slot), Expected, Live_State)
      then
         if Expected = Poisoned_State then
            raise Poison_Error with "slab write was poisoned";
         else
            raise Layout_Error with "slab write state changed";
         end if;
      end if;
   exception
      when others =>
         if Acquired
           and then Atomic.Load_Acquire_U32 (State_Address (Item, Slot)) =
             Accessing_State
         then
            Expected := Accessing_State;
            if Atomic.Compare_Exchange_U32
              (State_Address (Item, Slot), Expected,
               (if Mutated then Poisoned_State else Live_State))
            then
               null;
            end if;
         end if;
         raise;
   end Write;

   procedure Write
     (Item    : in out View;
      Value   : Handles.Handle;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout)
   is
      Slot     : Interfaces.Unsigned_32 := 0;
      Target   : System.Address := System.Null_Address;
      Acquired : Boolean := False;
      Mutated  : Boolean := False;
      Expected : Interfaces.Unsigned_32;
   begin
      Check_Length (Item, Data'Length);
      Acquire_Live (Item, Value, Accessing_State, Timeout, Slot);
      Acquired := True;
      Target := Payload_Address (Item, Slot);
      Mutated := True;
      Bytes.Copy
        (Target, Data'Address, Interfaces.C.size_t (Data'Length));
      Expected := Accessing_State;
      if not Atomic.Compare_Exchange_U32
        (State_Address (Item, Slot), Expected, Live_State)
      then
         if Expected = Poisoned_State then
            raise Poison_Error with "slab write was poisoned";
         else
            raise Layout_Error with "slab write state changed";
         end if;
      end if;
   exception
      when others =>
         if Acquired
           and then Atomic.Load_Acquire_U32 (State_Address (Item, Slot)) =
             Accessing_State
         then
            Expected := Accessing_State;
            if Atomic.Compare_Exchange_U32
              (State_Address (Item, Slot), Expected,
               (if Mutated then Poisoned_State else Live_State))
            then
               null;
            end if;
         end if;
         raise;
   end Write;

   procedure Poison_Abandoned
     (Item : in out View;
      Slot : Handles.Slot_Index)
   is
      Index    : Interfaces.Unsigned_32;
      State    : Interfaces.Unsigned_32;
      Expected : Interfaces.Unsigned_32;
   begin
      Check_Slot (Item, Slot, Index);
      for Attempt in 1 .. Contention_Limit loop
         pragma Unreferenced (Attempt);
         State := Atomic.Load_Acquire_U32 (State_Address (Item, Index));
         if State = Poisoned_State then
            return;
         elsif State = Free_State or else State = Live_State then
            raise Program_Error with "slab slot is not abandoned";
         elsif State > Poisoned_State then
            raise Layout_Error with "slab slot state is corrupt";
         end if;
         Expected := State;
         if Atomic.Compare_Exchange_U32
           (State_Address (Item, Index), Expected, Poisoned_State)
         then
            return;
         end if;
      end loop;
      raise Busy_Error with "slab poison claim budget exhausted";
   end Poison_Abandoned;

   procedure Poison_Abandoned_At
     (Region            : Region_View;
      Location          : Region_Offset;
      Capacity          : Positive;
      Element_Size      : Positive;
      Element_Alignment : Positive;
      Slot              : Handles.Slot_Index)
   is
      Expected_Payload : Byte_Count;
      Expected_Stride  : Byte_Count;
      Expected_Extent  : Byte_Count;
      Core             : Layouts.Local_View;
      Header           : Layouts.Header_Values;
      Item             : View;
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
      then
         raise Layout_Error with "slab recovery geometry does not match";
      end if;
      Set_View
        (Item, Core, Header.Capacity, Header.Element_Size, Header.Alignment,
         Expected_Payload, Expected_Stride);
      Poison_Abandoned (Item, Slot);
      Detach (Item);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Poison_Abandoned_At;

   procedure Recover_Poisoned
     (Item : in out View;
      Slot : Handles.Slot_Index)
   is
      Index      : Interfaces.Unsigned_32;
      Expected   : Interfaces.Unsigned_32 := Poisoned_State;
      Generation : Interfaces.Unsigned_32;
   begin
      Check_Slot (Item, Slot, Index);
      if not Atomic.Compare_Exchange_U32
        (State_Address (Item, Index), Expected, Releasing_State)
      then
         if Expected > Poisoned_State then
            raise Layout_Error with "slab slot state is corrupt";
         else
            raise Program_Error with "slab slot is not poisoned";
         end if;
      end if;
      Generation := Bytes.Read_U32 (Generation_Address (Item, Index));
      if Generation = 0 then
         Expected := Releasing_State;
         if Atomic.Compare_Exchange_U32
           (State_Address (Item, Index), Expected, Poisoned_State)
         then
            null;
         end if;
         raise Layout_Error with "slab poisoned generation is zero";
      end if;
      if not Policy.Generation_Can_Advance (Generation) then
         Expected := Releasing_State;
         if Atomic.Compare_Exchange_U32
           (State_Address (Item, Index), Expected, Poisoned_State)
         then
            null;
         end if;
         raise Poison_Error with
           "slab generation is exhausted; exclusive reinitialization required";
      end if;
      Bytes.Write_U32
        (Generation_Address (Item, Index),
         Policy.Next_Generation (Generation));
      Expected := Releasing_State;
      if not Atomic.Compare_Exchange_U32
        (State_Address (Item, Index), Expected, Free_State)
      then
         if Expected = Poisoned_State then
            raise Poison_Error with "slab recovery was poisoned";
         else
            raise Layout_Error with "slab recovery state changed";
         end if;
      end if;
   end Recover_Poisoned;

   procedure Destroy (Item : in out View) is
   begin
      Layouts.Require_Ready (Item.Core);
      for Slot in Interfaces.Unsigned_32 range 1 .. Item.Capacity_Value loop
         if Atomic.Load_Acquire_U32 (State_Address (Item, Slot)) /= Free_State
         then
            raise Program_Error with
              "cannot destroy a slab with owned or poisoned slots";
         end if;
      end loop;
      Validate_Slots (Item);
      Layouts.Mark_Destroyed (Item.Core);
      Detach (Item);
   end Destroy;

end Flyology.Data_Structures.Slab_Pools;
