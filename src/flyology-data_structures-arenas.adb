with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Policy;
with Flyology.Data_Structures.Storage;
with Flyology.Data_Structures.Waits;
with Interfaces.C;

package body Flyology.Data_Structures.Arenas is
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Policy renames Flyology.Data_Structures.Policy;
   package Bytes renames Flyology.Data_Structures.Storage;
   package Waiting renames Flyology.Data_Structures.Waits;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type System.Address;

   Node_Table_Offset : constant Byte_Count := Layouts.Header_Size;
   Node_Entry_Size   : constant Byte_Count := 16;
   Node_State_Offset : constant Byte_Count := 0;
   Node_Reserved_Offset : constant Byte_Count := 4;
   Node_Generation_Offset : constant Byte_Count := 8;

   Guard_Offset   : constant Byte_Count := 44;
   Counter_Offset : constant Byte_Count := 56;

   Inactive_State  : constant Interfaces.Unsigned_32 := 0;
   Free_State      : constant Interfaces.Unsigned_32 := 1;
   Split_State     : constant Interfaces.Unsigned_32 := 2;
   Allocated_State : constant Interfaces.Unsigned_32 := 3;

   Unlocked : constant Interfaces.Unsigned_32 := 0;
   Locked   : constant Interfaces.Unsigned_32 := 1;

   type Geometry_Values is record
      Usable     : Interfaces.Unsigned_32;
      Minimum    : Interfaces.Unsigned_32;
      Nodes      : Interfaces.Unsigned_32;
      Data_Start : Byte_Count;
      Extent     : Byte_Count;
   end record;

   function Geometry
     (Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive) return Geometry_Values
   is
      Usable  : constant Byte_Count := Byte_Count (Usable_Capacity);
      Minimum : constant Byte_Count := Byte_Count (Minimum_Block_Size);
      Leaves  : Byte_Count;
      Nodes   : Byte_Count;
      Table_End : Byte_Count;
      Data_Start : Byte_Count;
   begin
      if Minimum < Byte_Count (Minimum_Block_Limit)
        or else not Policy.Is_Power_Of_Two (Minimum)
        or else not Policy.Is_Power_Of_Two (Usable)
        or else Usable < Minimum
        or else Usable mod Minimum /= 0
      then
         raise Constraint_Error with "invalid arena buddy geometry";
      elsif Usable > Byte_Count (Interfaces.Unsigned_32'Last)
        or else Minimum > Byte_Count (Interfaces.Unsigned_32'Last)
      then
         raise Constraint_Error with "arena geometry exceeds stored widths";
      end if;

      Leaves := Usable / Minimum;
      if not Policy.Buddy_Node_Count_Fits (Leaves) then
         raise Constraint_Error with "arena node count exceeds stored width";
      end if;
      Nodes := Byte_Count (Policy.Buddy_Node_Count (Leaves));
      Table_End := Layouts.Checked_Add
        (Node_Table_Offset, Layouts.Checked_Multiply (Nodes, Node_Entry_Size));
      Data_Start := Layouts.Align_Up (Table_End, Minimum);
      return
        (Usable     => Interfaces.Unsigned_32 (Usable),
         Minimum    => Interfaces.Unsigned_32 (Minimum),
         Nodes      => Interfaces.Unsigned_32 (Nodes),
         Data_Start => Data_Start,
         Extent     => Layouts.Checked_Add (Data_Start, Usable));
   end Geometry;

   function Required_Storage
     (Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive) return Byte_Count is
     (Geometry (Usable_Capacity, Minimum_Block_Size).Extent);

   function Node_Relative
     (Item : View; Node : Interfaces.Unsigned_32) return Byte_Count
   is
   begin
      if Node >= Item.Node_Count then
         raise Layout_Error with "arena node index is out of range";
      end if;
      return Layouts.Checked_Add
        (Node_Table_Offset,
         Layouts.Checked_Multiply (Byte_Count (Node), Node_Entry_Size));
   end Node_Relative;
   pragma Inline_Always (Node_Relative);

   function Node_Address
     (Item     : View;
      Node     : Interfaces.Unsigned_32;
      Relative : Byte_Count;
      Extent   : Byte_Count;
      Alignment : Byte_Count) return System.Address is
   begin
      if Relative > Node_Entry_Size
        or else Extent > Node_Entry_Size - Relative
      then
         raise Layout_Error with "arena node field extent is corrupt";
      end if;
      return Layouts.Address_At
        (Item.Core, Layouts.Checked_Add (Node_Relative (Item, Node), Relative),
         Extent, Alignment);
   end Node_Address;
   pragma Inline_Always (Node_Address);

   function State_Address
     (Item : View; Node : Interfaces.Unsigned_32) return System.Address is
     (Node_Address (Item, Node, Node_State_Offset, 4, 4));
   pragma Inline_Always (State_Address);

   function Generation_Address
     (Item : View; Node : Interfaces.Unsigned_32) return System.Address is
     (Node_Address (Item, Node, Node_Generation_Offset, 8, 8));
   pragma Inline_Always (Generation_Address);

   procedure Set_View
     (Item : out View;
      Core : Layouts.Local_View;
      Values : Geometry_Values;
      Instance_ID : Interfaces.Unsigned_64) is
   begin
      Item.Core := Core;
      Item.Guard_Address := Layouts.Address_At (Core, Guard_Offset, 4, 4);
      Item.Counter_Address := Layouts.Address_At
        (Core, Counter_Offset, 8, 8);
      Item.Usable_Value := Values.Usable;
      Item.Minimum_Value := Values.Minimum;
      Item.Node_Count := Values.Nodes;
      Item.Data_Offset := Values.Data_Start;
      Item.Instance_Value := Instance_ID;
   end Set_View;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Guard_Address := System.Null_Address;
      Item.Counter_Address := System.Null_Address;
      Item.Usable_Value := 0;
      Item.Minimum_Value := 0;
      Item.Node_Count := 0;
      Item.Data_Offset := 0;
      Item.Instance_Value := 0;
   end Detach;

   procedure Initialize_Nodes (Item : View) is
   begin
      for Node in Interfaces.Unsigned_32 range 0 .. Item.Node_Count - 1 loop
         Atomic.Store_Release_U32 (State_Address (Item, Node), Inactive_State);
         Bytes.Write_U32
           (Node_Address (Item, Node, Node_Reserved_Offset, 4, 4), 0);
         Bytes.Write_U64 (Generation_Address (Item, Node), 0);
      end loop;
      Atomic.Store_Release_U32 (State_Address (Item, 0), Free_State);
   end Initialize_Nodes;

   procedure Finish_Initialize
     (Item        : out View;
      Core        : Layouts.Local_View;
      Values      : Geometry_Values;
      Instance_ID : Interfaces.Unsigned_64) is
   begin
      Set_View (Item, Core, Values, Instance_ID);
      Initialize_Nodes (Item);
      Layouts.Publish (Item.Core);
   end Finish_Initialize;

   procedure Check_Instance (Instance_ID : Interfaces.Unsigned_64) is
   begin
      if Instance_ID = 0 then
         raise Constraint_Error with "arena instance identity is zero";
      end if;
   end Check_Instance;

   procedure Initialize
     (Item               : out View;
      Region             : Region_View;
      Location           : Region_Offset;
      Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive;
      Instance_ID        : Interfaces.Unsigned_64)
   is
      Values : constant Geometry_Values :=
        Geometry (Usable_Capacity, Minimum_Block_Size);
      Core : Layouts.Local_View;
   begin
      Check_Instance (Instance_ID);
      Detach (Item);
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity, Values.Extent,
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
     (Item               : out View;
      Region             : Region_View;
      Location           : Region_Offset;
      Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive;
      Instance_ID        : Interfaces.Unsigned_64;
      Result             : out Open_Result)
   is
      Values : constant Geometry_Values :=
        Geometry (Usable_Capacity, Minimum_Block_Size);
      Core  : Layouts.Local_View;
      Claim : Layouts.Initialization_Claim;
   begin
      Check_Instance (Instance_ID);
      Detach (Item);
      Layouts.Try_Begin_Initialize
        (Core, Claim, Region, Location, Identity, Values.Extent,
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
            Attach
              (Item, Region, Location, Usable_Capacity,
               Minimum_Block_Size, Instance_ID);
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

   procedure Validate_Tree (Item : View) is
      Counter : constant Interfaces.Unsigned_64 :=
        Atomic.Load_Relaxed_U64 (Item.Counter_Address);

      procedure Validate_Node
        (Node : Interfaces.Unsigned_32; Active : Boolean)
      is
         State : constant Interfaces.Unsigned_32 :=
           Atomic.Load_Acquire_U32 (State_Address (Item, Node));
         Reserved : constant Interfaces.Unsigned_32 := Bytes.Read_U32
           (Node_Address (Item, Node, Node_Reserved_Offset, 4, 4));
         Generation : constant Interfaces.Unsigned_64 :=
           Bytes.Read_U64 (Generation_Address (Item, Node));
         Left_64 : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (Node) * 2 + 1;
         Has_Children : constant Boolean :=
           Left_64 < Interfaces.Unsigned_64 (Item.Node_Count);
      begin
         if Reserved /= 0 then
            raise Layout_Error with "arena node reserved field is corrupt";
         elsif not Active then
            if State /= Inactive_State then
               raise Layout_Error with "inactive arena subtree is corrupt";
            end if;
         elsif State = Inactive_State or else State > Allocated_State then
            raise Layout_Error with "active arena node state is corrupt";
         elsif State = Split_State and then not Has_Children then
            raise Layout_Error with "arena leaf is marked split";
         elsif Generation > Counter
           or else (State = Allocated_State and then Generation = 0)
         then
            raise Layout_Error with "arena allocation generation is corrupt";
         end if;

         if Has_Children then
            declare
               Left  : constant Interfaces.Unsigned_32 :=
                 Interfaces.Unsigned_32 (Left_64);
               Right : constant Interfaces.Unsigned_32 := Left + 1;
               Children_Active : constant Boolean :=
                 Active and then State = Split_State;
            begin
               Validate_Node (Left, Children_Active);
               Validate_Node (Right, Children_Active);
            end;
         end if;
      end Validate_Node;
   begin
      if Item.Node_Count = 0 then
         raise Layout_Error with "arena has no buddy root";
      end if;
      Validate_Node (0, True);
   end Validate_Tree;

   procedure Attach
     (Item               : out View;
      Region             : Region_View;
      Location           : Region_Offset;
      Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive;
      Instance_ID        : Interfaces.Unsigned_64)
   is
      Values : constant Geometry_Values :=
        Geometry (Usable_Capacity, Minimum_Block_Size);
      Core   : Layouts.Local_View;
      Header : Layouts.Header_Values;
   begin
      Check_Instance (Instance_ID);
      Detach (Item);
      Layouts.Attach
        (Core, Header, Region, Location, Identity,
         Byte_Count (Values.Minimum));
      if Header.Capacity /= Values.Usable
        or else Header.Element_Size /= Values.Minimum
        or else Header.Alignment /= Values.Minimum
        or else Header.Word_1 /= Instance_ID
        or else Core.Extent /= Values.Extent
      then
         raise Layout_Error with "arena creation parameters do not match";
      elsif Header.Auxiliary = Locked then
         raise Busy_Error with "arena metadata guard is active";
      elsif Header.Auxiliary /= Unlocked then
         raise Layout_Error with "arena metadata guard is corrupt";
      end if;
      Set_View (Item, Core, Values, Instance_ID);
      Validate_Tree (Item);
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

   procedure Poison
     (Region : Region_View; Location : Region_Offset) is
   begin
      Layouts.Poison_At (Region, Location, Identity, 8);
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

   function Allocate_Unlocked
     (Item           : View;
      Requested_Size : Byte_Count;
      Value          : out Allocation_Handle) return Boolean
   is
      Counter : Interfaces.Unsigned_64 :=
        Atomic.Load_Relaxed_U64 (Item.Counter_Address);

      function Visit
        (Node : Interfaces.Unsigned_32;
         Block_Size : Byte_Count) return Boolean
      is
         State : constant Interfaces.Unsigned_32 :=
           Atomic.Load_Acquire_U32 (State_Address (Item, Node));
         Half : Byte_Count;
         Left_64 : Interfaces.Unsigned_64;
         Left, Right : Interfaces.Unsigned_32;
      begin
         if Requested_Size > Block_Size then
            return False;
         elsif State = Allocated_State or else State = Inactive_State then
            return False;
         elsif State = Free_State then
            if Block_Size > Byte_Count (Item.Minimum_Value)
              and then Requested_Size <= Block_Size / 2
            then
               Half := Block_Size / 2;
               Left_64 := Interfaces.Unsigned_64 (Node) * 2 + 1;
               if Left_64 + 1 >= Interfaces.Unsigned_64 (Item.Node_Count) then
                  raise Layout_Error with "arena buddy tree is truncated";
               end if;
               Left := Interfaces.Unsigned_32 (Left_64);
               Right := Left + 1;
               if Atomic.Load_Acquire_U32 (State_Address (Item, Left)) /=
                 Inactive_State
                 or else Atomic.Load_Acquire_U32
                   (State_Address (Item, Right)) /= Inactive_State
               then
                  raise Layout_Error with
                    "arena free node has an active descendant";
               end if;
               Atomic.Store_Release_U32
                 (State_Address (Item, Left), Free_State);
               Atomic.Store_Release_U32
                 (State_Address (Item, Right), Free_State);
               Atomic.Store_Release_U32
                 (State_Address (Item, Node), Split_State);
               if Visit (Left, Half) or else Visit (Right, Half) then
                  return True;
               end if;
               return False;
            end if;

            if Counter = Interfaces.Unsigned_64'Last then
               raise Layout_Error with "arena allocation generation exhausted";
            end if;
            Counter := Counter + 1;
            Bytes.Write_U64 (Item.Counter_Address, Counter);
            Bytes.Write_U64 (Generation_Address (Item, Node), Counter);
            Atomic.Store_Release_U32
              (State_Address (Item, Node), Allocated_State);
            Value :=
              (Node        => Node,
               Arena_Epoch => Item.Core.Epoch_Value,
               Generation  => Counter);
            return True;
         elsif State = Split_State then
            Half := Block_Size / 2;
            Left_64 := Interfaces.Unsigned_64 (Node) * 2 + 1;
            if Left_64 + 1 >= Interfaces.Unsigned_64 (Item.Node_Count) then
               raise Layout_Error with "arena split node has no children";
            end if;
            Left := Interfaces.Unsigned_32 (Left_64);
            Right := Left + 1;
            return Visit (Left, Half) or else Visit (Right, Half);
         else
            raise Layout_Error with "arena node state is corrupt";
         end if;
      end Visit;
   begin
      Value := Null_Allocation;
      if Requested_Size > Byte_Count (Item.Usable_Value) then
         return False;
      end if;
      return Visit (0, Byte_Count (Item.Usable_Value));
   end Allocate_Unlocked;

   procedure Try_Allocate
     (Item           : in out View;
      Requested_Size : Positive;
      Value          : out Allocation_Handle;
      Result         : out Allocation_Result)
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
     (Item           : in out View;
      Requested_Size : Positive;
      Timeout        : Wait_Timeout;
      Value          : out Allocation_Handle;
      Result         : out Allocation_Result)
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

   function Describe_Node
     (Item : View; Node : Interfaces.Unsigned_32) return Block_Description
   is
      Level_First : Interfaces.Unsigned_64 := 0;
      Level_Count : Interfaces.Unsigned_64 := 1;
      Index       : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Node);
      Capacity    : Byte_Count := Byte_Count (Item.Usable_Value);
   begin
      if Node >= Item.Node_Count then
         raise Handle_Error with "arena handle node is out of range";
      end if;
      while Index >= Level_First + Level_Count loop
         Level_First := Level_First + Level_Count;
         Level_Count := Level_Count * 2;
         Capacity := Capacity / 2;
      end loop;
      return
        (Capacity => Capacity,
         Offset   => Byte_Count (Index - Level_First) * Capacity);
   end Describe_Node;
   pragma Inline_Always (Describe_Node);

   function Validate_Handle
     (Item : View; Value : Allocation_Handle) return Block_Description
   is
      State : Interfaces.Unsigned_32;
      Stored_Generation : Interfaces.Unsigned_64;
   begin
      Layouts.Require_Ready (Item.Core);
      if Value = Null_Allocation
        or else Value.Arena_Epoch = 0
        or else Value.Generation = 0
        or else Value.Arena_Epoch /= Item.Core.Epoch_Value
        or else Value.Node >= Item.Node_Count
      then
         raise Handle_Error with "arena allocation handle is invalid or stale";
      end if;
      State := Atomic.Load_Acquire_U32 (State_Address (Item, Value.Node));
      Stored_Generation := Bytes.Read_U64
        (Generation_Address (Item, Value.Node));
      if State /= Allocated_State
        or else Stored_Generation /= Value.Generation
      then
         raise Handle_Error with
           "arena allocation handle is reclaimed or stale";
      end if;
      return Describe_Node (Item, Value.Node);
   end Validate_Handle;

   procedure Release_Unlocked
     (Item : View; Value : Allocation_Handle)
   is
      Ignored : constant Block_Description := Validate_Handle (Item, Value);
      pragma Unreferenced (Ignored);
      Node : Interfaces.Unsigned_32 := Value.Node;
      Parent, Buddy : Interfaces.Unsigned_32;
   begin
      Atomic.Store_Release_U32 (State_Address (Item, Node), Free_State);
      while Node /= 0 loop
         if Node not in Policy.Non_Root_Node then
            raise Layout_Error with "arena buddy node cannot be coalesced";
         end if;
         Parent := Policy.Buddy_Parent (Policy.Non_Root_Node (Node));
         Buddy := Policy.Buddy_Sibling (Policy.Non_Root_Node (Node));
         exit when Atomic.Load_Acquire_U32 (State_Address (Item, Parent)) /=
           Split_State;
         exit when Atomic.Load_Acquire_U32 (State_Address (Item, Buddy)) /=
           Free_State;
         Atomic.Store_Release_U32
           (State_Address (Item, Node), Inactive_State);
         Atomic.Store_Release_U32
           (State_Address (Item, Buddy), Inactive_State);
         Atomic.Store_Release_U32
           (State_Address (Item, Parent), Free_State);
         Node := Parent;
      end loop;
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
     (Item    : in out View;
      Value   : Allocation_Handle;
      Timeout : Wait_Timeout)
   is
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
     (Region : in out Region_View;
      Item   : View;
      Value  : Allocation_Handle)
   is
      Description : Block_Description;
   begin
      Region.Base := System.Null_Address;
      Region.Length_Value := 0;
      Region.Attached := False;
      Description := Validate_Handle (Item, Value);
      Region.Base := Layouts.Address_At
        (Item.Core, Layouts.Checked_Add
           (Item.Data_Offset, Description.Offset),
         Description.Capacity, 1);
      Region.Length_Value := Description.Capacity;
      Region.Attached := True;
   end Attach_Allocation;

   function Payload_Address
     (Item        : View;
      Description : Block_Description;
      Offset      : Byte_Count;
      Extent      : Byte_Count) return System.Address
   is
      Relative : Byte_Count;
   begin
      if Offset > Description.Capacity
        or else Extent > Description.Capacity - Offset
      then
         raise Constraint_Error with
           "arena allocation slice is out of bounds";
      elsif Extent = 0 then
         raise Constraint_Error with "zero-sized arena slice has no address";
      end if;
      Relative := Layouts.Checked_Add
        (Item.Data_Offset, Layouts.Checked_Add (Description.Offset, Offset));
      return Layouts.Address_At (Item.Core, Relative, Extent, 1);
   end Payload_Address;

   procedure Read
     (Item   : View;
      Value  : Allocation_Handle;
      Offset : Byte_Count;
      Data   : out Ada.Streams.Stream_Element_Array)
   is
      Description : constant Block_Description :=
        Validate_Handle (Item, Value);
      Length : constant Byte_Count := Byte_Count (Data'Length);
      Native_Length : Interfaces.C.size_t;
   begin
      if Offset > Description.Capacity
        or else Length > Description.Capacity - Offset
      then
         raise Constraint_Error with "arena read is out of bounds";
      elsif Length /= 0 then
         Native_Length := Interfaces.C.size_t (Length);
         if Byte_Count (Native_Length) /= Length then
            raise Constraint_Error with
              "arena read is not natively representable";
         end if;
         Bytes.Copy
           (Data'Address, Payload_Address (Item, Description, Offset, Length),
            Native_Length);
      end if;
   end Read;

   procedure Write
     (Item   : View;
      Value  : Allocation_Handle;
      Offset : Byte_Count;
      Data   : Ada.Streams.Stream_Element_Array)
   is
      Description : constant Block_Description :=
        Validate_Handle (Item, Value);
      Length : constant Byte_Count := Byte_Count (Data'Length);
      Native_Length : Interfaces.C.size_t;
   begin
      if Offset > Description.Capacity
        or else Length > Description.Capacity - Offset
      then
         raise Constraint_Error with "arena write is out of bounds";
      elsif Length /= 0 then
         Native_Length := Interfaces.C.size_t (Length);
         if Byte_Count (Native_Length) /= Length then
            raise Constraint_Error with
              "arena write is not natively representable";
         end if;
         Bytes.Copy
           (Payload_Address (Item, Description, Offset, Length), Data'Address,
            Native_Length);
      end if;
   end Write;

   procedure Copy
     (Item          : View;
      Source        : Allocation_Handle;
      Source_Offset : Byte_Count;
      Target        : Allocation_Handle;
      Target_Offset : Byte_Count;
      Length        : Byte_Count)
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
         Validate_Tree (Item);
         if Atomic.Load_Acquire_U32 (State_Address (Item, 0)) /=
           Free_State
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

end Flyology.Data_Structures.Arenas;
