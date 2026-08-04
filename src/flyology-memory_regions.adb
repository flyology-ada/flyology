with Ada.Unchecked_Deallocate_Subpool;
with Ada.Unchecked_Deallocation;

package body Flyology.Memory_Regions is

   use type Ada.Task_Identification.Task_Id;
   use type Region_Handle;
   use type Storage.Storage_Count;

   procedure Free_Chunk is new Ada.Unchecked_Deallocation
     (Chunk, Chunk_Access);
   procedure Free_Region is new Ada.Unchecked_Deallocation
     (Region_Data, Region_Access);

   procedure Check_Owner (Pool : Task_Pool);

   function Aligned_Address
     (Address   : System.Address;
      Alignment : Storage.Storage_Count) return System.Address;

   function Fits
     (Item      : Chunk;
      Size      : Storage.Storage_Count;
      Alignment : Storage.Storage_Count) return Boolean;

   procedure Check_Owner (Pool : Task_Pool) is
   begin
      if Pool.Owner /= Ada.Task_Identification.Current_Task then
         raise Ownership_Error with
           "memory region used by a task other than its owner";
      end if;
   end Check_Owner;

   function Aligned_Address
     (Address   : System.Address;
      Alignment : Storage.Storage_Count) return System.Address
   is
      Remainder : constant Storage.Storage_Count := Address mod Alignment;
   begin
      if Remainder = 0 then
         return Address;
      end if;
      return Address + Storage.Storage_Offset (Alignment - Remainder);
   end Aligned_Address;

   function Fits
     (Item      : Chunk;
      Size      : Storage.Storage_Count;
      Alignment : Storage.Storage_Count) return Boolean
   is
      Current : constant System.Address :=
        Item.Data'Address + Storage.Storage_Offset (Item.Used);
      Aligned : constant System.Address :=
        Aligned_Address (Current, Alignment);
      Padding : constant Storage.Storage_Count :=
        Storage.Storage_Count (Aligned - Current);
   begin
      return Padding <= Storage.Storage_Count (Item.Last) - Item.Used
        and then
          Size <= Storage.Storage_Count (Item.Last) - Item.Used - Padding;
   end Fits;

   function Create_Region
     (Pool          : in out Task_Pool;
      Chunk_Storage : Storage.Storage_Count := 65_536)
      return not null Region_Handle
   is
      Result : Region_Access;
   begin
      Check_Owner (Pool);
      if Chunk_Storage = 0 then
         raise Constraint_Error with "region chunk size must be positive";
      end if;
      if Pool.Live_Count = Natural'Last then
         raise Storage_Error with "too many live memory regions";
      end if;

      Result := new Region_Data'
        (Subpools.Root_Subpool with
         First      => null,
         Chunk_Size => Chunk_Storage,
         Consumed   => 0,
         Reserved   => 0);
      begin
         Subpools.Set_Pool_Of_Subpool (Region_Handle (Result), Pool);
      exception
         when others =>
            Free_Region (Result);
            raise;
      end;
      Pool.Live_Count := Pool.Live_Count + 1;
      return Region_Handle (Result);
   end Create_Region;

   overriding function Create_Subpool
     (Pool : in out Task_Pool) return not null Region_Handle is
   begin
      return Create_Region (Pool);
   end Create_Subpool;

   overriding procedure Allocate_From_Subpool
     (Pool                     : in out Task_Pool;
      Storage_Address          : out System.Address;
      Size_In_Storage_Elements : Storage.Storage_Count;
      Alignment                : Storage.Storage_Count;
      Subpool                  : not null Region_Handle)
   is
      Item : Region_Data renames Region_Data (Subpool.all);
      Size : constant Storage.Storage_Count :=
        Storage.Storage_Count'Max (1, Size_In_Storage_Elements);
      Current  : System.Address;
      Aligned  : System.Address;
      Padding  : Storage.Storage_Count;
      Required : Storage.Storage_Count;
      Capacity : Storage.Storage_Count;
      New_Chunk : Chunk_Access;
   begin
      Check_Owner (Pool);
      if Alignment = 0 then
         raise Program_Error with "zero storage alignment";
      end if;

      if Item.First = null
        or else not Fits (Item.First.all, Size, Alignment)
      then
         if Alignment - 1 > Storage.Storage_Count'Last - Size then
            raise Storage_Error with "memory region allocation is too large";
         end if;
         Required := Size + Alignment - 1;
         Capacity := Storage.Storage_Count'Max (Item.Chunk_Size, Required);
         if Capacity > Storage.Storage_Count'Last - Item.Reserved
           or else Capacity > Storage.Storage_Count'Last - Pool.Reserved
         then
            raise Storage_Error with "memory region accounting overflow";
         end if;
         New_Chunk := new Chunk (Storage.Storage_Offset (Capacity));
         New_Chunk.Next := Item.First;
         Item.First := New_Chunk;
         Item.Reserved := Item.Reserved + Capacity;
         Pool.Reserved := Pool.Reserved + Capacity;
      end if;

      Current := Item.First.Data'Address
        + Storage.Storage_Offset (Item.First.Used);
      Aligned := Aligned_Address (Current, Alignment);
      Padding := Storage.Storage_Count (Aligned - Current);
      Item.First.Used := Item.First.Used + Padding + Size;
      Item.Consumed := Item.Consumed + Padding + Size;
      Pool.Consumed := Pool.Consumed + Padding + Size;
      Storage_Address := Aligned;
   end Allocate_From_Subpool;

   overriding procedure Deallocate_Subpool
     (Pool    : in out Task_Pool;
      Subpool : in out Region_Handle)
   is
      Item       : Region_Data renames Region_Data (Subpool.all);
      Region_Ptr : Region_Access := Item'Unchecked_Access;
      Current    : Chunk_Access := Item.First;
      Next       : Chunk_Access;
   begin
      Check_Owner (Pool);

      while Current /= null loop
         Next := Current.Next;
         Free_Chunk (Current);
         Current := Next;
      end loop;

      Pool.Live_Count := Pool.Live_Count - 1;
      Pool.Consumed := Pool.Consumed - Item.Consumed;
      Pool.Reserved := Pool.Reserved - Item.Reserved;
      Free_Region (Region_Ptr);
   end Deallocate_Subpool;

   procedure Release (Region : in out Region_Handle) is
      Owner : access Subpools.Root_Storage_Pool_With_Subpools'Class;
   begin
      if Region = null then
         return;
      end if;

      Owner := Subpools.Pool_Of_Subpool (Region);
      if Owner = null or else not (Owner.all in Task_Pool'Class) then
         raise Ownership_Error with
           "region was not created by Flyology.Memory_Regions";
      end if;
      Check_Owner (Task_Pool (Owner.all));
      Ada.Unchecked_Deallocate_Subpool (Region);
   end Release;

   function Statistics (Pool : Task_Pool) return Pool_Statistics is
   begin
      Check_Owner (Pool);
      return
        (Live_Regions     => Pool.Live_Count,
         Consumed_Storage => Pool.Consumed,
         Reserved_Storage => Pool.Reserved);
   end Statistics;

end Flyology.Memory_Regions;
