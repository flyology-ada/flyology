with Flyology_Allocators.Storage;
with Interfaces;
with System;
with System.Storage_Elements;

package body Flyology_Allocators.Allocation_Algorithms.TLSF_Kernel.Testing is
   package Support renames Allocator_Refinement_Support;
   package Bytes renames Flyology_Allocators.Storage;
   package Native renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Native.Storage_Offset;
   use type System.Address;

   First_Level_Count       : constant := 32;
   Second_Level_Count      : constant := 16;
   Null_Block              : constant Interfaces.Unsigned_32 :=
     Interfaces.Unsigned_32'Last;
   Block_Size_Offset       : constant Byte_Count := 0;
   Previous_Size_Offset    : constant Byte_Count := 4;
   Generation_Offset       : constant Byte_Count := 8;
   Block_State_Offset      : constant Byte_Count := 16;
   Next_Free_Offset        : constant Byte_Count := 20;
   Free_State              : constant Interfaces.Unsigned_32 := 1;
   Allocated_State         : constant Interfaces.Unsigned_32 := 2;

   function Field_Address
     (Item : View; Block : Interfaces.Unsigned_32; Relative : Byte_Count)
      return System.Address is
     (Item.Data_Base
      + Native.Storage_Offset
          (Byte_Count (Block) * Byte_Count (Item.Minimum_Value) + Relative));

   function Read_U32
     (Item : View; Block : Interfaces.Unsigned_32; Relative : Byte_Count)
      return Interfaces.Unsigned_32 is
     (Bytes.Read_U32 (Field_Address (Item, Block, Relative)));

   procedure Capture
     (Item  : View;
      Value : out Support.Snapshot)
   is
      Block      : Interfaces.Unsigned_32 := 0;
      Previous   : Interfaces.Unsigned_32 := 0;
      Size_Bytes : Interfaces.Unsigned_32;
      State      : Interfaces.Unsigned_32;
      Stored_Generation : Interfaces.Unsigned_64;
      Cursor     : Interfaces.Unsigned_32;
   begin
      Value := (others => <>);
      Value.Generation := Bytes.Read_U64 (Item.Counter_Address);
      Value.First_Map := Bytes.Read_U32 (Item.First_Map_Address);
      for First in Value.Second_Maps'Range loop
         Value.Second_Maps (First) := Bytes.Read_U32
           (Item.Second_Maps_Base + Native.Storage_Offset (First * 4));
      end loop;
      while Block < Item.Usable_Value / Item.Minimum_Value loop
         if Value.Block_Count = Support.Max_Blocks then
            raise Program_Error with "TLSF refinement snapshot is full";
         end if;
         Size_Bytes := Read_U32 (Item, Block, Block_Size_Offset);
         if Size_Bytes < Item.Prefix_Value + Item.Minimum_Value
           or else Size_Bytes mod Item.Minimum_Value /= 0
           or else Size_Bytes / Item.Minimum_Value >
             Item.Usable_Value / Item.Minimum_Value - Block
           or else Read_U32 (Item, Block, Previous_Size_Offset) /= Previous
         then
            raise Program_Error with
              "TLSF refinement physical chain is invalid";
         end if;
         State := Read_U32 (Item, Block, Block_State_Offset);
         Stored_Generation := Bytes.Read_U64
           (Field_Address (Item, Block, Generation_Offset));
         if Stored_Generation > Value.Generation
           or else (State = Allocated_State and then Stored_Generation = 0)
         then
            raise Program_Error with
              "TLSF refinement generation is invalid";
         end if;
         Value.Block_Count := Value.Block_Count + 1;
         Value.Blocks (Value.Block_Count) :=
           (Token      => Block,
            Start      => Natural (Block),
            Size       => Positive (Size_Bytes / Item.Minimum_Value),
            State      =>
              (if State = Free_State then Support.Free_Block
               elsif State = Allocated_State then Support.Allocated_Block
               else raise Program_Error with
                 "TLSF refinement block state is invalid"),
            Generation =>
              (if State = Allocated_State
               then Stored_Generation
               else 0));
         Previous := Size_Bytes;
         Block := Block + Size_Bytes / Item.Minimum_Value;
      end loop;

      for First in 0 .. First_Level_Count - 1 loop
         for Second in 0 .. Second_Level_Count - 1 loop
            Cursor := Bytes.Read_U32
              (Item.Heads_Base
               + Native.Storage_Offset
                   ((First * Second_Level_Count + Second) * 4));
            while Cursor /= Null_Block loop
               if Cursor >= Item.Usable_Value / Item.Minimum_Value then
                  raise Program_Error with
                    "TLSF refinement index is out of range";
               end if;
               if Value.Index_Count = Support.Max_Blocks then
                  raise Program_Error with "TLSF refinement index is full";
               end if;
               Value.Index_Count := Value.Index_Count + 1;
               Value.Index (Value.Index_Count) :=
                 (Start        => Natural (Cursor),
                  Size         => Positive
                    (Read_U32 (Item, Cursor, Block_Size_Offset) /
                     Item.Minimum_Value),
                  Class_First  => First,
                  Class_Second => Second);
               Cursor := Read_U32 (Item, Cursor, Next_Free_Offset);
            end loop;
         end loop;
      end loop;
   end Capture;
end Flyology_Allocators.Allocation_Algorithms.TLSF_Kernel.Testing;
