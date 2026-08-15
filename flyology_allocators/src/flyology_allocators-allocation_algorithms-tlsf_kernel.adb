with Flyology_Allocators.Atomics;
with Flyology_Allocators.Policy;
with Flyology_Allocators.Storage;
with Flyology_Allocators.Waits;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology_Allocators.Allocation_Algorithms.TLSF_Kernel is
   package Atomic renames Flyology_Allocators.Atomics;
   package Policy renames Flyology_Allocators.Policy;
   package Bytes renames Flyology_Allocators.Storage;
   package Waiting renames Flyology_Allocators.Waits;
   package Addressing renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Addressing.Integer_Address;
   use type Addressing.Storage_Offset;
   use type System.Address;

   subtype Block_Ref is Interfaces.Unsigned_32;
   Null_Block : constant Block_Ref := Block_Ref'Last;

   function Count_Leading_Zeros
     (Value : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (Intrinsic, Count_Leading_Zeros, "__builtin_clz");

   function Count_Trailing_Zeros
     (Value : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (Intrinsic, Count_Trailing_Zeros, "__builtin_ctz");

   function Make_Token
     (Arena_Epoch : Interfaces.Unsigned_32;
      Block       : Block_Ref) return Interfaces.Unsigned_64 is
     (Interfaces.Shift_Left (Interfaces.Unsigned_64 (Arena_Epoch), 32)
      or Interfaces.Unsigned_64 (Block));
   pragma Inline_Always (Make_Token);

   function Token_Epoch
     (Value : Allocation_Handle) return Interfaces.Unsigned_32 is
     (Interfaces.Unsigned_32 (Interfaces.Shift_Right (Value.Token, 32)));
   pragma Inline_Always (Token_Epoch);

   function Token_Block (Value : Allocation_Handle) return Block_Ref is
     (Block_Ref
        (Value.Token
         and Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)));
   pragma Inline_Always (Token_Block);

   First_Level_Count  : constant := 32;
   Second_Level_Count : constant := 16;
   Second_Level_Log   : constant := 4;
   Index_Offset       : constant Byte_Count := Layouts.Header_Size;
   First_Map_Offset   : constant Byte_Count := Index_Offset;
   Index_Reserved     : constant Byte_Count := Index_Offset + 4;
   Live_Count_Offset  : constant Byte_Count := Index_Offset + 8;
   Second_Maps_Offset : constant Byte_Count := Index_Offset + 16;
   Heads_Offset       : constant Byte_Count :=
     Second_Maps_Offset + First_Level_Count * 4;
   Index_Size         : constant Byte_Count :=
     16 + First_Level_Count * 4
     + First_Level_Count * Second_Level_Count * 4;

   Guard_Offset   : constant Byte_Count := 44;
   Counter_Offset : constant Byte_Count := 56;

   Block_Size_Offset       : constant Byte_Count := 0;
   Previous_Size_Offset    : constant Byte_Count := 4;
   Generation_Offset       : constant Byte_Count := 8;
   Block_State_Offset      : constant Byte_Count := 16;
   Next_Free_Offset        : constant Byte_Count := 20;
   Previous_Free_Offset    : constant Byte_Count := 24;
   Block_Reserved_Offset   : constant Byte_Count := 28;
   Block_Metadata_Minimum  : constant Byte_Count := 32;

   Free_State      : constant Interfaces.Unsigned_32 := 1;
   Allocated_State : constant Interfaces.Unsigned_32 := 2;

   Unlocked : constant Interfaces.Unsigned_32 := 0;
   Locked   : constant Interfaces.Unsigned_32 := 1;

   type Geometry_Values is record
      Usable     : Interfaces.Unsigned_32;
      Minimum    : Interfaces.Unsigned_32;
      Prefix     : Interfaces.Unsigned_32;
      Units      : Interfaces.Unsigned_32;
      Data_Start : Byte_Count;
      Extent     : Byte_Count;
   end record;

   function Geometry
     (Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive) return Geometry_Values
   is
      Usable  : constant Byte_Count := Byte_Count (Usable_Capacity);
      Minimum : constant Byte_Count := Byte_Count (Minimum_Block_Size);
      Prefix  : Byte_Count;
      Units   : Byte_Count;
      Data_Start : Byte_Count;
   begin
      if Minimum < Byte_Count (Minimum_Block_Limit)
        or else not Policy.Is_Power_Of_Two (Minimum)
        or else Usable mod Minimum /= 0
      then
         raise Constraint_Error with "invalid arena TLSF geometry";
      elsif Usable > Byte_Count (Interfaces.Unsigned_32'Last)
        or else Minimum > Byte_Count (Interfaces.Unsigned_32'Last)
      then
         raise Constraint_Error with "arena geometry exceeds stored widths";
      end if;

      Prefix := Layouts.Align_Up (Block_Metadata_Minimum, Minimum);
      if Prefix > Byte_Count (Interfaces.Unsigned_32'Last)
        or else not Policy.Addition_Fits (Prefix, Minimum)
        or else Usable < Prefix + Minimum
      then
         raise Constraint_Error with "arena is too small for a TLSF block";
      end if;
      Units := Usable / Minimum;
      if Units = 0 or else Units >= Byte_Count (Null_Block) then
         raise Constraint_Error with "arena block index exceeds stored width";
      end if;
      Data_Start := Layouts.Align_Up
        (Layouts.Checked_Add (Index_Offset, Index_Size), Minimum);
      return
        (Usable     => Interfaces.Unsigned_32 (Usable),
         Minimum    => Interfaces.Unsigned_32 (Minimum),
         Prefix     => Interfaces.Unsigned_32 (Prefix),
         Units      => Interfaces.Unsigned_32 (Units),
         Data_Start => Data_Start,
         Extent     => Layouts.Checked_Add (Data_Start, Usable));
   end Geometry;

   function Required_Storage
     (Configuration : TLSF_Kernel.Configuration) return Byte_Count is
     (Geometry
        (Configuration.Usable_Capacity,
         Configuration.Minimum_Block_Size).Extent);

   function Index_Address
     (Item      : View;
      Relative  : Byte_Count;
      Extent    : Byte_Count;
      Alignment : Byte_Count) return System.Address is
      Local : Byte_Count;
   begin
      if not Item.Core.Attached
        or else Item.Index_Base = System.Null_Address
      then
         raise Region_Error with "detached arena view";
      elsif Relative < Index_Offset then
         raise Layout_Error with "arena index offset is corrupt";
      end if;
      Local := Relative - Index_Offset;
      if Extent = 0
        or else Local > Index_Size
        or else Extent > Index_Size - Local
      then
         raise Layout_Error with "arena index extent is corrupt";
      elsif Alignment = 0
        or else (Alignment and (Alignment - 1)) /= 0
        or else
          (Addressing.To_Integer (Item.Index_Base)
           + Addressing.Integer_Address (Local))
            mod Addressing.Integer_Address (Alignment) /= 0
      then
         raise Region_Error with "arena index field is misaligned";
      end if;
      return Item.Index_Base + Addressing.Storage_Offset (Local);
   end Index_Address;
   pragma Inline_Always (Index_Address);

   function Block_Address
     (Item      : View;
      Block     : Block_Ref;
      Relative  : Byte_Count;
      Extent    : Byte_Count;
      Alignment : Byte_Count) return System.Address is
   begin
      if Block = Null_Block
        or else Block >= Item.Usable_Value / Item.Minimum_Value
      then
         raise Layout_Error with "arena block reference is out of range";
      elsif Relative > Byte_Count (Item.Prefix_Value)
        or else Extent > Byte_Count (Item.Prefix_Value) - Relative
      then
         raise Layout_Error with "arena block field extent is corrupt";
      end if;
      if not Item.Core.Attached or else Item.Data_Base = System.Null_Address
      then
         raise Region_Error with "detached arena view";
      end if;
      declare
         Local : constant Byte_Count := Layouts.Checked_Add
           (Layouts.Checked_Multiply
              (Byte_Count (Block), Byte_Count (Item.Minimum_Value)),
            Relative);
         Address : constant System.Address := Item.Data_Base
           + Addressing.Storage_Offset (Local);
      begin
         if Extent = 0
           or else Local > Byte_Count (Item.Usable_Value)
           or else Extent > Byte_Count (Item.Usable_Value) - Local
         then
            raise Layout_Error with "arena block extent is corrupt";
         elsif Alignment = 0
           or else (Alignment and (Alignment - 1)) /= 0
           or else Addressing.To_Integer (Address)
             mod Addressing.Integer_Address (Alignment) /= 0
         then
            raise Region_Error with "arena block field is misaligned";
         end if;
         return Address;
      end;
   end Block_Address;
   pragma Inline_Always (Block_Address);

   function Block_Base
     (Item : View; Block : Block_Ref) return System.Address is
     (Block_Address
        (Item, Block, 0, Byte_Count (Item.Prefix_Value),
         Byte_Count (Item.Minimum_Value)));
   pragma Inline_Always (Block_Base);

   function Read_Field
     (Item : View; Block : Block_Ref; Relative : Byte_Count)
      return Interfaces.Unsigned_32 is
     (Bytes.Read_U32 (Block_Address (Item, Block, Relative, 4, 4)));
   pragma Inline_Always (Read_Field);

   procedure Write_Field
     (Item : View; Block : Block_Ref; Relative : Byte_Count;
      Value : Interfaces.Unsigned_32) is
   begin
      Bytes.Write_U32 (Block_Address (Item, Block, Relative, 4, 4), Value);
   end Write_Field;
   pragma Inline_Always (Write_Field);

   function Block_Size (Item : View; Block : Block_Ref)
      return Interfaces.Unsigned_32 is
     (Read_Field (Item, Block, Block_Size_Offset));
   function Previous_Size (Item : View; Block : Block_Ref)
      return Interfaces.Unsigned_32 is
     (Read_Field (Item, Block, Previous_Size_Offset));
   function Block_State (Item : View; Block : Block_Ref)
      return Interfaces.Unsigned_32 is
     (Atomic.Load_Acquire_U32
        (Block_Address (Item, Block, Block_State_Offset, 4, 4)));
   function Next_Free (Item : View; Block : Block_Ref) return Block_Ref is
     (Read_Field (Item, Block, Next_Free_Offset));
   function Previous_Free (Item : View; Block : Block_Ref)
      return Block_Ref is
     (Read_Field (Item, Block, Previous_Free_Offset));
   pragma Inline_Always
     (Block_Size, Previous_Size, Block_State, Next_Free, Previous_Free);

   procedure Set_Block_Size
     (Item : View; Block : Block_Ref; Value : Interfaces.Unsigned_32) is
   begin
      Write_Field (Item, Block, Block_Size_Offset, Value);
   end Set_Block_Size;
   procedure Set_Previous_Size
     (Item : View; Block : Block_Ref; Value : Interfaces.Unsigned_32) is
   begin
      Write_Field (Item, Block, Previous_Size_Offset, Value);
   end Set_Previous_Size;
   procedure Set_State
     (Item : View; Block : Block_Ref; Value : Interfaces.Unsigned_32) is
   begin
      Atomic.Store_Release_U32
        (Block_Address (Item, Block, Block_State_Offset, 4, 4), Value);
   end Set_State;
   procedure Set_Next_Free (Item : View; Block, Value : Block_Ref) is
   begin
      Write_Field (Item, Block, Next_Free_Offset, Value);
   end Set_Next_Free;
   procedure Set_Previous_Free
     (Item : View; Block, Value : Block_Ref) is
   begin
      Write_Field (Item, Block, Previous_Free_Offset, Value);
   end Set_Previous_Free;
   pragma Inline_Always
     (Set_Block_Size, Set_Previous_Size, Set_State, Set_Next_Free,
      Set_Previous_Free);

   function Live_Count (Item : View) return Interfaces.Unsigned_64 is
     (Bytes.Read_U64 (Item.Live_Count_Address));
   procedure Set_Live_Count
     (Item : View; Value : Interfaces.Unsigned_64) is
   begin
      Bytes.Write_U64 (Item.Live_Count_Address, Value);
   end Set_Live_Count;
   pragma Inline_Always (Live_Count, Set_Live_Count);

   subtype First_Level is Natural range 0 .. First_Level_Count - 1;
   subtype Second_Level is Natural range 0 .. Second_Level_Count - 1;

   type Size_Class is record
      First  : First_Level;
      Second : Second_Level;
   end record;

   function Bit (Index : Natural) return Interfaces.Unsigned_32 is
     (Interfaces.Shift_Left (Interfaces.Unsigned_32 (1), Index));
   pragma Inline_Always (Bit);

   function Floor_Log_2
     (Value : Interfaces.Unsigned_32) return First_Level
   is
   begin
      if Value = 0 then
         raise Layout_Error with "TLSF cannot classify a zero size";
      end if;
      return First_Level
        (31 - Integer
           (Count_Leading_Zeros (Interfaces.C.unsigned (Value))));
   end Floor_Log_2;
   pragma Inline_Always (Floor_Log_2);

   function Class_Of
     (Item : View; Size : Interfaces.Unsigned_32) return Size_Class
   is
      Units : Interfaces.Unsigned_32;
      First : First_Level;
      Base  : Interfaces.Unsigned_32;
      Second : Interfaces.Unsigned_32;
   begin
      if Size = 0 or else Size mod Item.Minimum_Value /= 0 then
         raise Layout_Error with "TLSF block size is not classifiable";
      end if;
      Units := Size / Item.Minimum_Value;
      First := Floor_Log_2 (Units);
      Base := Interfaces.Shift_Left (Interfaces.Unsigned_32 (1), First);
      Second := Interfaces.Unsigned_32
        (Interfaces.Shift_Right
           (Interfaces.Shift_Left
              (Interfaces.Unsigned_64 (Units - Base), Second_Level_Log),
            First));
      if Second >= Second_Level_Count then
         raise Layout_Error with "TLSF second-level class is corrupt";
      end if;
      return (First => First, Second => Second_Level (Second));
   end Class_Of;
   pragma Inline_Always (Class_Of);

   function First_Map (Item : View) return Interfaces.Unsigned_32 is
     (Bytes.Read_U32 (Item.First_Map_Address));
   procedure Set_First_Map
     (Item : View; Value : Interfaces.Unsigned_32) is
   begin
      Bytes.Write_U32 (Item.First_Map_Address, Value);
   end Set_First_Map;

   function Second_Map
     (Item : View; First : First_Level) return Interfaces.Unsigned_32 is
     (Bytes.Read_U32
        (Item.Second_Maps_Base + Addressing.Storage_Offset (First * 4)));
   procedure Set_Second_Map
     (Item : View; First : First_Level; Value : Interfaces.Unsigned_32) is
   begin
      Bytes.Write_U32
        (Item.Second_Maps_Base + Addressing.Storage_Offset (First * 4),
         Value);
   end Set_Second_Map;

   function Head
     (Item : View; Class : Size_Class) return Block_Ref is
     (Bytes.Read_U32
        (Item.Heads_Base
         + Addressing.Storage_Offset
           ((Class.First * Second_Level_Count + Class.Second) * 4)));
   procedure Set_Head
     (Item : View; Class : Size_Class; Value : Block_Ref) is
   begin
      Bytes.Write_U32
        (Item.Heads_Base
         + Addressing.Storage_Offset
           ((Class.First * Second_Level_Count + Class.Second) * 4),
         Value);
   end Set_Head;
   pragma Inline_Always
     (First_Map, Set_First_Map, Second_Map, Set_Second_Map, Head, Set_Head);

   function Generation (Item : View; Block : Block_Ref)
      return Interfaces.Unsigned_64 is
     (Bytes.Read_U64 (Block_Address (Item, Block, Generation_Offset, 8, 8)));
   procedure Set_Generation
     (Item : View; Block : Block_Ref; Value : Interfaces.Unsigned_64) is
   begin
      Bytes.Write_U64
        (Block_Address (Item, Block, Generation_Offset, 8, 8), Value);
   end Set_Generation;
   pragma Inline_Always (Generation, Set_Generation);

   procedure Set_View
     (Item : out View; Core : Layouts.Local_View; Values : Geometry_Values;
      Instance_ID : Interfaces.Unsigned_64) is
   begin
      Item.Core := Core;
      Item.Guard_Address := Layouts.Address_At (Core, Guard_Offset, 4, 4);
      Item.Counter_Address := Layouts.Address_At (Core, Counter_Offset, 8, 8);
      Item.Index_Base := Layouts.Address_At
        (Core, Index_Offset, Index_Size, 8);
      Item.Data_Base := Layouts.Address_At
        (Core, Values.Data_Start, Byte_Count (Values.Usable),
         Byte_Count (Values.Minimum));
      Item.First_Map_Address := Layouts.Address_At
        (Core, First_Map_Offset, 4, 4);
      Item.Second_Maps_Base := Layouts.Address_At
        (Core, Second_Maps_Offset, First_Level_Count * 4, 4);
      Item.Heads_Base := Layouts.Address_At
        (Core, Heads_Offset,
         First_Level_Count * Second_Level_Count * 4, 4);
      Item.Live_Count_Address := Layouts.Address_At
        (Core, Live_Count_Offset, 8, 8);
      Item.Usable_Value := Values.Usable;
      Item.Minimum_Value := Values.Minimum;
      Item.Prefix_Value := Values.Prefix;
      Item.Data_Offset := Values.Data_Start;
      Item.Instance_Value := Instance_ID;
   end Set_View;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Guard_Address := System.Null_Address;
      Item.Counter_Address := System.Null_Address;
      Item.Index_Base := System.Null_Address;
      Item.Data_Base := System.Null_Address;
      Item.First_Map_Address := System.Null_Address;
      Item.Second_Maps_Base := System.Null_Address;
      Item.Heads_Base := System.Null_Address;
      Item.Live_Count_Address := System.Null_Address;
      Item.Usable_Value := 0;
      Item.Minimum_Value := 0;
      Item.Prefix_Value := 0;
      Item.Data_Offset := 0;
      Item.Instance_Value := 0;
   end Detach;

   procedure Initialize_Block_At
     (Base          : System.Address;
      Size          : Interfaces.Unsigned_32;
      Previous      : Interfaces.Unsigned_32;
      State         : Interfaces.Unsigned_32;
      Generation_ID : Interfaces.Unsigned_64 := 0) is
   begin
      Bytes.Write_U32
        (Base + Addressing.Storage_Offset (Block_Size_Offset), Size);
      Bytes.Write_U32
        (Base + Addressing.Storage_Offset (Previous_Size_Offset), Previous);
      Bytes.Write_U64
        (Base + Addressing.Storage_Offset (Generation_Offset), Generation_ID);
      Bytes.Write_U32
        (Base + Addressing.Storage_Offset (Next_Free_Offset), Null_Block);
      Bytes.Write_U32
        (Base + Addressing.Storage_Offset (Previous_Free_Offset), Null_Block);
      Bytes.Write_U32
        (Base + Addressing.Storage_Offset (Block_Reserved_Offset), 0);
      Atomic.Store_Release_U32
        (Base + Addressing.Storage_Offset (Block_State_Offset), State);
   end Initialize_Block_At;

   procedure Initialize_Block
     (Item          : View;
      Block         : Block_Ref;
      Size          : Interfaces.Unsigned_32;
      Previous      : Interfaces.Unsigned_32;
      State         : Interfaces.Unsigned_32;
      Generation_ID : Interfaces.Unsigned_64 := 0) is
   begin
      Initialize_Block_At
        (Block_Base (Item, Block), Size, Previous, State, Generation_ID);
   end Initialize_Block;

   procedure Finish_Initialize
     (Item : out View; Core : Layouts.Local_View; Values : Geometry_Values;
      Instance_ID : Interfaces.Unsigned_64) is
   begin
      Set_View (Item, Core, Values, Instance_ID);
      Set_First_Map (Item, 0);
      Bytes.Write_U32 (Index_Address (Item, Index_Reserved, 4, 4), 0);
      Set_Live_Count (Item, 0);
      for First in First_Level loop
         Set_Second_Map (Item, First, 0);
         for Second in Second_Level loop
            Set_Head (Item, (First, Second), Null_Block);
         end loop;
      end loop;
      Initialize_Block (Item, 0, Values.Usable, 0, Free_State);
      declare
         Class : constant Size_Class := Class_Of (Item, Values.Usable);
      begin
         Set_Head (Item, Class, 0);
         Set_Second_Map (Item, Class.First, Bit (Class.Second));
         Set_First_Map (Item, Bit (Class.First));
      end;
      Layouts.Publish (Item.Core);
   end Finish_Initialize;

   procedure Check_Instance (Instance_ID : Interfaces.Unsigned_64) is
   begin
      if Instance_ID = 0 then
         raise Constraint_Error with "arena instance identity is zero";
      end if;
   end Check_Instance;

   procedure Initialize
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : TLSF_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64)
   is
      Values : constant Geometry_Values := Geometry
        (Configuration.Usable_Capacity, Configuration.Minimum_Block_Size);
      Core : Layouts.Local_View;
   begin
      Check_Instance (Instance_ID);
      Detach (Item);
      Layouts.Begin_Initialize
        (Core, Region, Location, Values.Extent,
         (Capacity     => Values.Usable,
          Element_Size => Values.Minimum,
          Alignment    => Values.Minimum,
          Auxiliary    => Unlocked,
          Word_1       => Instance_ID,
          Word_2       => 0),
         Byte_Count (Values.Minimum));
      Finish_Initialize (Item, Core, Values, Instance_ID);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Initialize;

   procedure Create_Or_Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : TLSF_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64;
      Result        : out Open_Result)
   is
      Values : constant Geometry_Values := Geometry
        (Configuration.Usable_Capacity, Configuration.Minimum_Block_Size);
      Core  : Layouts.Local_View;
      Claim : Layouts.Initialization_Claim;
   begin
      Check_Instance (Instance_ID);
      Detach (Item);
      Layouts.Try_Begin_Initialize
        (Core, Claim, Region, Location, Values.Extent,
         (Capacity     => Values.Usable,
          Element_Size => Values.Minimum,
          Alignment    => Values.Minimum,
          Auxiliary    => Unlocked,
          Word_1       => Instance_ID,
          Word_2       => 0),
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
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Create_Or_Attach;

   function Valid_Block_Ref (Item : View; Block : Block_Ref) return Boolean is
     (Block /= Null_Block
      and then Block < Item.Usable_Value / Item.Minimum_Value);
   pragma Inline_Always (Valid_Block_Ref);

   procedure Validate_Index (Item : View) is
      Physical_Free : Interfaces.Unsigned_32 := 0;
      Listed_Free   : Interfaces.Unsigned_32 := 0;
      Used_Blocks   : Interfaces.Unsigned_64 := 0;
      Cursor        : Block_Ref := 0;
      Previous      : Interfaces.Unsigned_32 := 0;
      Covered       : Interfaces.Unsigned_64 := 0;
      Previous_Was_Free : Boolean := False;
      Maximum_Blocks : constant Interfaces.Unsigned_32 :=
        Item.Usable_Value / Item.Minimum_Value;
   begin
      if Bytes.Read_U32 (Index_Address (Item, Index_Reserved, 4, 4)) /= 0 then
         raise Layout_Error with "arena index reserved field is corrupt";
      end if;
      while Covered < Interfaces.Unsigned_64 (Item.Usable_Value) loop
         if not Valid_Block_Ref (Item, Cursor) then
            raise Layout_Error with "arena physical block chain is truncated";
         end if;
         declare
            Size : constant Interfaces.Unsigned_32 :=
              Block_Size (Item, Cursor);
            State : constant Interfaces.Unsigned_32 :=
              Block_State (Item, Cursor);
            Gen : constant Interfaces.Unsigned_64 := Generation (Item, Cursor);
            Counter : constant Interfaces.Unsigned_64 :=
              Bytes.Read_U64 (Item.Counter_Address);
         begin
            if Size < Item.Prefix_Value + Item.Minimum_Value
              or else Size mod Item.Minimum_Value /= 0
              or else Previous_Size (Item, Cursor) /= Previous
              or else Interfaces.Unsigned_64 (Size) >
                Interfaces.Unsigned_64 (Item.Usable_Value) - Covered
              or else Read_Field (Item, Cursor, Block_Reserved_Offset) /= 0
              or else Gen > Counter
            then
               raise Layout_Error with
                 "arena physical block metadata is corrupt";
            elsif State = Free_State then
               if Previous_Was_Free then
                  raise Layout_Error with
                    "TLSF contains adjacent uncoalesced free blocks";
               end if;
               Physical_Free := Physical_Free + 1;
               Previous_Was_Free := True;
            elsif State = Allocated_State then
               Used_Blocks := Used_Blocks + 1;
               if Gen = 0
                 or else Next_Free (Item, Cursor) /= Null_Block
                 or else Previous_Free (Item, Cursor) /= Null_Block
               then
                  raise Layout_Error with
                    "arena allocated block metadata is corrupt";
               end if;
               Previous_Was_Free := False;
            else
               raise Layout_Error with "arena block state is corrupt";
            end if;
            Covered := Covered + Interfaces.Unsigned_64 (Size);
            Previous := Size;
            if Covered < Interfaces.Unsigned_64 (Item.Usable_Value) then
               Cursor := Cursor + Size / Item.Minimum_Value;
            end if;
         end;
      end loop;
      if Covered /= Interfaces.Unsigned_64 (Item.Usable_Value)
        or else Used_Blocks /= Live_Count (Item)
      then
         raise Layout_Error with "arena physical block accounting is corrupt";
      end if;

      declare
         Expected_First_Map : Interfaces.Unsigned_32 := 0;
      begin
         for First in First_Level loop
            declare
               Map : constant Interfaces.Unsigned_32 :=
                 Second_Map (Item, First);
               Expected_Second_Map : Interfaces.Unsigned_32 := 0;
            begin
               if (Map and 16#FFFF_0000#) /= 0 then
                  raise Layout_Error with
                    "TLSF second-level bitmap has reserved bits";
               end if;
               for Second in Second_Level loop
                  declare
                     Class : constant Size_Class := (First, Second);
                     Block : Block_Ref := Head (Item, Class);
                     Prior : Block_Ref := Null_Block;
                     Steps : Interfaces.Unsigned_32 := 0;
                  begin
                     if Block /= Null_Block then
                        Expected_Second_Map :=
                          Expected_Second_Map or Bit (Second);
                     end if;
                     while Block /= Null_Block loop
                        Steps := Steps + 1;
                        Listed_Free := Listed_Free + 1;
                        if Steps > Maximum_Blocks
                          or else Listed_Free > Maximum_Blocks
                          or else not Valid_Block_Ref (Item, Block)
                          or else Block_State (Item, Block) /= Free_State
                          or else Previous_Free (Item, Block) /= Prior
                          or else Class_Of
                            (Item, Block_Size (Item, Block)) /= Class
                        then
                           raise Layout_Error with
                             "TLSF free-list linkage is corrupt";
                        end if;
                        Prior := Block;
                        Block := Next_Free (Item, Block);
                     end loop;
                  end;
               end loop;
               if Map /= Expected_Second_Map then
                  raise Layout_Error with
                    "TLSF second-level bitmap disagrees with free lists";
               elsif Map /= 0 then
                  Expected_First_Map := Expected_First_Map or Bit (First);
               end if;
            end;
         end loop;
         if First_Map (Item) /= Expected_First_Map
           or else Listed_Free /= Physical_Free
         then
            raise Layout_Error with
              "TLSF first-level index or free-block count is corrupt";
         end if;
      end;
   end Validate_Index;

   procedure Acquire (Item : View);
   procedure Release_Guard (Item : View);

   procedure Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : TLSF_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64)
   is
      Values : constant Geometry_Values := Geometry
        (Configuration.Usable_Capacity, Configuration.Minimum_Block_Size);
      Core   : Layouts.Local_View;
      Header : Layouts.Header_Values;
   begin
      Check_Instance (Instance_ID);
      Detach (Item);
      Layouts.Attach
        (Core, Header, Region, Location, Byte_Count (Values.Minimum));
      if Header.Capacity /= Values.Usable
        or else Header.Element_Size /= Values.Minimum
        or else Header.Alignment /= Values.Minimum
        or else Header.Word_1 /= Instance_ID
        or else Core.Extent /= Values.Extent
      then
         raise Layout_Error with "arena creation parameters do not match";
      end if;
      Set_View (Item, Core, Values, Instance_ID);
      Acquire (Item);
      begin
         Validate_Index (Item);
      exception
         when others =>
            Release_Guard (Item);
            raise;
      end;
      Release_Guard (Item);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Attach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   function Current_Metadata (Item : View) return Metadata is
   begin
      Layouts.Require_Ready (Item.Core);
      return
        (Usable_Capacity    => Item.Usable_Value,
         Minimum_Block_Size => Item.Minimum_Value,
         Instance_ID        => Item.Instance_Value,
         Incarnation        => Item.Core.Epoch_Value,
         Extent             => Item.Core.Extent);
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
      if not Item.Core.Attached
        or else Item.Guard_Address = System.Null_Address
      then
         raise Region_Error with "detached arena view";
      elsif not Atomic.Compare_Exchange_U32
        (Item.Guard_Address, Expected, Locked)
      then
         Layouts.Require_Ready (Item.Core);
         if Expected = Locked then
            raise Busy_Error with "arena metadata is busy";
         else
            raise Layout_Error with "arena metadata guard is corrupt";
         end if;
      end if;
      begin
         Layouts.Require_Ready (Item.Core);
      exception
         when others =>
            Atomic.Store_Release_U32 (Item.Guard_Address, Unlocked);
            raise;
      end;
   end Acquire;
   pragma Inline_Always (Acquire);

   procedure Acquire (Item : View; Timeout : Wait_Timeout) is
      Wait     : Waiting.Context := Waiting.Start (Timeout);
      Expected : Interfaces.Unsigned_32;
   begin
      if not Item.Core.Attached
        or else Item.Guard_Address = System.Null_Address
      then
         raise Region_Error with "detached arena view";
      end if;
      Outer : loop
         Expected := Unlocked;
         exit Outer when Atomic.Compare_Exchange_U32
           (Item.Guard_Address, Expected, Locked);
         Inner : loop
            Layouts.Require_Ready (Item.Core);
            if Expected /= Locked then
               raise Layout_Error with "arena metadata guard is corrupt";
            end if;
            Waiting.Retry (Wait);
            Expected := Atomic.Load_Acquire_U32 (Item.Guard_Address);
            exit Inner when Expected = Unlocked;
         end loop Inner;
      end loop Outer;
      begin
         Layouts.Require_Ready (Item.Core);
      exception
         when others =>
            Atomic.Store_Release_U32 (Item.Guard_Address, Unlocked);
            raise;
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
         begin
            Layouts.Poison (Item.Core);
         exception
            when others =>
               Release_Guard (Item);
               raise;
         end;
      end if;
      Release_Guard (Item);
   end Finish_Failure;

   procedure List_Insert
     (Item : View; Block : Block_Ref; Base : System.Address;
      Size : Interfaces.Unsigned_32) is
      Stored_Size : constant Interfaces.Unsigned_32 := Bytes.Read_U32
        (Base + Addressing.Storage_Offset (Block_Size_Offset));
      Class : constant Size_Class := Class_Of (Item, Size);
      Previous_Head : constant Block_Ref := Head (Item, Class);
      Map : Interfaces.Unsigned_32;
   begin
      if Stored_Size /= Size then
         raise Layout_Error with "TLSF block size changed before insertion";
      end if;
      Bytes.Write_U32
        (Base + Addressing.Storage_Offset (Previous_Free_Offset), Null_Block);
      Bytes.Write_U32
        (Base + Addressing.Storage_Offset (Next_Free_Offset), Previous_Head);
      if Previous_Head /= Null_Block then
         declare
            Previous_Base : constant System.Address :=
              Block_Base (Item, Previous_Head);
         begin
            Bytes.Write_U32
              (Previous_Base
               + Addressing.Storage_Offset (Previous_Free_Offset),
               Block);
         end;
      end if;
      Set_Head (Item, Class, Block);
      Map := Second_Map (Item, Class.First) or Bit (Class.Second);
      Set_Second_Map (Item, Class.First, Map);
      Set_First_Map (Item, First_Map (Item) or Bit (Class.First));
   end List_Insert;

   procedure List_Remove
     (Item : View; Block : Block_Ref; Base : System.Address;
      Size : Interfaces.Unsigned_32) is
      Previous : constant Block_Ref := Bytes.Read_U32
        (Base + Addressing.Storage_Offset (Previous_Free_Offset));
      Following : constant Block_Ref := Bytes.Read_U32
        (Base + Addressing.Storage_Offset (Next_Free_Offset));
      Class : constant Size_Class := Class_Of (Item, Size);
      Previous_Base : System.Address := System.Null_Address;
      Following_Base : System.Address := System.Null_Address;
      Map : Interfaces.Unsigned_32;
   begin
      if Previous /= Null_Block then
         Previous_Base := Block_Base (Item, Previous);
      end if;
      if Following /= Null_Block then
         Following_Base := Block_Base (Item, Following);
      end if;
      if (Previous = Null_Block and then Head (Item, Class) /= Block)
        or else
          (Previous /= Null_Block
           and then Bytes.Read_U32
             (Previous_Base
              + Addressing.Storage_Offset (Next_Free_Offset)) /= Block)
        or else
          (Following /= Null_Block
           and then Bytes.Read_U32
             (Following_Base
              + Addressing.Storage_Offset (Previous_Free_Offset)) /= Block)
      then
         raise Layout_Error with "TLSF free-list linkage is corrupt";
      end if;
      if Previous = Null_Block then
         Set_Head (Item, Class, Following);
      else
         Bytes.Write_U32
           (Previous_Base + Addressing.Storage_Offset (Next_Free_Offset),
            Following);
      end if;
      if Following /= Null_Block then
         Bytes.Write_U32
           (Following_Base
            + Addressing.Storage_Offset (Previous_Free_Offset), Previous);
      end if;
      Bytes.Write_U32
        (Base + Addressing.Storage_Offset (Next_Free_Offset), Null_Block);
      Bytes.Write_U32
        (Base + Addressing.Storage_Offset (Previous_Free_Offset), Null_Block);
      if Previous = Null_Block and then Following = Null_Block then
         Map := Second_Map (Item, Class.First) and not Bit (Class.Second);
         Set_Second_Map (Item, Class.First, Map);
         if Map = 0 then
            Set_First_Map
              (Item, First_Map (Item) and not Bit (Class.First));
         end if;
      end if;
   end List_Remove;

   function First_Set
     (Map : Interfaces.Unsigned_32) return Natural
   is
   begin
      if Map = 0 then
         raise Layout_Error with "TLSF bitmap search received zero";
      end if;
      return Natural
        (Count_Trailing_Zeros (Interfaces.C.unsigned (Map)));
   end First_Set;
   pragma Inline_Always (First_Set);

   function Mask_From (Index : Natural) return Interfaces.Unsigned_32 is
     (if Index = 0 then Interfaces.Unsigned_32'Last
      else not (Bit (Index) - 1));
   pragma Inline_Always (Mask_From);

   function Find_TLSF
     (Item : View; Required : Interfaces.Unsigned_32;
      Base : out System.Address; Size : out Interfaces.Unsigned_32)
      return Block_Ref
   is
      Class : Size_Class := Class_Of (Item, Required);
      Map : Interfaces.Unsigned_32 :=
        Second_Map (Item, Class.First) and Mask_From (Class.Second);
      First_Map_Value : Interfaces.Unsigned_32;
      Result : Block_Ref;
   begin
      Base := System.Null_Address;
      Size := 0;
      if Map = 0 then
         if Class.First = First_Level'Last then
            return Null_Block;
         end if;
         First_Map_Value := First_Map (Item)
           and Mask_From (Class.First + 1);
         if First_Map_Value = 0 then
            return Null_Block;
         end if;
         Class.First := First_Level (First_Set (First_Map_Value));
         Map := Second_Map (Item, Class.First);
      end if;
      Class.Second := Second_Level (First_Set (Map));
      Result := Head (Item, Class);
      if Result = Null_Block then
         raise Layout_Error with "TLSF bitmap selected an empty list";
      end if;
      Base := Block_Base (Item, Result);
      Size := Bytes.Read_U32
        (Base + Addressing.Storage_Offset (Block_Size_Offset));
      if Size < Required then
         raise Layout_Error with "TLSF bitmap selected an undersized block";
      end if;
      return Result;
   end Find_TLSF;

   function Rounded_Block_Size
     (Item : View; Requested : Byte_Count) return Interfaces.Unsigned_32 is
      Payload : constant Byte_Count := Layouts.Align_Up
        (Requested, Byte_Count (Item.Minimum_Value));
      Total : constant Byte_Count := Layouts.Checked_Add
        (Byte_Count (Item.Prefix_Value), Payload);
      Units : Interfaces.Unsigned_64;
      Base  : Interfaces.Unsigned_64;
      Step  : Interfaces.Unsigned_64;
      Rounded_Units : Interfaces.Unsigned_64;
      Rounded_Total : Interfaces.Unsigned_64;
   begin
      if Total > Byte_Count (Interfaces.Unsigned_32'Last) then
         raise Constraint_Error with
            "arena allocation size exceeds stored width";
      end if;
      Units := Interfaces.Unsigned_64 (Total)
        / Interfaces.Unsigned_64 (Item.Minimum_Value);
      if Units <= Second_Level_Count then
         Rounded_Units := Units;
      else
         Base := Interfaces.Shift_Left
           (Interfaces.Unsigned_64 (1),
            Floor_Log_2 (Interfaces.Unsigned_32 (Units)));
         Step := Base / Second_Level_Count;
         Rounded_Units := ((Units + Step - 1) / Step) * Step;
      end if;
      Rounded_Total := Rounded_Units
        * Interfaces.Unsigned_64 (Item.Minimum_Value);
      if Rounded_Total > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)
      then
         raise Constraint_Error with
           "TLSF rounded allocation exceeds stored width";
      end if;
      return Interfaces.Unsigned_32 (Rounded_Total);
   end Rounded_Block_Size;

   function Allocate_Unlocked
     (Item : View; Requested_Size : Byte_Count;
      Value : out Allocation_Handle) return Boolean
   is
      Required : Interfaces.Unsigned_32;
      Block, Following, Remainder : Block_Ref;
      Size, Remainder_Size : Interfaces.Unsigned_32;
      Base, Remainder_Base : System.Address;
      Counter : Interfaces.Unsigned_64 :=
        Bytes.Read_U64 (Item.Counter_Address);
      Count : Interfaces.Unsigned_64;
   begin
      Value := Null_Allocation;
      if Requested_Size >
        Byte_Count (Item.Usable_Value - Item.Prefix_Value)
      then
         return False;
      end if;
      Required := Rounded_Block_Size (Item, Requested_Size);
      Block := Find_TLSF (Item, Required, Base, Size);
      if Block = Null_Block then
         return False;
      end if;
      if Counter = Interfaces.Unsigned_64'Last then
         raise Layout_Error with "arena allocation generation exhausted";
      end if;
      Count := Live_Count (Item);
      if Count = Interfaces.Unsigned_64'Last then
         raise Layout_Error with "arena live allocation count overflows";
      end if;

      List_Remove (Item, Block, Base, Size);
      if Size - Required >= Item.Prefix_Value + Item.Minimum_Value then
         Remainder_Size := Size - Required;
         Remainder := Block + Required / Item.Minimum_Value;
         Remainder_Base := Block_Base (Item, Remainder);
         Initialize_Block_At
           (Remainder_Base, Remainder_Size, Required, Free_State);
         Following := Remainder + Remainder_Size / Item.Minimum_Value;
         if Following < Item.Usable_Value / Item.Minimum_Value then
            Set_Previous_Size (Item, Following, Remainder_Size);
         end if;
         Bytes.Write_U32
           (Base + Addressing.Storage_Offset (Block_Size_Offset), Required);
         List_Insert
           (Item, Remainder, Remainder_Base, Remainder_Size);
      end if;

      Counter := Counter + 1;
      Bytes.Write_U64 (Item.Counter_Address, Counter);
      Bytes.Write_U64
        (Base + Addressing.Storage_Offset (Generation_Offset), Counter);
      Atomic.Store_Release_U32
        (Base + Addressing.Storage_Offset (Block_State_Offset),
         Allocated_State);
      Set_Live_Count (Item, Count + 1);
      Value :=
        (Token      => Make_Token (Item.Core.Epoch_Value, Block),
         Generation => Counter);
      return True;
   end Allocate_Unlocked;

   procedure Try_Allocate
     (Item : in out View; Requested_Size : Positive;
      Value : out Allocation_Handle; Result : out Allocation_Result)
   is
      Mutated : Boolean := False;
   begin
      Value := Null_Allocation;
      begin
         Acquire (Item);
      exception
         when Busy_Error =>
            Result := Allocation_Contended;
            return;
      end;
      begin
         Mutated := Requested_Size <= Natural (Item.Usable_Value);
         if Allocate_Unlocked (Item, Byte_Count (Requested_Size), Value) then
            Result := Allocated;
         else
            Result := Exhausted;
         end if;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release_Guard (Item);
   end Try_Allocate;

   procedure Try_Allocate
     (Item : in out View; Requested_Size : Positive; Timeout : Wait_Timeout;
      Value : out Allocation_Handle; Result : out Allocation_Result)
   is
      Mutated : Boolean := False;
   begin
      Value := Null_Allocation;
      Acquire (Item, Timeout);
      begin
         Mutated := Requested_Size <= Natural (Item.Usable_Value);
         if Allocate_Unlocked (Item, Byte_Count (Requested_Size), Value) then
            Result := Allocated;
         else
            Result := Exhausted;
         end if;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release_Guard (Item);
   end Try_Allocate;

   type Block_Description is record
      Capacity : Byte_Count;
      Offset   : Byte_Count;
      Base     : System.Address;
      Size     : Interfaces.Unsigned_32;
   end record;

   function Validate_Handle_Metadata
     (Item : View; Value : Allocation_Handle) return Block_Description
   is
      Block : constant Block_Ref := Token_Block (Value);
   begin
      if Value = Null_Allocation
        or else Token_Epoch (Value) = 0
        or else Value.Generation = 0
        or else Token_Epoch (Value) /= Item.Core.Epoch_Value
        or else not Valid_Block_Ref (Item, Block)
      then
         raise Handle_Error with "arena allocation handle is invalid or stale";
      end if;
      declare
         Base : constant System.Address := Block_Base (Item, Block);
         Size : constant Interfaces.Unsigned_32 := Bytes.Read_U32
           (Base + Addressing.Storage_Offset (Block_Size_Offset));
      begin
         if Atomic.Load_Acquire_U32
              (Base + Addressing.Storage_Offset (Block_State_Offset)) /=
                Allocated_State
           or else Bytes.Read_U64
             (Base + Addressing.Storage_Offset (Generation_Offset)) /=
               Value.Generation
         then
            raise Handle_Error with
              "arena allocation handle is invalid or stale";
         elsif Size < Item.Prefix_Value + Item.Minimum_Value
           or else Size mod Item.Minimum_Value /= 0
           or else Interfaces.Unsigned_64 (Block) *
             Interfaces.Unsigned_64 (Item.Minimum_Value)
             + Interfaces.Unsigned_64 (Size) >
               Interfaces.Unsigned_64 (Item.Usable_Value)
         then
            raise Layout_Error with "arena allocation block extent is corrupt";
         end if;
         return
           (Capacity => Byte_Count (Size - Item.Prefix_Value),
            Offset   => Layouts.Checked_Add
              (Layouts.Checked_Multiply
                 (Byte_Count (Block), Byte_Count (Item.Minimum_Value)),
               Byte_Count (Item.Prefix_Value)),
            Base     => Base,
            Size     => Size);
      end;
   end Validate_Handle_Metadata;

   function Validate_Handle
     (Item : View; Value : Allocation_Handle) return Block_Description is
   begin
      Layouts.Require_Ready (Item.Core);
      return Validate_Handle_Metadata (Item, Value);
   end Validate_Handle;

   function Next_Block
     (Item : View; Block : Block_Ref; Size : Interfaces.Unsigned_32)
      return Block_Ref is
      Candidate : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Block)
        + Interfaces.Unsigned_64 (Size / Item.Minimum_Value);
   begin
      if Candidate = Interfaces.Unsigned_64
        (Item.Usable_Value / Item.Minimum_Value)
      then
         return Null_Block;
      elsif Candidate > Interfaces.Unsigned_64
        (Item.Usable_Value / Item.Minimum_Value)
      then
         raise Layout_Error with "arena next block is out of range";
      end if;
      return Block_Ref (Candidate);
   end Next_Block;

   function Prior_Block
     (Item : View; Block : Block_Ref; Base : System.Address)
      return Block_Ref is
      Size : constant Interfaces.Unsigned_32 := Bytes.Read_U32
        (Base + Addressing.Storage_Offset (Previous_Size_Offset));
   begin
      if Size = 0 then
         return Null_Block;
      elsif Size mod Item.Minimum_Value /= 0
        or else Size / Item.Minimum_Value > Block
      then
         raise Layout_Error with "arena previous block is out of range";
      end if;
      return Block - Size / Item.Minimum_Value;
   end Prior_Block;

   procedure Release_Unlocked
     (Item : View; Value : Allocation_Handle;
      Description : Block_Description) is
      Block : Block_Ref := Token_Block (Value);
      Next, Previous, Following : Block_Ref;
      Base : System.Address := Description.Base;
      Neighbor_Base : System.Address;
      Size : Interfaces.Unsigned_32 := Description.Size;
      Neighbor_Size : Interfaces.Unsigned_32;
      Count : constant Interfaces.Unsigned_64 := Live_Count (Item);

      function Combined_Size
        (Left, Right : Interfaces.Unsigned_32)
         return Interfaces.Unsigned_32
      is
         Total : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (Left) + Interfaces.Unsigned_64 (Right);
      begin
         if Total > Interfaces.Unsigned_64 (Item.Usable_Value) then
            raise Layout_Error with "arena coalesced block size is corrupt";
         end if;
         return Interfaces.Unsigned_32 (Total);
      end Combined_Size;
   begin
      if Count = 0 then
         raise Layout_Error with "arena live allocation count underflows";
      end if;
      Atomic.Store_Release_U32
        (Base + Addressing.Storage_Offset (Block_State_Offset), Free_State);
      Next := Next_Block (Item, Block, Size);
      if Next /= Null_Block then
         Neighbor_Base := Block_Base (Item, Next);
      end if;
      if Next /= Null_Block
        and then Atomic.Load_Acquire_U32
          (Neighbor_Base + Addressing.Storage_Offset (Block_State_Offset)) =
            Free_State
      then
         Neighbor_Size := Bytes.Read_U32
           (Neighbor_Base + Addressing.Storage_Offset (Block_Size_Offset));
         List_Remove (Item, Next, Neighbor_Base, Neighbor_Size);
         Size := Combined_Size (Size, Neighbor_Size);
         Bytes.Write_U32
           (Base + Addressing.Storage_Offset (Block_Size_Offset), Size);
         Following := Next_Block (Item, Block, Size);
         if Following /= Null_Block then
            Set_Previous_Size (Item, Following, Size);
         end if;
      end if;
      Previous := Prior_Block (Item, Block, Base);
      if Previous /= Null_Block then
         Neighbor_Base := Block_Base (Item, Previous);
      end if;
      if Previous /= Null_Block
        and then Atomic.Load_Acquire_U32
          (Neighbor_Base + Addressing.Storage_Offset (Block_State_Offset)) =
            Free_State
      then
         Neighbor_Size := Bytes.Read_U32
           (Neighbor_Base + Addressing.Storage_Offset (Block_Size_Offset));
         List_Remove (Item, Previous, Neighbor_Base, Neighbor_Size);
         Size := Combined_Size (Neighbor_Size, Size);
         Bytes.Write_U32
           (Neighbor_Base + Addressing.Storage_Offset (Block_Size_Offset),
            Size);
         Following := Next_Block (Item, Previous, Size);
         if Following /= Null_Block then
            Set_Previous_Size (Item, Following, Size);
         end if;
         Block := Previous;
         Base := Neighbor_Base;
      end if;
      Bytes.Write_U32
        (Base + Addressing.Storage_Offset (Next_Free_Offset), Null_Block);
      Bytes.Write_U32
        (Base + Addressing.Storage_Offset (Previous_Free_Offset), Null_Block);
      List_Insert (Item, Block, Base, Size);
      Set_Live_Count (Item, Count - 1);
   end Release_Unlocked;

   procedure Release (Item : in out View; Value : Allocation_Handle) is
      Mutated : Boolean := False;
   begin
      Acquire (Item);
      begin
         declare
            Description : constant Block_Description :=
              Validate_Handle_Metadata (Item, Value);
         begin
            Mutated := True;
            Release_Unlocked (Item, Value, Description);
         end;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release_Guard (Item);
   end Release;

   procedure Release
     (Item : in out View; Value : Allocation_Handle; Timeout : Wait_Timeout) is
      Mutated : Boolean := False;
   begin
      Acquire (Item, Timeout);
      begin
         declare
            Description : constant Block_Description :=
              Validate_Handle_Metadata (Item, Value);
         begin
            Mutated := True;
            Release_Unlocked (Item, Value, Description);
         end;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release_Guard (Item);
   end Release;

   function Block_Capacity
     (Item : View; Value : Allocation_Handle) return Byte_Count is
     (Validate_Handle (Item, Value).Capacity);

   procedure Attach_Allocation
     (Region : in out Region_View; Item : View; Value : Allocation_Handle)
   is
      Description : Block_Description;
   begin
      Region.Base := System.Null_Address;
      Region.Length_Value := 0;
      Region.Attached := False;
      Description := Validate_Handle (Item, Value);
      Region.Base := Layouts.Address_At
        (Item.Core, Layouts.Checked_Add (Item.Data_Offset, Description.Offset),
         Description.Capacity, 1);
      Region.Length_Value := Description.Capacity;
      Region.Attached := True;
   end Attach_Allocation;

   function Payload_Address
     (Item : View; Description : Block_Description;
      Offset, Extent : Byte_Count; Alignment : Byte_Count := 1)
      return System.Address
   is
      Relative : Byte_Count;
   begin
      if Offset > Description.Capacity
        or else Extent > Description.Capacity - Offset
      then
         raise Constraint_Error with "arena allocation slice is out of bounds";
      elsif Extent = 0 then
         raise Constraint_Error with "zero-sized arena slice has no address";
      end if;
      Relative := Layouts.Checked_Add (Description.Offset, Offset);
      if not Item.Core.Attached or else Item.Data_Base = System.Null_Address
      then
         raise Region_Error with "detached arena view";
      end if;
      declare
         Address : constant System.Address := Item.Data_Base
           + Addressing.Storage_Offset (Relative);
      begin
         if Alignment = 0
           or else (Alignment and (Alignment - 1)) /= 0
           or else Addressing.To_Integer (Address)
             mod Addressing.Integer_Address (Alignment) /= 0
         then
            raise Region_Error with "arena payload slice is misaligned";
         end if;
         return Address;
      end;
   end Payload_Address;

   procedure Copy
     (Item : View; Source : Allocation_Handle; Source_Offset : Byte_Count;
      Target : Allocation_Handle; Target_Offset, Length : Byte_Count)
   is
      Source_Description : constant Block_Description :=
        Validate_Handle (Item, Source);
      Target_Description : constant Block_Description :=
        Validate_Handle (Item, Target);
      Native_Length : Interfaces.C.size_t;
   begin
      if Source_Offset > Source_Description.Capacity
        or else Length > Source_Description.Capacity - Source_Offset
        or else Target_Offset > Target_Description.Capacity
        or else Length > Target_Description.Capacity - Target_Offset
      then
         raise Constraint_Error with "arena copy is out of bounds";
      elsif Length /= 0 then
         Native_Length := Interfaces.C.size_t (Length);
         if Byte_Count (Native_Length) /= Length then
            raise Constraint_Error with
              "arena copy is not natively representable";
         end if;
         Bytes.Copy
           (Payload_Address
              (Item, Target_Description, Target_Offset, Length),
            Payload_Address
              (Item, Source_Description, Source_Offset, Length),
            Native_Length);
      end if;
   end Copy;

   procedure Destroy (Item : in out View) is
   begin
      Acquire (Item);
      begin
         Validate_Index (Item);
         if Live_Count (Item) /= 0
           or else Head
             (Item, Class_Of (Item, Item.Usable_Value)) /= 0
           or else Block_State (Item, 0) /= Free_State
           or else Block_Size (Item, 0) /= Item.Usable_Value
         then
            raise Layout_Error with "arena still has live allocations";
         end if;
         Layouts.Mark_Destroyed (Item.Core);
      exception
         when others =>
            Release_Guard (Item);
            raise;
      end;
      Release_Guard (Item);
      Detach (Item);
   end Destroy;

end Flyology_Allocators.Allocation_Algorithms.TLSF_Kernel;
