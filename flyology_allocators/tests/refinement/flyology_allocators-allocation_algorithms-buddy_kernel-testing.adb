with Flyology_Allocators.Storage;
with Interfaces;
with System;
with System.Storage_Elements;

package body Flyology_Allocators.Allocation_Algorithms.Buddy_Kernel.Testing is
   package Support renames Allocator_Refinement_Support;
   package Bytes renames Flyology_Allocators.Storage;
   package Native renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Native.Storage_Offset;
   use type Support.Canonical_Block_State;
   use type System.Address;

   Node_Entry_Size        : constant Byte_Count := 16;
   Node_State_Offset      : constant Byte_Count := 0;
   Node_Generation_Offset : constant Byte_Count := 8;

   Inactive_State  : constant Interfaces.Unsigned_32 := 0;
   Free_State      : constant Interfaces.Unsigned_32 := 1;
   Split_State     : constant Interfaces.Unsigned_32 := 2;
   Allocated_State : constant Interfaces.Unsigned_32 := 3;

   function Node_Address
     (Item : View; Node : Interfaces.Unsigned_32; Relative : Byte_Count) return System.Address
   is (Item.Node_Table_Address + Native.Storage_Offset (Byte_Count (Node) * Node_Entry_Size + Relative));

   function Node_Start (Item : View; Node : Interfaces.Unsigned_32) return Natural is
      First_At_Level : Interfaces.Unsigned_32 := 0;
      Nodes_At_Level : Interfaces.Unsigned_32 := 1;
      Size           : Natural := Natural (Item.Usable_Value / Item.Minimum_Value);
   begin
      while Node >= First_At_Level + Nodes_At_Level loop
         First_At_Level := First_At_Level + Nodes_At_Level;
         Nodes_At_Level := Nodes_At_Level * 2;
         Size := Size / 2;
      end loop;
      return Natural (Node - First_At_Level) * Size;
   end Node_Start;

   procedure Capture (Item : View; Value : out Support.Snapshot) is
      procedure Append_Block
        (Node       : Interfaces.Unsigned_32;
         Start      : Natural;
         Size       : Positive;
         State      : Support.Canonical_Block_State;
         Generation : Interfaces.Unsigned_64) is
      begin
         if Value.Block_Count = Support.Max_Blocks then
            raise Program_Error with "buddy refinement snapshot is full";
         end if;
         Value.Block_Count := Value.Block_Count + 1;
         Value.Blocks (Value.Block_Count) :=
           (Token => Node, Start => Start, Size => Size, State => State, Generation => Generation);
         if State = Support.Free_Block then
            Value.Index_Count := Value.Index_Count + 1;
            Value.Index (Value.Index_Count) :=
              (Start => Start, Size => Size, Class_First => -1, Class_Second => -1);
         end if;
      end Append_Block;

      procedure Visit (Node : Interfaces.Unsigned_32; Start : Natural; Size : Positive) is
         State             : Interfaces.Unsigned_32;
         Stored_Generation : Interfaces.Unsigned_64;
         Left              : Interfaces.Unsigned_32;
      begin
         if Node >= Item.Node_Count then
            raise Program_Error with "buddy refinement tree is out of range";
         end if;
         State := Bytes.Read_U32 (Node_Address (Item, Node, Node_State_Offset));
         Stored_Generation := Bytes.Read_U64 (Node_Address (Item, Node, Node_Generation_Offset));
         if Stored_Generation > Value.Generation
           or else (State = Allocated_State and then Stored_Generation = 0)
         then
            raise Program_Error with "buddy refinement generation is invalid";
         end if;
         case State is
            when Free_State      =>
               Append_Block (Node, Start, Size, Support.Free_Block, 0);

            when Allocated_State =>
               Append_Block (Node, Start, Size, Support.Allocated_Block, Stored_Generation);

            when Split_State     =>
               if Size = 1 then
                  raise Program_Error with "buddy refinement leaf is split";
               end if;
               Left := Node * 2 + 1;
               Visit (Left, Start, Size / 2);
               Visit (Left + 1, Start + Size / 2, Size / 2);

            when Inactive_State  =>
               raise Program_Error with "active buddy refinement node is inactive";

            when others          =>
               raise Program_Error with "buddy refinement node state is invalid";
         end case;
      end Visit;
   begin
      Value := (others => <>);
      Value.Generation := Bytes.Read_U64 (Item.Counter_Address);
      Visit (0, 0, Positive (Item.Usable_Value / Item.Minimum_Value));
   end Capture;

   procedure Capture_Hints (Item : View; Value : out Support.Hint_Array) is
      Size  : Positive := 1;
      Order : Natural := 0;
      Node  : Interfaces.Unsigned_32;
   begin
      Value := Support.Empty_Hints;
      while Size <= Value'Last loop
         Node := Item.Cached_Nodes (Order);
         if Node /= No_Cached_Node then
            Value (Size) := Node_Start (Item, Node);
         end if;
         exit when Size > Value'Last / 2;
         Size := Size * 2;
         Order := Order + 1;
      end loop;
   end Capture_Hints;

   function Handle_Start (Item : View; Value : Allocation_Handle) return Natural
   is (Node_Start
         (Item,
          Interfaces.Unsigned_32 (Value.Token and Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last))));
end Flyology_Allocators.Allocation_Algorithms.Buddy_Kernel.Testing;
