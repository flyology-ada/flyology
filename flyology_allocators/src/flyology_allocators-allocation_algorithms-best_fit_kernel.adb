with Flyology_Allocators.Atomics;
with Flyology_Allocators.Policy;
with Flyology_Allocators.Storage;
with Flyology_Allocators.Waits;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology_Allocators.Allocation_Algorithms.Best_Fit_Kernel is
   package Atomic renames Flyology_Allocators.Atomics;
   package Policy renames Flyology_Allocators.Policy;
   package Bytes renames Flyology_Allocators.Storage;
   package Waiting renames Flyology_Allocators.Waits;
   package Addressing renames System.Storage_Elements;

   use type Interfaces.Integer_64;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Addressing.Integer_Address;
   use type Addressing.Storage_Offset;
   use type System.Address;

   subtype Block_Ref is Interfaces.Unsigned_32;
   Null_Block : constant Block_Ref := Block_Ref'Last;

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

   Index_Offset      : constant Byte_Count := Layouts.Header_Size;
   Index_Size        : constant Byte_Count := 16;
   Root_Offset       : constant Byte_Count := Index_Offset;
   Index_Reserved    : constant Byte_Count := Index_Offset + 4;
   Live_Count_Offset : constant Byte_Count := Index_Offset + 8;

   Guard_Offset   : constant Byte_Count := 44;
   Counter_Offset : constant Byte_Count := 56;

   Block_Size_Offset       : constant Byte_Count := 0;
   Previous_Size_Offset    : constant Byte_Count := 4;
   Generation_Offset       : constant Byte_Count := 8;
   Block_State_Offset      : constant Byte_Count := 16;
   Left_Offset             : constant Byte_Count := 20;
   Right_Offset            : constant Byte_Count := 24;
   Parent_Offset           : constant Byte_Count := 28;
   Height_Offset           : constant Byte_Count := 32;
   Block_Reserved_Offset   : constant Byte_Count := 36;
   Block_Metadata_Minimum  : constant Byte_Count := 40;

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
         raise Constraint_Error with "invalid arena best-fit geometry";
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
         raise Constraint_Error with "arena is too small for a best-fit block";
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
     (Configuration : Best_Fit_Kernel.Configuration) return Byte_Count is
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
   function Left_Of (Item : View; Block : Block_Ref) return Block_Ref is
     (Read_Field (Item, Block, Left_Offset));
   function Right_Of (Item : View; Block : Block_Ref) return Block_Ref is
     (Read_Field (Item, Block, Right_Offset));
   function Parent_Of (Item : View; Block : Block_Ref) return Block_Ref is
     (Read_Field (Item, Block, Parent_Offset));
   function Height_Of (Item : View; Block : Block_Ref)
      return Interfaces.Unsigned_32 is
     (if Block = Null_Block then 0
      else Read_Field (Item, Block, Height_Offset));
   pragma Inline_Always
     (Block_Size, Previous_Size, Block_State, Left_Of, Right_Of, Parent_Of,
      Height_Of);

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
   procedure Set_Left (Item : View; Block, Value : Block_Ref) is
   begin
      Write_Field (Item, Block, Left_Offset, Value);
   end Set_Left;
   procedure Set_Right (Item : View; Block, Value : Block_Ref) is
   begin
      Write_Field (Item, Block, Right_Offset, Value);
   end Set_Right;
   procedure Set_Parent (Item : View; Block, Value : Block_Ref) is
   begin
      Write_Field (Item, Block, Parent_Offset, Value);
   end Set_Parent;
   procedure Set_Height
     (Item : View; Block : Block_Ref; Value : Interfaces.Unsigned_32) is
   begin
      Write_Field (Item, Block, Height_Offset, Value);
   end Set_Height;
   pragma Inline_Always
     (Set_Block_Size, Set_Previous_Size, Set_State, Set_Left, Set_Right,
      Set_Parent, Set_Height);

   function Root (Item : View) return Block_Ref is
     (Bytes.Read_U32 (Item.Root_Address));
   procedure Set_Root (Item : View; Value : Block_Ref) is
   begin
      Bytes.Write_U32 (Item.Root_Address, Value);
   end Set_Root;
   function Live_Count (Item : View) return Interfaces.Unsigned_64 is
     (Bytes.Read_U64 (Item.Live_Count_Address));
   procedure Set_Live_Count
     (Item : View; Value : Interfaces.Unsigned_64) is
   begin
      Bytes.Write_U64 (Item.Live_Count_Address, Value);
   end Set_Live_Count;
   pragma Inline_Always (Root, Set_Root, Live_Count, Set_Live_Count);

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
      Item.Root_Address := Layouts.Address_At (Core, Root_Offset, 4, 4);
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
      Item.Root_Address := System.Null_Address;
      Item.Live_Count_Address := System.Null_Address;
      Item.Usable_Value := 0;
      Item.Minimum_Value := 0;
      Item.Prefix_Value := 0;
      Item.Data_Offset := 0;
      Item.Instance_Value := 0;
   end Detach;

   procedure Initialize_Block
     (Item          : View;
      Block         : Block_Ref;
      Size          : Interfaces.Unsigned_32;
      Previous      : Interfaces.Unsigned_32;
      State         : Interfaces.Unsigned_32;
      Generation_ID : Interfaces.Unsigned_64 := 0) is
   begin
      Set_Block_Size (Item, Block, Size);
      Set_Previous_Size (Item, Block, Previous);
      Set_Generation (Item, Block, Generation_ID);
      Set_Left (Item, Block, Null_Block);
      Set_Right (Item, Block, Null_Block);
      Set_Parent (Item, Block, Null_Block);
      Set_Height (Item, Block, (if State = Free_State then 1 else 0));
      Write_Field (Item, Block, Block_Reserved_Offset, 0);
      Set_State (Item, Block, State);
   end Initialize_Block;

   procedure Finish_Initialize
     (Item : out View; Core : Layouts.Local_View; Values : Geometry_Values;
      Instance_ID : Interfaces.Unsigned_64) is
   begin
      Set_View (Item, Core, Values, Instance_ID);
      Set_Root (Item, 0);
      Bytes.Write_U32 (Index_Address (Item, Index_Reserved, 4, 4), 0);
      Set_Live_Count (Item, 0);
      Initialize_Block (Item, 0, Values.Usable, 0, Free_State);
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
      Configuration : Best_Fit_Kernel.Configuration;
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
      Configuration : Best_Fit_Kernel.Configuration;
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

   function Key_Less (Item : View; Left, Right : Block_Ref) return Boolean is
      Left_Size  : constant Interfaces.Unsigned_32 := Block_Size (Item, Left);
      Right_Size : constant Interfaces.Unsigned_32 := Block_Size (Item, Right);
   begin
      return Left_Size < Right_Size
        or else (Left_Size = Right_Size and then Left < Right);
   end Key_Less;
   pragma Inline_Always (Key_Less);

   function Valid_Block_Ref (Item : View; Block : Block_Ref) return Boolean is
     (Block /= Null_Block
      and then Block < Item.Usable_Value / Item.Minimum_Value);
   pragma Inline_Always (Valid_Block_Ref);

   --  An AVL tree over the at most 2**32 - 1 addressable blocks cannot exceed
   --  46 levels, so a deeper descent means the stored links are corrupt.
   --  Bounding the descent keeps corrupt metadata a Layout_Error instead of a
   --  recursion deep enough to exhaust the caller's stack.
   Maximum_Tree_Depth : constant Interfaces.Unsigned_32 := 64;

   procedure Validate_Index (Item : View) is
      Free_Blocks : Interfaces.Unsigned_32 := 0;
      Physical_Free : Interfaces.Unsigned_32 := 0;
      Used_Blocks : Interfaces.Unsigned_64 := 0;
      Cursor      : Block_Ref := 0;
      Previous    : Interfaces.Unsigned_32 := 0;
      Covered     : Interfaces.Unsigned_64 := 0;
      Previous_Was_Free : Boolean := False;
      Maximum_Blocks : constant Interfaces.Unsigned_32 :=
        Item.Usable_Value / Item.Minimum_Value;

      function Validate_Tree
        (Block : Block_Ref; Expected_Parent : Block_Ref;
         Lower, Upper : Block_Ref; Depth : Interfaces.Unsigned_32)
         return Interfaces.Unsigned_32
      is
         Left, Right : Block_Ref;
         Left_Height, Right_Height, Stored_Height : Interfaces.Unsigned_32;
         Difference : Interfaces.Integer_64;
      begin
         if Block = Null_Block then
            return 0;
         elsif Depth > Maximum_Tree_Depth
           or else not Valid_Block_Ref (Item, Block)
         then
            raise Layout_Error with
              "arena free tree is cyclic or out of range";
         elsif Block_State (Item, Block) /= Free_State
           or else Parent_Of (Item, Block) /= Expected_Parent
           or else
             (Lower /= Null_Block
              and then not Key_Less (Item, Lower, Block))
           or else
             (Upper /= Null_Block
              and then not Key_Less (Item, Block, Upper))
         then
            raise Layout_Error with "arena free tree ordering is corrupt";
         end if;
         Free_Blocks := Free_Blocks + 1;
         if Free_Blocks > Maximum_Blocks then
            raise Layout_Error with
              "arena free tree is cyclic or contains duplicates";
         end if;
         Left := Left_Of (Item, Block);
         Right := Right_Of (Item, Block);
         Left_Height := Validate_Tree
           (Left, Block, Lower, Block, Depth + 1);
         Right_Height := Validate_Tree
           (Right, Block, Block, Upper, Depth + 1);
         Difference := Interfaces.Integer_64 (Left_Height)
           - Interfaces.Integer_64 (Right_Height);
         Stored_Height := Height_Of (Item, Block);
         if Difference < -1 or else Difference > 1
           or else Stored_Height /=
             Interfaces.Unsigned_32'Max (Left_Height, Right_Height) + 1
         then
            raise Layout_Error with "arena free tree balance is corrupt";
         end if;
         return Stored_Height;
      end Validate_Tree;

      Tree_Root : Block_Ref;
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
                    "best-fit contains adjacent uncoalesced free blocks";
               end if;
               Physical_Free := Physical_Free + 1;
               Previous_Was_Free := True;
            elsif State = Allocated_State then
               Used_Blocks := Used_Blocks + 1;
               if Gen = 0
                 or else Left_Of (Item, Cursor) /= Null_Block
                 or else Right_Of (Item, Cursor) /= Null_Block
                 or else Parent_Of (Item, Cursor) /= Null_Block
                 or else Height_Of (Item, Cursor) /= 0
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
      Tree_Root := Root (Item);
      if Tree_Root /= Null_Block
        and then Parent_Of (Item, Tree_Root) /= Null_Block
      then
         raise Layout_Error with "arena free tree root has a parent";
      end if;
      declare
         Ignored_Height : constant Interfaces.Unsigned_32 :=
           Validate_Tree (Tree_Root, Null_Block, Null_Block, Null_Block, 1);
         pragma Unreferenced (Ignored_Height);
      begin
         null;
      end;
      if Free_Blocks /= Physical_Free then
         raise Layout_Error with "arena free tree omits a physical block";
      end if;
   end Validate_Index;

   procedure Acquire (Item : View);
   procedure Release_Guard (Item : View);

   procedure Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Best_Fit_Kernel.Configuration;
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

   procedure Update_Height (Item : View; Block : Block_Ref) is
   begin
      Set_Height
        (Item, Block,
         Interfaces.Unsigned_32'Max
           (Height_Of (Item, Left_Of (Item, Block)),
            Height_Of (Item, Right_Of (Item, Block))) + 1);
   end Update_Height;

   function Balance (Item : View; Block : Block_Ref)
      return Interfaces.Integer_64 is
     (Interfaces.Integer_64 (Height_Of (Item, Left_Of (Item, Block)))
      - Interfaces.Integer_64 (Height_Of (Item, Right_Of (Item, Block))));

   procedure Replace_Child
     (Item : View; Parent, Previous, Replacement : Block_Ref) is
   begin
      if Parent = Null_Block then
         Set_Root (Item, Replacement);
      elsif Left_Of (Item, Parent) = Previous then
         Set_Left (Item, Parent, Replacement);
      elsif Right_Of (Item, Parent) = Previous then
         Set_Right (Item, Parent, Replacement);
      else
         raise Layout_Error with "arena free tree parent link is corrupt";
      end if;
      if Replacement /= Null_Block then
         Set_Parent (Item, Replacement, Parent);
      end if;
   end Replace_Child;

   function Rotate_Left (Item : View; Block : Block_Ref) return Block_Ref is
      Pivot : constant Block_Ref := Right_Of (Item, Block);
      Parent : constant Block_Ref := Parent_Of (Item, Block);
      Middle : Block_Ref;
   begin
      if Pivot = Null_Block then
         raise Layout_Error with "arena AVL left rotation has no pivot";
      end if;
      Middle := Left_Of (Item, Pivot);
      Replace_Child (Item, Parent, Block, Pivot);
      Set_Left (Item, Pivot, Block);
      Set_Parent (Item, Block, Pivot);
      Set_Right (Item, Block, Middle);
      if Middle /= Null_Block then
         Set_Parent (Item, Middle, Block);
      end if;
      Update_Height (Item, Block);
      Update_Height (Item, Pivot);
      return Pivot;
   end Rotate_Left;

   function Rotate_Right (Item : View; Block : Block_Ref) return Block_Ref is
      Pivot : constant Block_Ref := Left_Of (Item, Block);
      Parent : constant Block_Ref := Parent_Of (Item, Block);
      Middle : Block_Ref;
   begin
      if Pivot = Null_Block then
         raise Layout_Error with "arena AVL right rotation has no pivot";
      end if;
      Middle := Right_Of (Item, Pivot);
      Replace_Child (Item, Parent, Block, Pivot);
      Set_Right (Item, Pivot, Block);
      Set_Parent (Item, Block, Pivot);
      Set_Left (Item, Block, Middle);
      if Middle /= Null_Block then
         Set_Parent (Item, Middle, Block);
      end if;
      Update_Height (Item, Block);
      Update_Height (Item, Pivot);
      return Pivot;
   end Rotate_Right;

   procedure Rebalance_Up (Item : View; Start : Block_Ref) is
      Block : Block_Ref := Start;
      New_Root : Block_Ref;
   begin
      while Block /= Null_Block loop
         Update_Height (Item, Block);
         if Balance (Item, Block) > 1 then
            if Balance (Item, Left_Of (Item, Block)) < 0 then
               declare
                  Child_Root : constant Block_Ref :=
                    Rotate_Left (Item, Left_Of (Item, Block));
                  pragma Unreferenced (Child_Root);
               begin
                  null;
               end;
            end if;
            New_Root := Rotate_Right (Item, Block);
         elsif Balance (Item, Block) < -1 then
            if Balance (Item, Right_Of (Item, Block)) > 0 then
               declare
                  Child_Root : constant Block_Ref :=
                    Rotate_Right (Item, Right_Of (Item, Block));
                  pragma Unreferenced (Child_Root);
               begin
                  null;
               end;
            end if;
            New_Root := Rotate_Left (Item, Block);
         else
            New_Root := Block;
         end if;
         Block := Parent_Of (Item, New_Root);
      end loop;
   end Rebalance_Up;

   procedure Tree_Insert (Item : View; Block : Block_Ref) is
      Parent : Block_Ref := Null_Block;
      Cursor : Block_Ref := Root (Item);
   begin
      Set_Left (Item, Block, Null_Block);
      Set_Right (Item, Block, Null_Block);
      Set_Parent (Item, Block, Null_Block);
      Set_Height (Item, Block, 1);
      while Cursor /= Null_Block loop
         Parent := Cursor;
         Cursor :=
           (if Key_Less (Item, Block, Cursor)
            then Left_Of (Item, Cursor) else Right_Of (Item, Cursor));
      end loop;
      Set_Parent (Item, Block, Parent);
      if Parent = Null_Block then
         Set_Root (Item, Block);
      elsif Key_Less (Item, Block, Parent) then
         Set_Left (Item, Parent, Block);
      else
         Set_Right (Item, Parent, Block);
      end if;
      Rebalance_Up (Item, Parent);
   end Tree_Insert;

   function Tree_Minimum (Item : View; Start : Block_Ref) return Block_Ref is
      Cursor : Block_Ref := Start;
   begin
      if Cursor = Null_Block then
         raise Layout_Error with "arena free tree minimum is null";
      end if;
      while Left_Of (Item, Cursor) /= Null_Block loop
         Cursor := Left_Of (Item, Cursor);
      end loop;
      return Cursor;
   end Tree_Minimum;

   procedure Tree_Remove (Item : View; Block : Block_Ref) is
      Left  : constant Block_Ref := Left_Of (Item, Block);
      Right : constant Block_Ref := Right_Of (Item, Block);
      Start : Block_Ref;
      Successor, Successor_Parent, Successor_Right : Block_Ref;
   begin
      if Left = Null_Block then
         Start := Parent_Of (Item, Block);
         Replace_Child (Item, Start, Block, Right);
      elsif Right = Null_Block then
         Start := Parent_Of (Item, Block);
         Replace_Child (Item, Start, Block, Left);
      else
         Successor := Tree_Minimum (Item, Right);
         Successor_Parent := Parent_Of (Item, Successor);
         Successor_Right := Right_Of (Item, Successor);
         if Successor_Parent /= Block then
            Replace_Child
              (Item, Successor_Parent, Successor, Successor_Right);
            Set_Right (Item, Successor, Right);
            Set_Parent (Item, Right, Successor);
            Start := Successor_Parent;
         else
            Start := Successor;
         end if;
         Replace_Child
           (Item, Parent_Of (Item, Block), Block, Successor);
         Set_Left (Item, Successor, Left);
         Set_Parent (Item, Left, Successor);
         Update_Height (Item, Successor);
      end if;
      Set_Left (Item, Block, Null_Block);
      Set_Right (Item, Block, Null_Block);
      Set_Parent (Item, Block, Null_Block);
      Set_Height (Item, Block, 0);
      Rebalance_Up (Item, Start);
   end Tree_Remove;

   function Find_Best_Fit
     (Item : View; Required : Interfaces.Unsigned_32) return Block_Ref is
      Cursor : Block_Ref := Root (Item);
      Candidate : Block_Ref := Null_Block;
   begin
      while Cursor /= Null_Block loop
         if Block_Size (Item, Cursor) >= Required then
            Candidate := Cursor;
            Cursor := Left_Of (Item, Cursor);
         else
            Cursor := Right_Of (Item, Cursor);
         end if;
      end loop;
      return Candidate;
   end Find_Best_Fit;

   function Rounded_Block_Size
     (Item : View; Requested : Byte_Count) return Interfaces.Unsigned_32 is
      Payload : constant Byte_Count := Layouts.Align_Up
        (Requested, Byte_Count (Item.Minimum_Value));
      Total : constant Byte_Count := Layouts.Checked_Add
        (Byte_Count (Item.Prefix_Value), Payload);
   begin
      if Total > Byte_Count (Interfaces.Unsigned_32'Last) then
         raise Constraint_Error with
           "arena allocation size exceeds stored width";
      end if;
      return Interfaces.Unsigned_32 (Total);
   end Rounded_Block_Size;

   function Allocate_Unlocked
     (Item : View; Requested_Size : Byte_Count;
      Value : out Allocation_Handle) return Boolean
   is
      Required : Interfaces.Unsigned_32;
      Block, Following, Remainder : Block_Ref;
      Size, Remainder_Size : Interfaces.Unsigned_32;
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
      Block := Find_Best_Fit (Item, Required);
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

      Size := Block_Size (Item, Block);
      Tree_Remove (Item, Block);
      if Size - Required >= Item.Prefix_Value + Item.Minimum_Value then
         Remainder_Size := Size - Required;
         Remainder := Block + Required / Item.Minimum_Value;
         Initialize_Block
           (Item, Remainder, Remainder_Size, Required, Free_State);
         Following := Remainder + Remainder_Size / Item.Minimum_Value;
         if Following < Item.Usable_Value / Item.Minimum_Value then
            Set_Previous_Size (Item, Following, Remainder_Size);
         end if;
         Set_Block_Size (Item, Block, Required);
         Tree_Insert (Item, Remainder);
      end if;

      Counter := Counter + 1;
      Bytes.Write_U64 (Item.Counter_Address, Counter);
      Set_Generation (Item, Block, Counter);
      Set_State (Item, Block, Allocated_State);
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
   end record;

   function Validate_Handle
     (Item : View; Value : Allocation_Handle) return Block_Description
   is
      Block : constant Block_Ref := Token_Block (Value);
      Size  : Interfaces.Unsigned_32;
   begin
      Layouts.Require_Ready (Item.Core);
      if Value = Null_Allocation
        or else Token_Epoch (Value) = 0
        or else Value.Generation = 0
        or else Token_Epoch (Value) /= Item.Core.Epoch_Value
        or else not Valid_Block_Ref (Item, Block)
        or else Block_State (Item, Block) /= Allocated_State
        or else Generation (Item, Block) /= Value.Generation
      then
         raise Handle_Error with "arena allocation handle is invalid or stale";
      end if;
      Size := Block_Size (Item, Block);
      if Size < Item.Prefix_Value + Item.Minimum_Value
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
            Byte_Count (Item.Prefix_Value)));
   end Validate_Handle;

   function Next_Block (Item : View; Block : Block_Ref) return Block_Ref is
      Candidate : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Block)
        + Interfaces.Unsigned_64 (Block_Size (Item, Block) /
            Item.Minimum_Value);
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

   function Prior_Block (Item : View; Block : Block_Ref) return Block_Ref is
      Size : constant Interfaces.Unsigned_32 := Previous_Size (Item, Block);
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

   procedure Release_Unlocked (Item : View; Value : Allocation_Handle) is
      Block : Block_Ref := Token_Block (Value);
      Next, Previous, Following : Block_Ref;
      Size : Interfaces.Unsigned_32 := Block_Size (Item, Block);
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
      Set_State (Item, Block, Free_State);
      Next := Next_Block (Item, Block);
      if Next /= Null_Block and then Block_State (Item, Next) = Free_State then
         Tree_Remove (Item, Next);
         Size := Combined_Size (Size, Block_Size (Item, Next));
         Set_Block_Size (Item, Block, Size);
         Following := Next_Block (Item, Block);
         if Following /= Null_Block then
            Set_Previous_Size (Item, Following, Size);
         end if;
      end if;
      Previous := Prior_Block (Item, Block);
      if Previous /= Null_Block
        and then Block_State (Item, Previous) = Free_State
      then
         Tree_Remove (Item, Previous);
         Size := Combined_Size (Block_Size (Item, Previous), Size);
         Set_Block_Size (Item, Previous, Size);
         Following := Next_Block (Item, Previous);
         if Following /= Null_Block then
            Set_Previous_Size (Item, Following, Size);
         end if;
         Block := Previous;
      end if;
      Set_Left (Item, Block, Null_Block);
      Set_Right (Item, Block, Null_Block);
      Set_Parent (Item, Block, Null_Block);
      Set_Height (Item, Block, 1);
      Tree_Insert (Item, Block);
      Set_Live_Count (Item, Count - 1);
   end Release_Unlocked;

   procedure Release (Item : in out View; Value : Allocation_Handle) is
      Mutated : Boolean := False;
   begin
      Acquire (Item);
      begin
         declare
            Ignored : constant Block_Description :=
              Validate_Handle (Item, Value);
            pragma Unreferenced (Ignored);
         begin
            Mutated := True;
            Release_Unlocked (Item, Value);
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
            Ignored : constant Block_Description :=
              Validate_Handle (Item, Value);
            pragma Unreferenced (Ignored);
         begin
            Mutated := True;
            Release_Unlocked (Item, Value);
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
           or else Root (Item) /= 0
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

end Flyology_Allocators.Allocation_Algorithms.Best_Fit_Kernel;
