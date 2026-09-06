with Flyology.Adaptive_Pool_Test_Hooks;
with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Slab_Pools.Validation;
with Flyology.Data_Structures.Storage;

package body Flyology.Data_Structures.Allocation_Pools.Adaptive is
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Bytes renames Flyology.Data_Structures.Storage;
   package Regions renames Flyology.Data_Structures.Regions;
   package Chunk_Validation is new Chunk_Slabs.Validation;

   use type Arena_Provider.Allocation_Handle;
   use type Chunk_Slabs.Allocation_Result;
   use type Handles.Generation;
   use type Handles.Slot_Index;
   use type Interfaces.Unsigned_32;
   use type System.Address;

   Table_Offset      : constant Byte_Count := Layouts.Header_Size;
   Entry_Size        : constant Byte_Count := 24;
   Token_Offset      : constant Byte_Count := 0;
   Generation_Offset : constant Byte_Count := 8;
   State_Offset      : constant Byte_Count := 16;
   Reserved_Offset   : constant Byte_Count := 20;
   Guard_Offset      : constant Byte_Count := 44;

   Empty_State        : constant Interfaces.Unsigned_32 := 0;
   Initializing_State : constant Interfaces.Unsigned_32 := 1;
   Live_State         : constant Interfaces.Unsigned_32 := 2;
   Unlocked           : constant Interfaces.Unsigned_32 := 0;
   Locked             : constant Interfaces.Unsigned_32 := 1;

   Chunk_Location : constant Region_Offset := Region_Offset (Minimum_Arena_Alignment);

   function Has_Compatible_Alignment (Arena_Metadata : Arena_Provider.Metadata) return Boolean
   is (Byte_Count (Arena_Metadata.Minimum_Block_Size) >= Minimum_Arena_Alignment);

   procedure Require_Creation_Alignment (Arena_Metadata : Arena_Provider.Metadata) is
   begin
      if not Has_Compatible_Alignment (Arena_Metadata) then
         raise Constraint_Error with "adaptive pool requires 64-byte arena allocation alignment";
      end if;
   end Require_Creation_Alignment;

   function Chunk_Storage return Byte_Count
   is (Layouts.Checked_Add (Byte_Count (Chunk_Location), Chunk_Slabs.Required_Storage (Slots_Per_Chunk)));

   function Required_Storage return Byte_Count is
   begin
      return
        Layouts.Align_Up
          (Layouts.Checked_Add
             (Table_Offset, Layouts.Checked_Multiply (Byte_Count (Maximum_Chunks), Entry_Size)),
           8);
   end Required_Storage;

   function Entry_Address
     (Item : View; Index : Positive; Relative : Byte_Count; Extent : Byte_Count; Alignment : Byte_Count)
      return System.Address is
   begin
      if Index > Maximum_Chunks or else Relative > Entry_Size or else Extent > Entry_Size - Relative then
         raise Layout_Error with "adaptive-pool chunk index is corrupt";
      end if;
      return
        Layouts.Address_At
          (Item.Core,
           Layouts.Checked_Add
             (Table_Offset,
              Layouts.Checked_Add (Layouts.Checked_Multiply (Byte_Count (Index - 1), Entry_Size), Relative)),
           Extent,
           Alignment);
   end Entry_Address;

   function Entry_State (Item : View; Index : Positive) return Interfaces.Unsigned_32
   is (Atomic.Load_Acquire_U32 (Entry_Address (Item, Index, State_Offset, 4, 4)));

   procedure Set_Entry_State (Item : View; Index : Positive; State : Interfaces.Unsigned_32) is
   begin
      Atomic.Store_Release_U32 (Entry_Address (Item, Index, State_Offset, 4, 4), State);
   end Set_Entry_State;

   function Entry_Allocation (Item : View; Index : Positive) return Arena_Provider.Allocation_Handle
   is ((Token      => Bytes.Read_U64 (Entry_Address (Item, Index, Token_Offset, 8, 8)),
        Generation => Bytes.Read_U64 (Entry_Address (Item, Index, Generation_Offset, 8, 8))));

   procedure Set_Entry_Allocation (Item : View; Index : Positive; Value : Arena_Provider.Allocation_Handle) is
   begin
      Bytes.Write_U64 (Entry_Address (Item, Index, Token_Offset, 8, 8), Value.Token);
      Bytes.Write_U64 (Entry_Address (Item, Index, Generation_Offset, 8, 8), Value.Generation);
   end Set_Entry_Allocation;

   procedure Clear_Cache (Item : in out View; Index : Positive) is
   begin
      if Chunk_Slabs.Is_Attached (Item.Chunks (Index).Slab) then
         Chunk_Slabs.Detach (Item.Chunks (Index).Slab);
      end if;
      if Regions.Is_Attached (Item.Chunks (Index).Region) then
         Regions.Detach (Item.Chunks (Index).Region);
      end if;
      Item.Chunks (Index).Allocation := Arena_Provider.Null_Allocation;
   end Clear_Cache;

   procedure Detach (Item : in out View) is
   begin
      for Index in Item.Chunks'Range loop
         Clear_Cache (Item, Index);
      end loop;
      Layouts.Detach (Item.Core);
      Item.Guard_Address := System.Null_Address;
      Item.Arena_Instance := 0;
      Item.Arena_Epoch := 0;
   end Detach;

   procedure Set_View (Item : out View; Core : Layouts.Local_View; Arena_Metadata : Arena_Provider.Metadata)
   is
   begin
      Item.Core := Core;
      Item.Guard_Address := Layouts.Address_At (Core, Guard_Offset, 4, 4);
      Item.Arena_Instance := Arena_Metadata.Instance_ID;
      Item.Arena_Epoch := Arena_Metadata.Incarnation;
   end Set_View;

   procedure Finish_Initialize
     (Item : out View; Core : Layouts.Local_View; Arena_Metadata : Arena_Provider.Metadata) is
   begin
      Set_View (Item, Core, Arena_Metadata);
      for Index in 1 .. Maximum_Chunks loop
         Set_Entry_Allocation (Item, Index, Arena_Provider.Null_Allocation);
         Bytes.Write_U32 (Entry_Address (Item, Index, Reserved_Offset, 4, 4), 0);
         Set_Entry_State (Item, Index, Empty_State);
      end loop;
      Layouts.Publish (Item.Core);
   end Finish_Initialize;

   procedure Initialize
     (Item : out View; Region : Region_View; Location : Region_Offset; Arena : Arena_Provider.View)
   is
      Arena_Metadata : Arena_Provider.Metadata;
      Core           : Layouts.Local_View;
   begin
      Detach (Item);
      Arena_Metadata := Arena_Provider.Current_Metadata (Arena);
      Require_Creation_Alignment (Arena_Metadata);
      Layouts.Begin_Initialize
        (Core,
         Region,
         Location,
         Identity,
         Required_Storage,
         (Capacity     => Interfaces.Unsigned_32 (Maximum_Chunks),
          Element_Size => Interfaces.Unsigned_32 (Element.Size),
          Alignment    => Interfaces.Unsigned_32 (Element.Alignment),
          Auxiliary    => Unlocked,
          Word_1       => Arena_Metadata.Instance_ID,
          Word_2       => Interfaces.Unsigned_64 (Arena_Metadata.Incarnation)),
         64);
      Finish_Initialize (Item, Core, Arena_Metadata);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Initialize;

   procedure Ensure_Chunk (Item : in out View; Arena : Arena_Provider.View; Index : Positive) is
      Allocation : Arena_Provider.Allocation_Handle;
   begin
      if Entry_State (Item, Index) /= Live_State then
         raise Handle_Error with "adaptive-pool chunk is not live";
      end if;
      Allocation := Entry_Allocation (Item, Index);
      if Allocation = Arena_Provider.Null_Allocation then
         raise Layout_Error with "adaptive-pool live chunk has no allocation";
      end if;
      if Item.Chunks (Index).Allocation = Allocation
        and then Chunk_Slabs.Is_Attached (Item.Chunks (Index).Slab)
      then
         return;
      end if;
      Clear_Cache (Item, Index);
      Arena_Provider.Attach_Allocation (Item.Chunks (Index).Region, Arena, Allocation);
      begin
         Chunk_Slabs.Attach
           (Item.Chunks (Index).Slab, Item.Chunks (Index).Region, Chunk_Location, Slots_Per_Chunk);
         Item.Chunks (Index).Allocation := Allocation;
      exception
         when others =>
            Clear_Cache (Item, Index);
            raise;
      end;
   end Ensure_Chunk;

   procedure Validate_Table (Item : in out View; Arena : Arena_Provider.View) is
   begin
      for Index in 1 .. Maximum_Chunks loop
         if Bytes.Read_U32 (Entry_Address (Item, Index, Reserved_Offset, 4, 4)) /= 0 then
            raise Layout_Error with "adaptive-pool chunk reserved field is corrupt";
         end if;
         case Entry_State (Item, Index) is
            when Empty_State        =>
               if Entry_Allocation (Item, Index) /= Arena_Provider.Null_Allocation then
                  raise Layout_Error with "adaptive-pool empty chunk retains an allocation";
               end if;

            when Live_State         =>
               Ensure_Chunk (Item, Arena, Index);

            when Initializing_State =>
               raise Layout_Error with "adaptive-pool chunk initialization is incomplete";

            when others             =>
               raise Layout_Error with "adaptive-pool chunk state is corrupt";
         end case;
      end loop;
   end Validate_Table;

   procedure Attach
     (Item : out View; Region : Region_View; Location : Region_Offset; Arena : Arena_Provider.View)
   is
      Arena_Metadata : Arena_Provider.Metadata;
      Core           : Layouts.Local_View;
      Header         : Layouts.Header_Values;
   begin
      Detach (Item);
      Arena_Metadata := Arena_Provider.Current_Metadata (Arena);
      if not Has_Compatible_Alignment (Arena_Metadata) then
         raise Layout_Error with "adaptive pool requires 64-byte arena allocation alignment";
      end if;
      Layouts.Attach (Core, Header, Region, Location, Identity, 64);
      if Header.Capacity /= Interfaces.Unsigned_32 (Maximum_Chunks)
        or else Header.Element_Size /= Interfaces.Unsigned_32 (Element.Size)
        or else Header.Alignment /= Interfaces.Unsigned_32 (Element.Alignment)
        or else Header.Word_1 /= Arena_Metadata.Instance_ID
        or else Header.Word_2 /= Interfaces.Unsigned_64 (Arena_Metadata.Incarnation)
        or else Core.Extent /= Required_Storage
      then
         raise Layout_Error with "adaptive-pool creation parameters do not match";
      elsif Header.Auxiliary = Locked then
         raise Busy_Error with "adaptive-pool chunk creation is active";
      elsif Header.Auxiliary /= Unlocked then
         raise Layout_Error with "adaptive-pool guard is corrupt";
      end if;
      Set_View (Item, Core, Arena_Metadata);
      Validate_Table (Item, Arena);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Attach;

   procedure Create_Or_Attach
     (Item     : out View;
      Region   : Region_View;
      Location : Region_Offset;
      Arena    : Arena_Provider.View;
      Result   : out Open_Result)
   is
      Arena_Metadata : Arena_Provider.Metadata;
      Core           : Layouts.Local_View;
      Claim          : Layouts.Initialization_Claim;
   begin
      Detach (Item);
      Arena_Metadata := Arena_Provider.Current_Metadata (Arena);
      Require_Creation_Alignment (Arena_Metadata);
      Layouts.Try_Begin_Initialize
        (Core,
         Claim,
         Region,
         Location,
         Identity,
         Required_Storage,
         (Capacity     => Interfaces.Unsigned_32 (Maximum_Chunks),
          Element_Size => Interfaces.Unsigned_32 (Element.Size),
          Alignment    => Interfaces.Unsigned_32 (Element.Alignment),
          Auxiliary    => Unlocked,
          Word_1       => Arena_Metadata.Instance_ID,
          Word_2       => Interfaces.Unsigned_64 (Arena_Metadata.Incarnation)),
         64);
      case Claim is
         when Layouts.Claimed_Virgin    =>
            Finish_Initialize (Item, Core, Arena_Metadata);
            Result := Initialized_New;

         when Layouts.Existing_Ready    =>
            Attach (Item, Region, Location, Arena);
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

   function Is_Attached (Item : View) return Boolean
   is (Item.Core.Attached);

   procedure Poison (Region : Region_View; Location : Region_Offset) is
   begin
      Layouts.Poison_At (Region, Location, Identity, 64);
   end Poison;

   --  Reject an arena that is not the exact instance and incarnation this view
   --  attached to. Chunk allocation handles and the process-local chunk caches
   --  are meaningful only for that arena, and a reinitialized arena reuses its
   --  blocks for unrelated storage.
   procedure Require_Arena (Item : View; Arena : Arena_Provider.View) is
      Arena_Metadata : constant Arena_Provider.Metadata := Arena_Provider.Current_Metadata (Arena);
   begin
      if Arena_Metadata.Instance_ID /= Item.Arena_Instance
        or else Arena_Metadata.Incarnation /= Item.Arena_Epoch
      then
         raise Layout_Error with "adaptive pool is attached to another arena incarnation";
      end if;
   end Require_Arena;

   procedure Acquire (Item : View) is
      Expected : Interfaces.Unsigned_32 := Unlocked;
   begin
      if not Item.Core.Attached or else Item.Guard_Address = System.Null_Address then
         raise Region_Error with "detached adaptive-pool view";
      elsif not Atomic.Compare_Exchange_U32 (Item.Guard_Address, Expected, Locked) then
         Layouts.Require_Ready (Item.Core);
         if Expected = Locked then
            raise Busy_Error with "adaptive-pool chunk creation is busy";
         end if;
         raise Layout_Error with "adaptive-pool guard is corrupt";
      end if;
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

   procedure Try_Existing
     (Item   : in out View;
      Arena  : Arena_Provider.View;
      Data   : Element.Source;
      Value  : out Handle;
      Result : out Allocation_Result)
   is
      Slab_Handle    : Handles.Handle;
      Slab_Result    : Chunk_Slabs.Allocation_Result;
      Saw_Contention : Boolean := False;
   begin
      Value := Null_Handle;
      for Index in 1 .. Maximum_Chunks loop
         if Entry_State (Item, Index) = Live_State then
            Ensure_Chunk (Item, Arena, Index);
            Chunk_Slabs.Try_Allocate (Item.Chunks (Index).Slab, Data, Slab_Handle, Slab_Result);
            case Slab_Result is
               when Chunk_Slabs.Allocated            =>
                  Value :=
                    (Chunk => Interfaces.Unsigned_32 (Index),
                     Slot  => Slab_Handle.Slot,
                     Stamp => Slab_Handle.Stamp,
                     Epoch => Item.Core.Epoch_Value);
                  Result := Allocated;
                  return;

               when Chunk_Slabs.Allocation_Contended =>
                  Saw_Contention := True;

               when Chunk_Slabs.Exhausted            =>
                  null;
            end case;
         end if;
      end loop;
      Result := (if Saw_Contention then Allocation_Contended else Exhausted);
   end Try_Existing;

   procedure Try_Allocate
     (Item   : in out View;
      Arena  : in out Arena_Provider.View;
      Data   : Element.Source;
      Value  : out Handle;
      Result : out Allocation_Result)
   is
      Allocation   : Arena_Provider.Allocation_Handle;
      Arena_Result : Arena_Provider.Allocation_Result;
      Slab_Handle  : Handles.Handle;
      Slab_Result  : Chunk_Slabs.Allocation_Result;
      Empty_Index  : Natural := 0;
      Mutated      : Boolean := False;
   begin
      Layouts.Require_Ready (Item.Core);
      Require_Arena (Item, Arena);
      Try_Existing (Item, Arena, Data, Value, Result);
      if Result = Allocated or else Result = Allocation_Contended then
         return;
      end if;
      begin
         Acquire (Item);
      exception
         when Busy_Error =>
            Result := Allocation_Contended;
            return;
      end;
      begin
         --  A competing creator may have published a chunk after the first
         --  lock-free scan and before this call acquired the growth guard.
         --  Prefer that chunk instead of consuming another arena allocation.
         Try_Existing (Item, Arena, Data, Value, Result);
         if Result = Allocated or else Result = Allocation_Contended then
            Release_Guard (Item);
            return;
         end if;
         for Index in 1 .. Maximum_Chunks loop
            if Entry_State (Item, Index) = Empty_State then
               Empty_Index := Index;
               exit;
            end if;
         end loop;
         if Empty_Index = 0 then
            Release_Guard (Item);
            Result := Exhausted;
            return;
         end if;
         Arena_Provider.Try_Allocate (Arena, Positive (Chunk_Storage), Allocation, Arena_Result);
         case Arena_Result is
            when Arena_Provider.Allocation_Contended =>
               Release_Guard (Item);
               Result := Allocation_Contended;
               return;

            when Arena_Provider.Exhausted            =>
               Release_Guard (Item);
               Result := Arena_Exhausted;
               return;

            when Arena_Provider.Allocated            =>
               null;
         end case;
         Mutated := True;
         Set_Entry_Allocation (Item, Empty_Index, Allocation);
         Set_Entry_State (Item, Empty_Index, Initializing_State);
         Arena_Provider.Attach_Allocation (Item.Chunks (Empty_Index).Region, Arena, Allocation);
         Chunk_Slabs.Initialize
           (Item.Chunks (Empty_Index).Slab,
            Item.Chunks (Empty_Index).Region,
            Chunk_Location,
            Slots_Per_Chunk);
         Item.Chunks (Empty_Index).Allocation := Allocation;
         Chunk_Slabs.Try_Allocate (Item.Chunks (Empty_Index).Slab, Data, Slab_Handle, Slab_Result);
         if Slab_Result /= Chunk_Slabs.Allocated then
            raise Layout_Error with "new adaptive-pool chunk did not provide its first slot";
         end if;
         Set_Entry_State (Item, Empty_Index, Live_State);
         if Flyology.Adaptive_Pool_Test_Hooks.Enabled then
            Flyology.Adaptive_Pool_Test_Hooks.Record_Chunk_State (Empty_Index, Live => True);
         end if;
      exception
         when others =>
            begin
               if Mutated then
                  Layouts.Poison (Item.Core);
               end if;
            exception
               when others =>
                  Release_Guard (Item);
                  raise;
            end;
            Release_Guard (Item);
            raise;
      end;
      Release_Guard (Item);
      Value :=
        (Chunk => Interfaces.Unsigned_32 (Empty_Index),
         Slot  => Slab_Handle.Slot,
         Stamp => Slab_Handle.Stamp,
         Epoch => Item.Core.Epoch_Value);
      Result := Allocated;
   end Try_Allocate;

   procedure Resolve
     (Item        : in out View;
      Arena       : Arena_Provider.View;
      Value       : Handle;
      Index       : out Positive;
      Slab_Handle : out Handles.Handle) is
   begin
      Layouts.Require_Ready (Item.Core);
      Require_Arena (Item, Arena);
      if Value.Chunk = 0
        or else Value.Chunk > Interfaces.Unsigned_32 (Maximum_Chunks)
        or else Value.Slot = 0
        or else Value.Stamp = 0
        or else Value.Epoch = 0
        or else Value.Epoch /= Item.Core.Epoch_Value
      then
         raise Handle_Error with "adaptive-pool handle is invalid or stale";
      end if;
      Index := Positive (Value.Chunk);
      Ensure_Chunk (Item, Arena, Index);
      Slab_Handle := (Slot => Value.Slot, Stamp => Value.Stamp);
   end Resolve;

   procedure Read
     (Item : in out View; Arena : Arena_Provider.View; Value : Handle; Data : out Element.Observed)
   is
      Index       : Positive;
      Slab_Handle : Handles.Handle;
   begin
      Resolve (Item, Arena, Value, Index, Slab_Handle);
      Chunk_Slabs.Read (Item.Chunks (Index).Slab, Slab_Handle, Data);
   end Read;

   procedure Replace (Item : in out View; Arena : Arena_Provider.View; Value : Handle; Data : Element.Source)
   is
      Index       : Positive;
      Slab_Handle : Handles.Handle;
   begin
      Resolve (Item, Arena, Value, Index, Slab_Handle);
      Chunk_Slabs.Replace (Item.Chunks (Index).Slab, Slab_Handle, Data);
   end Replace;

   procedure Release (Item : in out View; Arena : Arena_Provider.View; Value : Handle) is
      Index       : Positive;
      Slab_Handle : Handles.Handle;
   begin
      Resolve (Item, Arena, Value, Index, Slab_Handle);
      Chunk_Slabs.Release (Item.Chunks (Index).Slab, Slab_Handle);
   end Release;

   procedure Destroy (Item : in out View; Arena : in out Arena_Provider.View) is
      Allocation : Arena_Provider.Allocation_Handle;
      Mutated    : Boolean := False;
   begin
      Require_Arena (Item, Arena);
      Acquire (Item);
      begin
         Validate_Table (Item, Arena);
         for Index in 1 .. Maximum_Chunks loop
            if Entry_State (Item, Index) = Live_State then
               Chunk_Validation.Validate_Empty (Item.Chunks (Index).Slab);
            end if;
         end loop;
         for Index in 1 .. Maximum_Chunks loop
            if Entry_State (Item, Index) = Live_State then
               Allocation := Entry_Allocation (Item, Index);
               Mutated := True;
               Chunk_Slabs.Destroy (Item.Chunks (Index).Slab);
               Regions.Detach (Item.Chunks (Index).Region);
               Item.Chunks (Index).Allocation := Arena_Provider.Null_Allocation;
               Arena_Provider.Release (Arena, Allocation);
               Set_Entry_Allocation (Item, Index, Arena_Provider.Null_Allocation);
               Set_Entry_State (Item, Index, Empty_State);
               if Flyology.Adaptive_Pool_Test_Hooks.Enabled then
                  Flyology.Adaptive_Pool_Test_Hooks.Record_Chunk_State (Index, Live => False);
               end if;
            end if;
         end loop;
         Layouts.Mark_Destroyed (Item.Core);
      exception
         when others =>
            begin
               if Mutated then
                  Layouts.Poison (Item.Core);
               end if;
            exception
               when others =>
                  Release_Guard (Item);
                  raise;
            end;
            Release_Guard (Item);
            raise;
      end;
      Release_Guard (Item);
      Detach (Item);
   end Destroy;

end Flyology.Data_Structures.Allocation_Pools.Adaptive;
