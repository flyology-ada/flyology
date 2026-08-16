with Flyology_Allocators.Atomics;
with Flyology_Allocators.Policy;
with Flyology_Allocators.Storage;
with Flyology_Allocators.Waits;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology_Allocators.Allocation_Algorithms.Slab_Span_Kernel is
   package Atomic renames Flyology_Allocators.Atomics;
   package Policy renames Flyology_Allocators.Policy;
   package Bytes renames Flyology_Allocators.Storage;
   package Waiting renames Flyology_Allocators.Waits;
   package Native renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Native.Integer_Address;
   use type Native.Storage_Offset;
   use type System.Address;

   Max_Classes : constant Byte_Count := 32;
   Null_Run : constant Interfaces.Unsigned_32 := Interfaces.Unsigned_32'Last;

   Run_Metadata_Offset : constant Byte_Count := Layouts.Header_Size;
   Run_Metadata_Reserved_Offset : constant Byte_Count :=
     Run_Metadata_Offset + 4;
   Head_Table_Offset : constant Byte_Count := Layouts.Header_Size + 8;
   Head_Entry_Size   : constant Byte_Count := 4;
   Descriptor_Table_Offset : constant Byte_Count :=
     Head_Table_Offset + Max_Classes * Head_Entry_Size;
   Descriptor_Size       : constant Byte_Count := 32;
   State_Offset          : constant Byte_Count := 0;
   Class_Offset          : constant Byte_Count := 4;
   Live_Offset           : constant Byte_Count := 8;
   Span_Offset           : constant Byte_Count := 12;
   Next_Offset           : constant Byte_Count := 16;
   Reserved_Offset       : constant Byte_Count := 20;
   Bitmap_Offset         : constant Byte_Count := 24;

   Guard_Offset   : constant Byte_Count := 44;
   Counter_Offset : constant Byte_Count := 56;

   Free_State       : constant Interfaces.Unsigned_32 := 0;
   Small_State      : constant Interfaces.Unsigned_32 := 1;
   Large_Head_State : constant Interfaces.Unsigned_32 := 2;
   Large_Tail_State : constant Interfaces.Unsigned_32 := 3;
   Unlocked          : constant Interfaces.Unsigned_32 := 0;
   Locked            : constant Interfaces.Unsigned_32 := 1;

   type Geometry_Values is record
      Usable            : Interfaces.Unsigned_32;
      Minimum           : Interfaces.Unsigned_32;
      Run_Size          : Interfaces.Unsigned_32;
      Runs              : Interfaces.Unsigned_32;
      Units             : Interfaces.Unsigned_32;
      Units_Per_Run     : Interfaces.Unsigned_32;
      Classes           : Interfaces.Unsigned_32;
      Generation_Offset : Byte_Count;
      Data_Start        : Byte_Count;
      Extent            : Byte_Count;
   end record;

   function Geometry
     (Usable_Capacity, Minimum_Block_Size, Run_Size : Positive)
      return Geometry_Values
   is
      Usable  : constant Byte_Count := Byte_Count (Usable_Capacity);
      Minimum : constant Byte_Count := Byte_Count (Minimum_Block_Size);
      Run     : constant Byte_Count := Byte_Count (Run_Size);
      Runs, Units, Per_Run, Classes : Byte_Count;
      Descriptor_End, Generation_Start, Generation_End, Data_Start : Byte_Count;
      Capacity : Byte_Count;
   begin
      if Minimum < Byte_Count (Minimum_Block_Limit)
        or else not Policy.Is_Power_Of_Two (Minimum)
        or else not Policy.Is_Power_Of_Two (Run)
        or else Run < Minimum * 2
        or else Run mod Minimum /= 0
        or else Run / Minimum > 64
        or else Usable < Run
        or else Usable mod Run /= 0
      then
         raise Constraint_Error with "invalid slab/span geometry";
      elsif Usable > Byte_Count (Interfaces.Unsigned_32'Last)
        or else Run > Byte_Count (Interfaces.Unsigned_32'Last)
      then
         raise Constraint_Error with "slab/span geometry exceeds stored widths";
      end if;

      Runs := Usable / Run;
      Units := Usable / Minimum;
      Per_Run := Run / Minimum;
      Classes := 0;
      Capacity := Minimum;
      while Capacity < Run loop
         Classes := Classes + 1;
         Capacity := Capacity * 2;
      end loop;
      if Runs > Byte_Count (Interfaces.Unsigned_32'Last)
        or else Units > Byte_Count (Interfaces.Unsigned_32'Last)
        or else Classes = 0
        or else Classes > Max_Classes
      then
         raise Constraint_Error with "slab/span table geometry is invalid";
      end if;

      Descriptor_End := Layouts.Checked_Add
        (Descriptor_Table_Offset,
         Layouts.Checked_Multiply (Runs, Descriptor_Size));
      Generation_Start := Layouts.Align_Up (Descriptor_End, 8);
      Generation_End := Layouts.Checked_Add
        (Generation_Start, Layouts.Checked_Multiply (Units, 8));
      Data_Start := Layouts.Align_Up (Generation_End, Minimum);
      return
        (Usable            => Interfaces.Unsigned_32 (Usable),
         Minimum           => Interfaces.Unsigned_32 (Minimum),
         Run_Size          => Interfaces.Unsigned_32 (Run),
         Runs              => Interfaces.Unsigned_32 (Runs),
         Units             => Interfaces.Unsigned_32 (Units),
         Units_Per_Run     => Interfaces.Unsigned_32 (Per_Run),
         Classes           => Interfaces.Unsigned_32 (Classes),
         Generation_Offset => Generation_Start,
         Data_Start        => Data_Start,
         Extent            => Layouts.Checked_Add (Data_Start, Usable));
   end Geometry;

   function Required_Storage
     (Configuration : Slab_Span_Kernel.Configuration) return Byte_Count is
     (Geometry
        (Configuration.Usable_Capacity,
         Configuration.Minimum_Block_Size,
         Configuration.Run_Size).Extent);

   function Make_Token
     (Epoch, Unit : Interfaces.Unsigned_32) return Interfaces.Unsigned_64 is
     (Interfaces.Shift_Left (Interfaces.Unsigned_64 (Epoch), 32)
      or Interfaces.Unsigned_64 (Unit));
   pragma Inline_Always (Make_Token);

   function Token_Epoch
     (Value : Allocation_Handle) return Interfaces.Unsigned_32 is
     (Interfaces.Unsigned_32 (Interfaces.Shift_Right (Value.Token, 32)));
   pragma Inline_Always (Token_Epoch);

   function Token_Unit
     (Value : Allocation_Handle) return Interfaces.Unsigned_32 is
     (Interfaces.Unsigned_32
        (Value.Token and Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)));
   pragma Inline_Always (Token_Unit);

   function Descriptor_Address
     (Item : View; Run : Interfaces.Unsigned_32; Relative, Extent, Alignment : Byte_Count)
      return System.Address
   is
      Offset : Byte_Count;
   begin
      if not Item.Core.Attached
        or else Item.Descriptor_Address = System.Null_Address
      then
         raise Region_Error with "detached slab/span view";
      elsif Run >= Item.Run_Count then
         raise Layout_Error with "slab/span run index is out of range";
      elsif Relative > Descriptor_Size
        or else Extent > Descriptor_Size - Relative
        or else Alignment = 0
        or else Relative mod Alignment /= 0
      then
         raise Layout_Error with "slab/span descriptor field is invalid";
      end if;
      Offset := Byte_Count (Run) * Descriptor_Size + Relative;
      if Offset > Byte_Count (Native.Storage_Offset'Last) then
         raise Region_Error with "slab/span descriptor offset is not native";
      end if;
      return Item.Descriptor_Address + Native.Storage_Offset (Offset);
   end Descriptor_Address;
   pragma Inline_Always (Descriptor_Address);

   function State_Address
     (Item : View; Run : Interfaces.Unsigned_32) return System.Address is
     (Descriptor_Address (Item, Run, State_Offset, 4, 4));
   pragma Inline_Always (State_Address);

   function U32_Field
     (Item : View; Run : Interfaces.Unsigned_32; Relative : Byte_Count)
      return System.Address is
     (Descriptor_Address (Item, Run, Relative, 4, 4));
   pragma Inline_Always (U32_Field);

   function Bitmap_Address
     (Item : View; Run : Interfaces.Unsigned_32) return System.Address is
     (Descriptor_Address (Item, Run, Bitmap_Offset, 8, 8));
   pragma Inline_Always (Bitmap_Address);

   function Class_Head_Address
     (Item : View; Class : Interfaces.Unsigned_32) return System.Address is
   begin
      if not Item.Core.Attached
        or else Item.Head_Address = System.Null_Address
      then
         raise Region_Error with "detached slab/span view";
      elsif Class >= Item.Class_Count then
         raise Layout_Error with "slab/span class is out of range";
      end if;
      return Item.Head_Address
        + Native.Storage_Offset (Byte_Count (Class) * Head_Entry_Size);
   end Class_Head_Address;
   pragma Inline_Always (Class_Head_Address);

   function Unit_Generation_Address
     (Item : View; Unit : Interfaces.Unsigned_32) return System.Address
   is
      Unit_Count : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Item.Run_Count) *
        Interfaces.Unsigned_64 (Item.Units_Per_Run);
      Offset : Byte_Count;
   begin
      if not Item.Core.Attached
        or else Item.Generation_Address = System.Null_Address
      then
         raise Region_Error with "detached slab/span view";
      elsif Interfaces.Unsigned_64 (Unit) >= Unit_Count then
         raise Layout_Error with "slab/span unit is out of range";
      end if;
      Offset := Byte_Count (Unit) * 8;
      return Item.Generation_Address + Native.Storage_Offset (Offset);
   end Unit_Generation_Address;
   pragma Inline_Always (Unit_Generation_Address);

   procedure Set_View
     (Item : out View; Core : Layouts.Local_View; Values : Geometry_Values;
      Instance_ID : Interfaces.Unsigned_64)
   is
      Descriptor_Bytes : constant Byte_Count :=
        Byte_Count (Values.Runs) * Descriptor_Size;
      Generation_Bytes : constant Byte_Count := Byte_Count (Values.Units) * 8;
      procedure Prove_Native_Range
        (Address : System.Address; Extent : Byte_Count)
      is
         Base : constant Native.Integer_Address := Native.To_Integer (Address);
      begin
         if Extent = 0
           or else Extent - 1 > Byte_Count (Native.Storage_Offset'Last)
           or else Extent - 1 >
             Byte_Count (Native.Integer_Address'Last - Base)
         then
            raise Region_Error with "slab/span metadata range is not native";
         end if;
      end Prove_Native_Range;
   begin
      Item.Core := Core;
      Item.Head_Address := Layouts.Address_At
        (Core, Head_Table_Offset, Max_Classes * Head_Entry_Size, 4);
      Item.Descriptor_Address := Layouts.Address_At
        (Core, Descriptor_Table_Offset, Descriptor_Bytes, 8);
      Item.Generation_Address := Layouts.Address_At
        (Core, Values.Generation_Offset, Generation_Bytes, 8);
      Prove_Native_Range
        (Item.Head_Address, Max_Classes * Head_Entry_Size);
      Prove_Native_Range (Item.Descriptor_Address, Descriptor_Bytes);
      Prove_Native_Range (Item.Generation_Address, Generation_Bytes);
      Item.Guard_Address := Layouts.Address_At (Core, Guard_Offset, 4, 4);
      Item.Counter_Address := Layouts.Address_At (Core, Counter_Offset, 8, 8);
      Item.Usable_Value := Values.Usable;
      Item.Minimum_Value := Values.Minimum;
      Item.Run_Value := Values.Run_Size;
      Item.Run_Count := Values.Runs;
      Item.Units_Per_Run := Values.Units_Per_Run;
      Item.Class_Count := Values.Classes;
      Item.Data_Offset := Values.Data_Start;
      Item.Instance_Value := Instance_ID;
   end Set_View;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Descriptor_Address := System.Null_Address;
      Item.Generation_Address := System.Null_Address;
      Item.Head_Address := System.Null_Address;
      Item.Guard_Address := System.Null_Address;
      Item.Counter_Address := System.Null_Address;
      Item.Usable_Value := 0;
      Item.Minimum_Value := 0;
      Item.Run_Value := 0;
      Item.Run_Count := 0;
      Item.Units_Per_Run := 0;
      Item.Class_Count := 0;
      Item.Data_Offset := 0;
      Item.Instance_Value := 0;
   end Detach;

   procedure Initialize_Tables (Item : View) is
      Unit_Count : constant Interfaces.Unsigned_32 :=
        Item.Run_Count * Item.Units_Per_Run;
   begin
      Bytes.Write_U32
        (Layouts.Address_At (Item.Core, Run_Metadata_Offset, 4, 4),
         Item.Run_Value);
      Bytes.Write_U32
        (Layouts.Address_At (Item.Core, Run_Metadata_Reserved_Offset, 4, 4), 0);
      for Class in Interfaces.Unsigned_32 range 0 .. Item.Class_Count - 1 loop
         Bytes.Write_U32 (Class_Head_Address (Item, Class), Null_Run);
      end loop;
      for Class in Interfaces.Unsigned_32 range Item.Class_Count ..
        Interfaces.Unsigned_32 (Max_Classes) - 1
      loop
         Bytes.Write_U32
           (Item.Head_Address + Native.Storage_Offset
              (Byte_Count (Class) * Head_Entry_Size), Null_Run);
      end loop;
      for Run in Interfaces.Unsigned_32 range 0 .. Item.Run_Count - 1 loop
         Bytes.Write_U32 (U32_Field (Item, Run, Class_Offset), 0);
         Bytes.Write_U32 (U32_Field (Item, Run, Live_Offset), 0);
         Bytes.Write_U32 (U32_Field (Item, Run, Span_Offset), 0);
         Bytes.Write_U32 (U32_Field (Item, Run, Next_Offset), Null_Run);
         Bytes.Write_U32 (U32_Field (Item, Run, Reserved_Offset), 0);
         Bytes.Write_U64 (Bitmap_Address (Item, Run), 0);
         Atomic.Store_Release_U32 (State_Address (Item, Run), Free_State);
      end loop;
      for Unit in Interfaces.Unsigned_32 range 0 .. Unit_Count - 1 loop
         Bytes.Write_U64 (Unit_Generation_Address (Item, Unit), 0);
      end loop;
   end Initialize_Tables;

   procedure Check_Instance (Instance_ID : Interfaces.Unsigned_64) is
   begin
      if Instance_ID = 0 then
         raise Constraint_Error with "arena instance identity is zero";
      end if;
   end Check_Instance;

   procedure Finish_Initialize
     (Item : out View; Core : Layouts.Local_View; Values : Geometry_Values;
      Instance_ID : Interfaces.Unsigned_64) is
   begin
      Set_View (Item, Core, Values, Instance_ID);
      Initialize_Tables (Item);
      Layouts.Publish (Item.Core);
   end Finish_Initialize;

   procedure Initialize
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Slab_Span_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64)
   is
      Values : constant Geometry_Values := Geometry
        (Configuration.Usable_Capacity,
         Configuration.Minimum_Block_Size,
         Configuration.Run_Size);
      Core : Layouts.Local_View;
   begin
      Check_Instance (Instance_ID);
      Detach (Item);
      Layouts.Begin_Initialize
        (Core, Region, Location, Values.Extent,
         (Capacity => Values.Usable,
          Element_Size => Values.Minimum,
          Alignment => Values.Minimum,
          Auxiliary => Unlocked,
          Word_1 => Instance_ID,
          Word_2 => 0),
         Byte_Count (Values.Minimum));
      Finish_Initialize (Item, Core, Values, Instance_ID);
   exception
      when others =>
         if Item.Core.Attached then Detach (Item); end if;
         raise;
   end Initialize;

   procedure Create_Or_Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Slab_Span_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64;
      Result        : out Open_Result)
   is
      Values : constant Geometry_Values := Geometry
        (Configuration.Usable_Capacity,
         Configuration.Minimum_Block_Size,
         Configuration.Run_Size);
      Core : Layouts.Local_View;
      Claim : Layouts.Initialization_Claim;
   begin
      Check_Instance (Instance_ID);
      Detach (Item);
      Layouts.Try_Begin_Initialize
        (Core, Claim, Region, Location, Values.Extent,
         (Capacity => Values.Usable,
          Element_Size => Values.Minimum,
          Alignment => Values.Minimum,
          Auxiliary => Unlocked,
          Word_1 => Instance_ID,
          Word_2 => 0),
         Byte_Count (Values.Minimum));
      case Claim is
         when Layouts.Claimed_Virgin =>
            Finish_Initialize (Item, Core, Values, Instance_ID);
            Result := Initialized_New;
         when Layouts.Existing_Ready =>
            Attach (Item, Region, Location, Configuration, Instance_ID);
            Result := Attached_Existing;
         when Layouts.Claim_In_Progress =>
            Result := Initialization_In_Progress;
      end case;
   exception
      when others =>
         if Item.Core.Attached then Detach (Item); end if;
         raise;
   end Create_Or_Attach;

   function Class_Capacity
     (Item : View; Class : Interfaces.Unsigned_32) return Byte_Count
   is
      Result : Byte_Count := Byte_Count (Item.Minimum_Value);
   begin
      if Class >= Item.Class_Count then
         raise Layout_Error with "slab/span class is corrupt";
      end if;
      for Ignored in Interfaces.Unsigned_32 range 1 .. Class loop
         pragma Unreferenced (Ignored);
         Result := Result * 2;
      end loop;
      return Result;
   end Class_Capacity;
   pragma Inline_Always (Class_Capacity);

   function Slot_Mask (Slots : Interfaces.Unsigned_32)
      return Interfaces.Unsigned_64 is
   begin
      if Slots = 0 or else Slots > 64 then
         raise Layout_Error with "slab/span slot count is corrupt";
      elsif Slots = 64 then
         return Interfaces.Unsigned_64'Last;
      else
         return Interfaces.Shift_Left (Interfaces.Unsigned_64 (1),
                                       Natural (Slots)) - 1;
      end if;
   end Slot_Mask;
   pragma Inline_Always (Slot_Mask);

   function Population (Value : Interfaces.Unsigned_64)
      return Interfaces.Unsigned_32
   is
      Rest : Interfaces.Unsigned_64 := Value;
      Count : Interfaces.Unsigned_32 := 0;
   begin
      while Rest /= 0 loop
         Rest := Rest and (Rest - 1);
         Count := Count + 1;
      end loop;
      return Count;
   end Population;

   procedure Acquire (Item : View);
   procedure Release_Guard (Item : View);

   procedure Validate_Tables (Item : View) is
      Counter : constant Interfaces.Unsigned_64 :=
        Bytes.Read_U64 (Item.Counter_Address);
      Expected_Head : Interfaces.Unsigned_32 := Null_Run;
      Unit_Count : constant Interfaces.Unsigned_32 :=
        Item.Run_Count * Item.Units_Per_Run;
   begin
      for Class in Interfaces.Unsigned_32 range Item.Class_Count ..
        Interfaces.Unsigned_32 (Max_Classes) - 1
      loop
         if Bytes.Read_U32
           (Item.Head_Address + Native.Storage_Offset
              (Byte_Count (Class) * Head_Entry_Size)) /= Null_Run
         then
            raise Layout_Error with "unused slab class head is corrupt";
         end if;
      end loop;
      for Unit in Interfaces.Unsigned_32 range 0 .. Unit_Count - 1 loop
         if Bytes.Read_U64 (Unit_Generation_Address (Item, Unit)) > Counter then
            raise Layout_Error with "slab/span generation table is corrupt";
         end if;
      end loop;
      for Run in Interfaces.Unsigned_32 range 0 .. Item.Run_Count - 1 loop
         declare
            State : constant Interfaces.Unsigned_32 :=
              Atomic.Load_Acquire_U32 (State_Address (Item, Run));
            Class : constant Interfaces.Unsigned_32 :=
              Bytes.Read_U32 (U32_Field (Item, Run, Class_Offset));
            Live : constant Interfaces.Unsigned_32 :=
              Bytes.Read_U32 (U32_Field (Item, Run, Live_Offset));
            Span : constant Interfaces.Unsigned_32 :=
              Bytes.Read_U32 (U32_Field (Item, Run, Span_Offset));
            Next : constant Interfaces.Unsigned_32 :=
              Bytes.Read_U32 (U32_Field (Item, Run, Next_Offset));
            Reserved : constant Interfaces.Unsigned_32 :=
              Bytes.Read_U32 (U32_Field (Item, Run, Reserved_Offset));
            Bitmap : constant Interfaces.Unsigned_64 :=
              Bytes.Read_U64 (Bitmap_Address (Item, Run));
         begin
            if Reserved /= 0 then
               raise Layout_Error with "slab/span reserved field is corrupt";
            end if;
            case State is
               when Free_State =>
                  if Class /= 0 or else Live /= 0 or else Span /= 0
                    or else Next /= Null_Run or else Bitmap /= 0
                    or else Expected_Head /= Null_Run
                  then
                     raise Layout_Error with "free slab/span run is corrupt";
                  end if;
               when Small_State =>
                  if Expected_Head /= Null_Run or else Class >= Item.Class_Count
                    or else Span /= 0
                  then
                     raise Layout_Error with "small slab/span run is corrupt";
                  end if;
                  declare
                     Capacity : constant Byte_Count := Class_Capacity (Item, Class);
                     Slots : constant Interfaces.Unsigned_32 :=
                       Interfaces.Unsigned_32 (Byte_Count (Item.Run_Value) / Capacity);
                     Mask : constant Interfaces.Unsigned_64 := Slot_Mask (Slots);
                  begin
                     if (Bitmap and not Mask) /= 0
                       or else Live /= Population (Bitmap)
                       or else Live > Slots
                       or else (Next /= Null_Run and then Next >= Item.Run_Count)
                     then
                        raise Layout_Error with "small slab bitmap is corrupt";
                     end if;
                     for Slot in Interfaces.Unsigned_32 range 0 .. Slots - 1 loop
                        if (Bitmap and Interfaces.Shift_Left
                              (Interfaces.Unsigned_64 (1), Natural (Slot))) /= 0
                        then
                           declare
                              Units_Per_Slot : constant Interfaces.Unsigned_32 :=
                                Interfaces.Unsigned_32
                                  (Capacity / Byte_Count (Item.Minimum_Value));
                              Unit : constant Interfaces.Unsigned_32 :=
                                Run * Item.Units_Per_Run + Slot * Units_Per_Slot;
                              Generation : constant Interfaces.Unsigned_64 :=
                                Bytes.Read_U64 (Unit_Generation_Address (Item, Unit));
                           begin
                              if Generation = 0 or else Generation > Counter then
                                 raise Layout_Error with
                                   "small slab generation is corrupt";
                              end if;
                           end;
                        end if;
                     end loop;
                  end;
               when Large_Head_State =>
                  if Expected_Head /= Null_Run or else Class /= 0 or else Live /= 1
                    or else Span = 0 or else Span > Item.Run_Count - Run
                    or else Next /= Null_Run or else Bitmap /= 0
                  then
                     raise Layout_Error with "large span head is corrupt";
                  end if;
                  declare
                     Unit : constant Interfaces.Unsigned_32 := Run * Item.Units_Per_Run;
                     Generation : constant Interfaces.Unsigned_64 :=
                       Bytes.Read_U64 (Unit_Generation_Address (Item, Unit));
                  begin
                     if Generation = 0 or else Generation > Counter then
                        raise Layout_Error with "large span generation is corrupt";
                     end if;
                  end;
                  if Span > 1 then Expected_Head := Run; end if;
               when Large_Tail_State =>
                  if Expected_Head = Null_Run or else Class /= 0 or else Live /= 0
                    or else Span /= Expected_Head or else Next /= Null_Run
                    or else Bitmap /= 0
                  then
                     raise Layout_Error with "large span tail is corrupt";
                  end if;
                  declare
                     Head_Span : constant Interfaces.Unsigned_32 := Bytes.Read_U32
                       (U32_Field (Item, Expected_Head, Span_Offset));
                  begin
                     if Run = Expected_Head + Head_Span - 1 then
                        Expected_Head := Null_Run;
                     end if;
                  end;
               when others =>
                  raise Layout_Error with "slab/span run state is corrupt";
            end case;
         end;
      end loop;
      if Expected_Head /= Null_Run then
         raise Layout_Error with "large span is truncated";
      end if;

      for Class in Interfaces.Unsigned_32 range 0 .. Item.Class_Count - 1 loop
         declare
            Cursor : Interfaces.Unsigned_32 :=
              Bytes.Read_U32 (Class_Head_Address (Item, Class));
            Steps : Interfaces.Unsigned_32 := 0;
         begin
            while Cursor /= Null_Run loop
               if Cursor >= Item.Run_Count or else Steps >= Item.Run_Count
                 or else Atomic.Load_Acquire_U32
                   (State_Address (Item, Cursor)) /= Small_State
                 or else Bytes.Read_U32
                   (U32_Field (Item, Cursor, Class_Offset)) /= Class
               then
                  raise Layout_Error with "slab class list is corrupt";
               end if;
               declare
                  Capacity : constant Byte_Count := Class_Capacity (Item, Class);
                  Slots : constant Interfaces.Unsigned_32 :=
                    Interfaces.Unsigned_32 (Byte_Count (Item.Run_Value) / Capacity);
                  Live : constant Interfaces.Unsigned_32 := Bytes.Read_U32
                    (U32_Field (Item, Cursor, Live_Offset));
               begin
                  if Live >= Slots then
                     raise Layout_Error with "full slab is class-indexed";
                  end if;
               end;
               Cursor := Bytes.Read_U32 (U32_Field (Item, Cursor, Next_Offset));
               Steps := Steps + 1;
            end loop;
         end;
      end loop;

      for Run in Interfaces.Unsigned_32 range 0 .. Item.Run_Count - 1 loop
         if Atomic.Load_Acquire_U32 (State_Address (Item, Run)) = Small_State then
            declare
               Class : constant Interfaces.Unsigned_32 := Bytes.Read_U32
                 (U32_Field (Item, Run, Class_Offset));
               Capacity : constant Byte_Count := Class_Capacity (Item, Class);
               Slots : constant Interfaces.Unsigned_32 :=
                 Interfaces.Unsigned_32 (Byte_Count (Item.Run_Value) / Capacity);
               Live : constant Interfaces.Unsigned_32 := Bytes.Read_U32
                 (U32_Field (Item, Run, Live_Offset));
               Cursor : Interfaces.Unsigned_32 :=
                 Bytes.Read_U32 (Class_Head_Address (Item, Class));
               Occurrences : Natural := 0;
               Steps : Interfaces.Unsigned_32 := 0;
            begin
               while Cursor /= Null_Run loop
                  if Cursor = Run then Occurrences := Occurrences + 1; end if;
                  Cursor := Bytes.Read_U32 (U32_Field (Item, Cursor, Next_Offset));
                  Steps := Steps + 1;
                  exit when Steps > Item.Run_Count;
               end loop;
               if (Live < Slots and then Occurrences /= 1)
                 or else (Live = Slots and then Occurrences /= 0)
               then
                  raise Layout_Error with "slab class membership is corrupt";
               end if;
            end;
         end if;
      end loop;
   end Validate_Tables;

   procedure Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Slab_Span_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64)
   is
      Values : constant Geometry_Values := Geometry
        (Configuration.Usable_Capacity,
         Configuration.Minimum_Block_Size,
         Configuration.Run_Size);
      Core : Layouts.Local_View;
      Header : Layouts.Header_Values;
   begin
      Check_Instance (Instance_ID);
      Detach (Item);
      Layouts.Attach (Core, Header, Region, Location, Byte_Count (Values.Minimum));
      if Header.Capacity /= Values.Usable
        or else Header.Element_Size /= Values.Minimum
        or else Header.Alignment /= Values.Minimum
        or else Header.Word_1 /= Instance_ID
        or else Core.Extent /= Values.Extent
      then
         raise Layout_Error with "slab/span creation parameters do not match";
      end if;
      Set_View (Item, Core, Values, Instance_ID);
      if Bytes.Read_U32
        (Layouts.Address_At (Item.Core, Run_Metadata_Offset, 4, 4)) /=
          Values.Run_Size
        or else Bytes.Read_U32
          (Layouts.Address_At
             (Item.Core, Run_Metadata_Reserved_Offset, 4, 4)) /= 0
      then
         raise Layout_Error with "slab/span run geometry is corrupt";
      end if;
      Acquire (Item);
      begin Validate_Tables (Item);
      exception when others => Release_Guard (Item); raise; end;
      Release_Guard (Item);
   exception
      when others =>
         if Item.Core.Attached then Detach (Item); end if;
         raise;
   end Attach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   function Current_Metadata (Item : View) return Metadata is
   begin
      Layouts.Require_Ready (Item.Core);
      return
        (Usable_Capacity => Item.Usable_Value,
         Minimum_Block_Size => Item.Minimum_Value,
         Instance_ID => Item.Instance_Value,
         Incarnation => Item.Core.Epoch_Value,
         Extent => Item.Core.Extent);
   end Current_Metadata;

   function Is_Poisoned (Item : View) return Boolean is
     (Layouts.Is_Poisoned (Item.Core));

   procedure Poison (Region : Region_View; Location : Region_Offset) is
   begin
      Layouts.Poison_At (Region, Location, 8);
   end Poison;

   procedure Acquire (Item : View) is
      Expected : Interfaces.Unsigned_32 := Unlocked;
   begin
      if not Item.Core.Attached or else Item.Guard_Address = System.Null_Address then
         raise Region_Error with "detached slab/span view";
      elsif not Atomic.Compare_Exchange_U32
        (Item.Guard_Address, Expected, Locked)
      then
         Layouts.Require_Ready (Item.Core);
         if Expected = Locked then
            raise Busy_Error with "slab/span metadata is busy";
         else
            raise Layout_Error with "slab/span metadata guard is corrupt";
         end if;
      end if;
      begin Layouts.Require_Ready (Item.Core);
      exception when others =>
         Atomic.Store_Release_U32 (Item.Guard_Address, Unlocked); raise;
      end;
   end Acquire;
   pragma Inline_Always (Acquire);

   procedure Acquire (Item : View; Timeout : Wait_Timeout) is
      Wait : Waiting.Context := Waiting.Start (Timeout);
      Expected : Interfaces.Unsigned_32;
   begin
      if not Item.Core.Attached or else Item.Guard_Address = System.Null_Address then
         raise Region_Error with "detached slab/span view";
      end if;
      Outer : loop
         Expected := Unlocked;
         exit Outer when Atomic.Compare_Exchange_U32
           (Item.Guard_Address, Expected, Locked);
         Inner : loop
            Layouts.Require_Ready (Item.Core);
            if Expected /= Locked then
               raise Layout_Error with "slab/span metadata guard is corrupt";
            end if;
            Waiting.Retry (Wait);
            Expected := Atomic.Load_Acquire_U32 (Item.Guard_Address);
            exit Inner when Expected = Unlocked;
         end loop Inner;
      end loop Outer;
      begin Layouts.Require_Ready (Item.Core);
      exception when others =>
         Atomic.Store_Release_U32 (Item.Guard_Address, Unlocked); raise;
      end;
   end Acquire;

   procedure Release_Guard (Item : View) is
   begin
      Atomic.Store_Release_U32 (Item.Guard_Address, Unlocked);
   end Release_Guard;
   pragma Inline_Always (Release_Guard);

   procedure Finish_Failure (Item : View; Mutated : Boolean) is
   begin
      if Mutated then
         begin Layouts.Poison (Item.Core);
         exception when others => Release_Guard (Item); raise; end;
      end if;
      Release_Guard (Item);
   end Finish_Failure;

   procedure Add_To_Class
     (Item : View; Run, Class : Interfaces.Unsigned_32) is
      Head : constant Interfaces.Unsigned_32 :=
        Bytes.Read_U32 (Class_Head_Address (Item, Class));
   begin
      Bytes.Write_U32 (U32_Field (Item, Run, Next_Offset), Head);
      Bytes.Write_U32 (Class_Head_Address (Item, Class), Run);
   end Add_To_Class;
   pragma Inline_Always (Add_To_Class);

   procedure Remove_Class_Head
     (Item : View; Run, Class : Interfaces.Unsigned_32) is
      Head : constant Interfaces.Unsigned_32 :=
        Bytes.Read_U32 (Class_Head_Address (Item, Class));
      Next : Interfaces.Unsigned_32;
   begin
      if Head /= Run then
         raise Layout_Error with "slab class head is corrupt";
      end if;
      Next := Bytes.Read_U32 (U32_Field (Item, Run, Next_Offset));
      Bytes.Write_U32 (Class_Head_Address (Item, Class), Next);
      Bytes.Write_U32 (U32_Field (Item, Run, Next_Offset), Null_Run);
   end Remove_Class_Head;
   pragma Inline_Always (Remove_Class_Head);

   procedure Clear_Descriptor (Item : View; Run : Interfaces.Unsigned_32) is
   begin
      Bytes.Write_U32 (U32_Field (Item, Run, Class_Offset), 0);
      Bytes.Write_U32 (U32_Field (Item, Run, Live_Offset), 0);
      Bytes.Write_U32 (U32_Field (Item, Run, Span_Offset), 0);
      Bytes.Write_U32 (U32_Field (Item, Run, Next_Offset), Null_Run);
      Bytes.Write_U32 (U32_Field (Item, Run, Reserved_Offset), 0);
      Bytes.Write_U64 (Bitmap_Address (Item, Run), 0);
      Atomic.Store_Release_U32 (State_Address (Item, Run), Free_State);
   end Clear_Descriptor;

   procedure Rebuild_Class_Lists (Item : View) is
   begin
      for Class in Interfaces.Unsigned_32 range 0 .. Item.Class_Count - 1 loop
         Bytes.Write_U32 (Class_Head_Address (Item, Class), Null_Run);
      end loop;
      for Run in reverse Interfaces.Unsigned_32 range 0 .. Item.Run_Count - 1 loop
         if Atomic.Load_Acquire_U32 (State_Address (Item, Run)) = Small_State then
            declare
               Class : constant Interfaces.Unsigned_32 := Bytes.Read_U32
                 (U32_Field (Item, Run, Class_Offset));
               Slots : constant Interfaces.Unsigned_32 := Interfaces.Unsigned_32
                 (Byte_Count (Item.Run_Value) / Class_Capacity (Item, Class));
               Live : constant Interfaces.Unsigned_32 := Bytes.Read_U32
                 (U32_Field (Item, Run, Live_Offset));
            begin
               Bytes.Write_U32 (U32_Field (Item, Run, Next_Offset), Null_Run);
               if Live < Slots then Add_To_Class (Item, Run, Class); end if;
            end;
         end if;
      end loop;
   end Rebuild_Class_Lists;

   function Reclaim_Empty_Slabs (Item : View) return Boolean is
      Changed : Boolean := False;
   begin
      for Run in Interfaces.Unsigned_32 range 0 .. Item.Run_Count - 1 loop
         if Atomic.Load_Acquire_U32 (State_Address (Item, Run)) = Small_State
           and then Bytes.Read_U32 (U32_Field (Item, Run, Live_Offset)) = 0
         then
            Clear_Descriptor (Item, Run);
            Changed := True;
         end if;
      end loop;
      if Changed then Rebuild_Class_Lists (Item); end if;
      return Changed;
   end Reclaim_Empty_Slabs;

   function Claim_Free_Run (Item : View) return Interfaces.Unsigned_32 is
   begin
      for Run in Interfaces.Unsigned_32 range 0 .. Item.Run_Count - 1 loop
         if Atomic.Load_Acquire_U32 (State_Address (Item, Run)) = Free_State then
            return Run;
         end if;
      end loop;
      return Null_Run;
   end Claim_Free_Run;

   function Next_Generation (Item : View) return Interfaces.Unsigned_64 is
      Counter : Interfaces.Unsigned_64 := Bytes.Read_U64 (Item.Counter_Address);
   begin
      if Counter = Interfaces.Unsigned_64'Last then
         raise Layout_Error with "slab/span allocation generation exhausted";
      end if;
      Counter := Counter + 1;
      Bytes.Write_U64 (Item.Counter_Address, Counter);
      return Counter;
   end Next_Generation;
   pragma Inline_Always (Next_Generation);

   function First_Clear_Bit
     (Bitmap, Mask : Interfaces.Unsigned_64) return Interfaces.Unsigned_32
   is
      Free : Interfaces.Unsigned_64 := (not Bitmap) and Mask;
      Index : Interfaces.Unsigned_32 := 0;
   begin
      if Free = 0 then raise Layout_Error with "slab has no free slot"; end if;
      while (Free and 1) = 0 loop
         Free := Interfaces.Shift_Right (Free, 1);
         Index := Index + 1;
      end loop;
      return Index;
   end First_Clear_Bit;
   pragma Inline_Always (First_Clear_Bit);

   function Allocate_Small
     (Item : View; Requested : Byte_Count; Value : out Allocation_Handle)
      return Boolean
   is
      Capacity : Byte_Count := Byte_Count (Item.Minimum_Value);
      Class : Interfaces.Unsigned_32 := 0;
      Run, Slot, Slots, Units_Per_Slot, Unit : Interfaces.Unsigned_32;
      Bitmap, Mask, Bit : Interfaces.Unsigned_64;
      Live : Interfaces.Unsigned_32;
      Generation : Interfaces.Unsigned_64;
   begin
      while Capacity < Requested loop
         Capacity := Capacity * 2;
         Class := Class + 1;
      end loop;
      if Capacity >= Byte_Count (Item.Run_Value) then return False; end if;
      Run := Bytes.Read_U32 (Class_Head_Address (Item, Class));
      if Run = Null_Run then
         Run := Claim_Free_Run (Item);
         if Run = Null_Run then return False; end if;
         Bytes.Write_U32 (U32_Field (Item, Run, Class_Offset), Class);
         Bytes.Write_U32 (U32_Field (Item, Run, Live_Offset), 0);
         Bytes.Write_U32 (U32_Field (Item, Run, Span_Offset), 0);
         Bytes.Write_U32 (U32_Field (Item, Run, Next_Offset), Null_Run);
         Bytes.Write_U32 (U32_Field (Item, Run, Reserved_Offset), 0);
         Bytes.Write_U64 (Bitmap_Address (Item, Run), 0);
         Atomic.Store_Release_U32 (State_Address (Item, Run), Small_State);
         Add_To_Class (Item, Run, Class);
      elsif Run >= Item.Run_Count
        or else Atomic.Load_Acquire_U32 (State_Address (Item, Run)) /= Small_State
        or else Bytes.Read_U32 (U32_Field (Item, Run, Class_Offset)) /= Class
      then
         raise Layout_Error with "slab class head is corrupt";
      end if;
      Slots := Interfaces.Unsigned_32 (Byte_Count (Item.Run_Value) / Capacity);
      Mask := Slot_Mask (Slots);
      Bitmap := Bytes.Read_U64 (Bitmap_Address (Item, Run));
      Slot := First_Clear_Bit (Bitmap, Mask);
      Bit := Interfaces.Shift_Left (Interfaces.Unsigned_64 (1), Natural (Slot));
      Live := Bytes.Read_U32 (U32_Field (Item, Run, Live_Offset));
      if Live >= Slots then raise Layout_Error with "indexed slab is full"; end if;
      Units_Per_Slot := Interfaces.Unsigned_32
        (Capacity / Byte_Count (Item.Minimum_Value));
      Unit := Run * Item.Units_Per_Run + Slot * Units_Per_Slot;
      Generation := Next_Generation (Item);
      Bytes.Write_U64 (Unit_Generation_Address (Item, Unit), Generation);
      Bytes.Write_U64 (Bitmap_Address (Item, Run), Bitmap or Bit);
      Bytes.Write_U32 (U32_Field (Item, Run, Live_Offset), Live + 1);
      if Live + 1 = Slots then Remove_Class_Head (Item, Run, Class); end if;
      Value :=
        (Token => Make_Token (Item.Core.Epoch_Value, Unit),
         Generation => Generation);
      return True;
   end Allocate_Small;

   function Find_Free_Span
     (Item : View; Needed : Interfaces.Unsigned_32) return Interfaces.Unsigned_32
   is
      Start : Interfaces.Unsigned_32 := 0;
      Length : Interfaces.Unsigned_32 := 0;
   begin
      if Needed = 0 or else Needed > Item.Run_Count then return Null_Run; end if;
      for Run in Interfaces.Unsigned_32 range 0 .. Item.Run_Count - 1 loop
         if Atomic.Load_Acquire_U32 (State_Address (Item, Run)) = Free_State then
            if Length = 0 then Start := Run; end if;
            Length := Length + 1;
            if Length = Needed then return Start; end if;
         else
            Length := 0;
         end if;
      end loop;
      return Null_Run;
   end Find_Free_Span;

   function Allocate_Large
     (Item : View; Requested : Byte_Count; Value : out Allocation_Handle)
      return Boolean
   is
      Needed : constant Interfaces.Unsigned_32 := Interfaces.Unsigned_32
        ((Requested + Byte_Count (Item.Run_Value) - 1) /
         Byte_Count (Item.Run_Value));
      Start : constant Interfaces.Unsigned_32 := Find_Free_Span (Item, Needed);
      Unit : Interfaces.Unsigned_32;
      Generation : Interfaces.Unsigned_64;
   begin
      if Start = Null_Run then return False; end if;
      for Run in Interfaces.Unsigned_32 range Start + 1 .. Start + Needed - 1 loop
         Bytes.Write_U32 (U32_Field (Item, Run, Class_Offset), 0);
         Bytes.Write_U32 (U32_Field (Item, Run, Live_Offset), 0);
         Bytes.Write_U32 (U32_Field (Item, Run, Span_Offset), Start);
         Bytes.Write_U32 (U32_Field (Item, Run, Next_Offset), Null_Run);
         Bytes.Write_U32 (U32_Field (Item, Run, Reserved_Offset), 0);
         Bytes.Write_U64 (Bitmap_Address (Item, Run), 0);
         Atomic.Store_Release_U32 (State_Address (Item, Run), Large_Tail_State);
      end loop;
      Bytes.Write_U32 (U32_Field (Item, Start, Class_Offset), 0);
      Bytes.Write_U32 (U32_Field (Item, Start, Live_Offset), 1);
      Bytes.Write_U32 (U32_Field (Item, Start, Span_Offset), Needed);
      Bytes.Write_U32 (U32_Field (Item, Start, Next_Offset), Null_Run);
      Bytes.Write_U32 (U32_Field (Item, Start, Reserved_Offset), 0);
      Bytes.Write_U64 (Bitmap_Address (Item, Start), 0);
      Unit := Start * Item.Units_Per_Run;
      Generation := Next_Generation (Item);
      Bytes.Write_U64 (Unit_Generation_Address (Item, Unit), Generation);
      Atomic.Store_Release_U32 (State_Address (Item, Start), Large_Head_State);
      Value :=
        (Token => Make_Token (Item.Core.Epoch_Value, Unit),
         Generation => Generation);
      return True;
   end Allocate_Large;

   function Allocate_Unlocked
     (Item : View; Requested : Byte_Count; Value : out Allocation_Handle)
      return Boolean is
   begin
      Value := Null_Allocation;
      if Requested > Byte_Count (Item.Usable_Value) then return False; end if;
      if Requested <= Byte_Count (Item.Run_Value) / 2
        and then Allocate_Small (Item, Requested, Value)
      then
         return True;
      elsif Requested > Byte_Count (Item.Run_Value) / 2
        and then Allocate_Large (Item, Requested, Value)
      then
         return True;
      end if;
      declare
         Changed : constant Boolean := Reclaim_Empty_Slabs (Item);
      begin
         if not Changed then return False; end if;
      end;
      if Requested <= Byte_Count (Item.Run_Value) / 2 then
         return Allocate_Small (Item, Requested, Value);
      else
         return Allocate_Large (Item, Requested, Value);
      end if;
   end Allocate_Unlocked;

   procedure Allocate_With_Guard
     (Item : in out View; Requested_Size : Positive;
      Value : out Allocation_Handle; Result : out Allocation_Result)
   is
      Mutated : Boolean := Requested_Size <= Natural (Item.Usable_Value);
   begin
      begin
         if Allocate_Unlocked (Item, Byte_Count (Requested_Size), Value) then
            Result := Allocated;
         else
            Result := Exhausted;
         end if;
      exception when others => Finish_Failure (Item, Mutated); raise; end;
      Release_Guard (Item);
   end Allocate_With_Guard;

   procedure Try_Allocate
     (Item : in out View; Requested_Size : Positive;
      Value : out Allocation_Handle; Result : out Allocation_Result) is
   begin
      Value := Null_Allocation;
      begin Acquire (Item);
      exception when Busy_Error => Result := Allocation_Contended; return; end;
      Allocate_With_Guard (Item, Requested_Size, Value, Result);
   end Try_Allocate;

   procedure Try_Allocate
     (Item : in out View; Requested_Size : Positive; Timeout : Wait_Timeout;
      Value : out Allocation_Handle; Result : out Allocation_Result) is
   begin
      Value := Null_Allocation;
      Acquire (Item, Timeout);
      Allocate_With_Guard (Item, Requested_Size, Value, Result);
   end Try_Allocate;

   type Block_Description is record
      Capacity : Byte_Count;
      Offset   : Byte_Count;
      Run      : Interfaces.Unsigned_32;
      State    : Interfaces.Unsigned_32;
      Slot     : Interfaces.Unsigned_32;
      Class    : Interfaces.Unsigned_32;
      Span     : Interfaces.Unsigned_32;
   end record;

   function Validate_Handle
     (Item : View; Value : Allocation_Handle) return Block_Description
   is
      Unit : constant Interfaces.Unsigned_32 := Token_Unit (Value);
      Unit_Count : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Item.Run_Count) *
        Interfaces.Unsigned_64 (Item.Units_Per_Run);
      Run, In_Run : Interfaces.Unsigned_32;
      State, Class, Slot, Span : Interfaces.Unsigned_32;
      Capacity : Byte_Count;
      Generation : Interfaces.Unsigned_64;
   begin
      Layouts.Require_Ready (Item.Core);
      if Value = Null_Allocation or else Token_Epoch (Value) = 0
        or else Value.Generation = 0
        or else Token_Epoch (Value) /= Item.Core.Epoch_Value
        or else Interfaces.Unsigned_64 (Unit) >= Unit_Count
      then
         raise Handle_Error with "slab/span handle is invalid or stale";
      end if;
      Run := Unit / Item.Units_Per_Run;
      In_Run := Unit mod Item.Units_Per_Run;
      State := Atomic.Load_Acquire_U32 (State_Address (Item, Run));
      Generation := Bytes.Read_U64 (Unit_Generation_Address (Item, Unit));
      if Generation /= Value.Generation then
         raise Handle_Error with "slab/span handle is reclaimed or stale";
      end if;
      if State = Small_State then
         Class := Bytes.Read_U32 (U32_Field (Item, Run, Class_Offset));
         Capacity := Class_Capacity (Item, Class);
         declare
            Units_Per_Slot : constant Interfaces.Unsigned_32 :=
              Interfaces.Unsigned_32 (Capacity / Byte_Count (Item.Minimum_Value));
            Slots : constant Interfaces.Unsigned_32 := Interfaces.Unsigned_32
              (Byte_Count (Item.Run_Value) / Capacity);
            Bitmap : constant Interfaces.Unsigned_64 :=
              Bytes.Read_U64 (Bitmap_Address (Item, Run));
         begin
            if In_Run mod Units_Per_Slot /= 0 then
               raise Handle_Error with "slab handle is not at a slot boundary";
            end if;
            Slot := In_Run / Units_Per_Slot;
            if Slot >= Slots
              or else (Bitmap and Interfaces.Shift_Left
                (Interfaces.Unsigned_64 (1), Natural (Slot))) = 0
            then
               raise Handle_Error with "slab handle is reclaimed or stale";
            end if;
         end;
         Span := 0;
      elsif State = Large_Head_State then
         if In_Run /= 0 then
            raise Handle_Error with "span handle is not at its head";
         end if;
         Span := Bytes.Read_U32 (U32_Field (Item, Run, Span_Offset));
         if Span = 0 or else Span > Item.Run_Count - Run then
            raise Layout_Error with "large span is corrupt";
         end if;
         Capacity := Byte_Count (Span) * Byte_Count (Item.Run_Value);
         Class := 0;
         Slot := 0;
      else
         raise Handle_Error with "slab/span handle is reclaimed or stale";
      end if;
      return
        (Capacity => Capacity,
         Offset => Byte_Count (Unit) * Byte_Count (Item.Minimum_Value),
         Run => Run, State => State, Slot => Slot, Class => Class, Span => Span);
   end Validate_Handle;

   procedure Release_Unlocked
     (Item : View; Value : Allocation_Handle; Description : Block_Description)
   is
      pragma Unreferenced (Value);
   begin
      if Description.State = Small_State then
         declare
            Slots : constant Interfaces.Unsigned_32 := Interfaces.Unsigned_32
              (Byte_Count (Item.Run_Value) / Description.Capacity);
            Live : constant Interfaces.Unsigned_32 := Bytes.Read_U32
              (U32_Field (Item, Description.Run, Live_Offset));
            Bitmap : constant Interfaces.Unsigned_64 :=
              Bytes.Read_U64 (Bitmap_Address (Item, Description.Run));
            Bit : constant Interfaces.Unsigned_64 := Interfaces.Shift_Left
              (Interfaces.Unsigned_64 (1), Natural (Description.Slot));
         begin
            if Live = 0 or else (Bitmap and Bit) = 0 then
               raise Handle_Error with "slab handle is reclaimed or stale";
            end if;
            Bytes.Write_U64
              (Bitmap_Address (Item, Description.Run), Bitmap and not Bit);
            Bytes.Write_U32
              (U32_Field (Item, Description.Run, Live_Offset), Live - 1);
            if Live = Slots then
               Add_To_Class (Item, Description.Run, Description.Class);
            end if;
         end;
      else
         for Run in Interfaces.Unsigned_32 range Description.Run ..
           Description.Run + Description.Span - 1
         loop
            Clear_Descriptor (Item, Run);
         end loop;
      end if;
   end Release_Unlocked;

   procedure Release (Item : in out View; Value : Allocation_Handle) is
      Mutated : Boolean := False;
   begin
      Acquire (Item);
      begin
         declare D : constant Block_Description := Validate_Handle (Item, Value);
         begin Mutated := True; Release_Unlocked (Item, Value, D); end;
      exception when others => Finish_Failure (Item, Mutated); raise; end;
      Release_Guard (Item);
   end Release;

   procedure Release
     (Item : in out View; Value : Allocation_Handle; Timeout : Wait_Timeout) is
      Mutated : Boolean := False;
   begin
      Acquire (Item, Timeout);
      begin
         declare D : constant Block_Description := Validate_Handle (Item, Value);
         begin Mutated := True; Release_Unlocked (Item, Value, D); end;
      exception when others => Finish_Failure (Item, Mutated); raise; end;
      Release_Guard (Item);
   end Release;

   function Block_Capacity
     (Item : View; Value : Allocation_Handle) return Byte_Count is
     (Validate_Handle (Item, Value).Capacity);

   procedure Attach_Allocation
     (Region : in out Region_View; Item : View; Value : Allocation_Handle)
   is
      D : Block_Description;
   begin
      Region.Base := System.Null_Address;
      Region.Length_Value := 0;
      Region.Attached := False;
      D := Validate_Handle (Item, Value);
      Region.Base := Layouts.Address_At
        (Item.Core, Layouts.Checked_Add (Item.Data_Offset, D.Offset), D.Capacity, 1);
      Region.Length_Value := D.Capacity;
      Region.Attached := True;
   end Attach_Allocation;

   function Payload_Address
     (Item : View; D : Block_Description; Offset, Extent : Byte_Count)
      return System.Address is
   begin
      if Offset > D.Capacity or else Extent > D.Capacity - Offset then
         raise Constraint_Error with "slab/span allocation slice is out of bounds";
      elsif Extent = 0 then
         raise Constraint_Error with "zero-sized allocation slice has no address";
      end if;
      return Layouts.Address_At
        (Item.Core,
         Layouts.Checked_Add
           (Item.Data_Offset, Layouts.Checked_Add (D.Offset, Offset)), Extent, 1);
   end Payload_Address;

   procedure Copy
     (Item : View; Source : Allocation_Handle; Source_Offset : Byte_Count;
      Target : Allocation_Handle; Target_Offset : Byte_Count; Length : Byte_Count)
   is
      S : constant Block_Description := Validate_Handle (Item, Source);
      T : constant Block_Description := Validate_Handle (Item, Target);
      Native_Length : Interfaces.C.size_t;
   begin
      if Source_Offset > S.Capacity or else Length > S.Capacity - Source_Offset
        or else Target_Offset > T.Capacity or else Length > T.Capacity - Target_Offset
      then
         raise Constraint_Error with "slab/span copy is out of bounds";
      elsif Length /= 0 then
         Native_Length := Interfaces.C.size_t (Length);
         if Byte_Count (Native_Length) /= Length then
            raise Constraint_Error with "slab/span copy is not native";
         end if;
         Bytes.Copy
           (Payload_Address (Item, T, Target_Offset, Length),
            Payload_Address (Item, S, Source_Offset, Length), Native_Length);
      end if;
   end Copy;

   procedure Destroy (Item : in out View) is
   begin
      Acquire (Item);
      begin
         Validate_Tables (Item);
         for Run in Interfaces.Unsigned_32 range 0 .. Item.Run_Count - 1 loop
            declare
               State : constant Interfaces.Unsigned_32 :=
                 Atomic.Load_Acquire_U32 (State_Address (Item, Run));
            begin
               if State = Large_Head_State
                 or else (State = Small_State and then Bytes.Read_U32
                   (U32_Field (Item, Run, Live_Offset)) /= 0)
               then
                  raise Layout_Error with "slab/span arena still has live allocations";
               end if;
            end;
         end loop;
      exception when others => Release_Guard (Item); raise; end;
      begin Layouts.Mark_Destroyed (Item.Core);
      exception when others => Release_Guard (Item); raise; end;
      Release_Guard (Item);
      Detach (Item);
   end Destroy;

end Flyology_Allocators.Allocation_Algorithms.Slab_Span_Kernel;
