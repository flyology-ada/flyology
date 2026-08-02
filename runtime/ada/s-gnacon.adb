with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.Address_To_Access_Conversions;
with System.Gnatevl.ASan;
with System.Gnatevl.Faults;
with System.Storage_Elements;

package body System.Gnatevl.Contexts is
   package C renames Interfaces.C;
   package ASan renames System.Gnatevl.ASan;
   package Faults renames System.Gnatevl.Faults;
   package SSE renames System.Storage_Elements;
   package Context_Addresses is new System.Address_To_Access_Conversions
     (Context);
   package Snapshot_Addresses is new System.Address_To_Access_Conversions
     (Stack_Pool_Snapshot);

   use type C.int;
   use type C.size_t;
   use type C.unsigned_long_long;
   use type Context_Addresses.Object_Pointer;
   use type Snapshot_Addresses.Object_Pointer;
   use type SSE.Integer_Address;
   use System.Storage_Elements;

   MAP_PRIVATE : constant := 16#0002#;
   PROT_NONE   : constant := 0;
   PROT_READ   : constant := 1;
   PROT_WRITE  : constant := 2;
   Arena_Slot_Limit : constant := 64;
   Maximum_Arena_Bytes : constant C.size_t := 4 * 1_024 * 1_024;

   function Map_Anonymous return C.int;
   pragma Import (C, Map_Anonymous, "gnatevl_map_anonymous");

   type Entry_Point is access procedure (Argument : System.Address);
   pragma Convention (C, Entry_Point);

   function To_Entry is new Ada.Unchecked_Conversion
     (System.Address, Entry_Point);
   function Failed_Mapping return System.Address is
     (SSE.To_Address (SSE.Integer_Address'Last));

   function Mmap
     (Address : System.Address;
      Length  : C.size_t;
      Prot    : C.int;
      Flags   : C.int;
      File    : C.int;
      Offset  : C.long) return System.Address;
   pragma Import (C, Mmap, "mmap");

   function Munmap
     (Address : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, Munmap, "munmap");

   function Get_Page_Size return C.int;
   pragma Import (C, Get_Page_Size, "getpagesize");

   function Mprotect
     (Address : System.Address; Length : C.size_t; Prot : C.int)
      return C.int;
   pragma Import (C, Mprotect, "mprotect");

   function Pool_Lock return C.int;
   pragma Import (C, Pool_Lock, "gnatevl_stack_pool_lock");

   function Pool_Unlock return C.int;
   pragma Import (C, Pool_Unlock, "gnatevl_stack_pool_unlock");

   function Discard_Pages
     (Address : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, Discard_Pages, "gnatevl_discard_pages");

   function In_Fork_Child return C.int;
   pragma Import (C, In_Fork_Child, "gnatevl_in_fork_child");

   procedure Initialize_Registers
     (Registers  : System.Address;
      Stack_Top  : System.Address;
      Trampoline : System.Address);
   pragma Import
     (C, Initialize_Registers, "gnatevl_context_initialize_registers");

   procedure Swap_Registers
     (From, To : System.Address);
   pragma Import (C, Swap_Registers, "gnatevl_context_swap_registers");

   procedure Free is new Ada.Unchecked_Deallocation (Context, Context_Access);

   type Slot_Use_Array is
     array (Natural range 0 .. Arena_Slot_Limit - 1) of Boolean;
   type Stack_Arena;
   type Stack_Arena_Access is access all Stack_Arena;
   type Stack_Arena is record
      Mapping      : System.Address := System.Null_Address;
      Mapping_Size : C.size_t := 0;
      Usable_Size  : C.size_t := 0;
      Stride       : C.size_t := 0;
      Capacity     : Natural := 0;
      Used_Count   : Natural := 0;
      Used         : Slot_Use_Array := (others => False);
      Next         : Stack_Arena_Access := null;
   end record;

   function To_Arena is new Ada.Unchecked_Conversion
     (System.Address, Stack_Arena_Access);
   function To_Address is new Ada.Unchecked_Conversion
     (Stack_Arena_Access, System.Address);
   procedure Free_Arena is new Ada.Unchecked_Deallocation
     (Stack_Arena, Stack_Arena_Access);

   Arenas : Stack_Arena_Access := null;
   Active_Arenas    : C.unsigned_long_long := 0;
   Live_Stacks      : C.unsigned_long_long := 0;
   Live_Usable_Bytes : C.unsigned_long_long := 0;
   Reserved_Bytes   : C.unsigned_long_long := 0;
   Arena_Mappings   : C.unsigned_long_long := 0;
   Arena_Unmappings : C.unsigned_long_long := 0;
   Shared_Stacks    : C.unsigned_long_long := 0;
   Discarded_Stacks : C.unsigned_long_long := 0;

   procedure Lock_Pool;
   procedure Unlock_Pool;
   function Acquire_Stack
     (Usable_Size : C.size_t;
      Stack       : out System.Address;
      Arena       : out Stack_Arena_Access;
      Slot        : out Natural) return Boolean;
   procedure Release_Stack
     (Arena : not null Stack_Arena_Access;
      Slot  : Natural;
      Stack : System.Address);

   Active_Context : Context_Access := null;
   pragma Thread_Local_Storage (Active_Context);

   procedure Set_Active_Context (Item : Context_Access);
   pragma No_Inline (Set_Active_Context);

   procedure Trampoline;
   pragma Convention (C, Trampoline);
   pragma No_Return (Trampoline);

   procedure Finish_Switch;
   pragma No_Inline (Finish_Switch);

   procedure Set_Active_Context (Item : Context_Access) is
   begin
      --  Resolve the TLS slot on every call. A context may resume on a
      --  different pthread, so retaining the pre-switch TLS address across
      --  Swap_Registers would write into the source thread's slot.
      Active_Context := Item;
   end Set_Active_Context;

   procedure Finish_Switch is
      Source         : Context_Addresses.Object_Pointer;
      Source_Address : System.Address;
      Source_Bottom  : System.Address;
      Source_Size    : C.size_t;
   begin
      if ASan.Enabled then
         --  ASan's package retains the source in pthread-local state, rather
         --  than in the resumed context. This distinction matters when a task
         --  resumes after a cross-group migration: the old Switch frame still
         --  names its old scheduler, but ASan reports the new loop pthread.
         ASan.Finish_Switch
           (Source_Address, Source_Bottom, Source_Size);
         Source := Context_Addresses.To_Pointer (Source_Address);
         if Source = null then
            raise Program_Error with
              "GNATEVL ASan switch has no source context";
         end if;
         if Source_Bottom = System.Null_Address or else Source_Size = 0 then
            raise Program_Error with
              "GNATEVL ASan did not report the source stack";
         end if;
         if Source.Owns_Mapping then
            if Source.Stack /= Source_Bottom or else Source.Size /= Source_Size
            then
               raise Program_Error with
                 "GNATEVL ASan reported inconsistent task stack bounds";
            end if;
         else
            --  Capture learns a scheduler pthread's native stack on the first
            --  transfer away from it. Every later destination switch can then
            --  provide ASan with exact scheduler-stack bounds.
            Source.Stack := Source_Bottom;
            Source.Size := Source_Size;
         end if;
      end if;
   end Finish_Switch;

   procedure Lock_Pool is
   begin
      if Pool_Lock /= 0 then
         raise Program_Error with "GNATEVL stack-pool lock failed";
      end if;
   end Lock_Pool;

   procedure Unlock_Pool is
   begin
      if Pool_Unlock /= 0 then
         raise Program_Error with "GNATEVL stack-pool unlock failed";
      end if;
   end Unlock_Pool;

   function Acquire_Stack
     (Usable_Size : C.size_t;
      Stack       : out System.Address;
      Arena       : out Stack_Arena_Access;
      Slot        : out Natural) return Boolean
   is
      Page_Size : constant C.size_t := C.size_t (Get_Page_Size);
      Item      : Stack_Arena_Access;
      Capacity  : Natural;
      Result    : C.int;
      Stride    : constant C.size_t := Usable_Size + Page_Size;
      Locked    : Boolean := False;
   begin
      Stack := System.Null_Address;
      Arena := null;
      Slot := 0;
      Lock_Pool;
      Locked := True;

      Item := Arenas;
      while Item /= null loop
         if Item.Usable_Size = Usable_Size
           and then Item.Used_Count < Item.Capacity
         then
            for Index in 0 .. Item.Capacity - 1 loop
               if not Item.Used (Index) then
                  Stack :=
                    Item.Mapping
                    + SSE.Storage_Offset
                        (Page_Size + C.size_t (Index) * Item.Stride);
                  Result :=
                    (if Faults.Enabled
                       and then Faults.Fail (Faults.Stack_Protection)
                     then -1
                     else Mprotect
                       (Stack, Usable_Size, PROT_READ + PROT_WRITE));
                  if Result /= 0 then
                     Unlock_Pool;
                     Locked := False;
                     return False;
                  end if;
                  Item.Used (Index) := True;
                  Item.Used_Count := Item.Used_Count + 1;
                  Live_Stacks := Live_Stacks + 1;
                  Live_Usable_Bytes :=
                    Live_Usable_Bytes + C.unsigned_long_long (Usable_Size);
                  Shared_Stacks := Shared_Stacks + 1;
                  Arena := Item;
                  Slot := Index;
                  Unlock_Pool;
                  Locked := False;
                  return True;
               end if;
            end loop;
            Unlock_Pool;
            Locked := False;
            raise Program_Error with
              "GNATEVL stack arena has no advertised free slot";
         end if;
         Item := Item.Next;
      end loop;

      Capacity :=
        (if Stride >= Maximum_Arena_Bytes
         then 1
         else Natural'Min
           (Arena_Slot_Limit,
            Natural (Maximum_Arena_Bytes / Stride)));
      Item := new Stack_Arena;
      Item.Usable_Size := Usable_Size;
      Item.Stride := Stride;
      Item.Capacity := Capacity;
      Item.Mapping_Size := C.size_t (Capacity) * Stride + Page_Size;
      if Faults.Enabled and then Faults.Fail (Faults.Stack_Mapping) then
         Free_Arena (Item);
         Unlock_Pool;
         Locked := False;
         return False;
      end if;
      Item.Mapping := Mmap
        (System.Null_Address,
         Item.Mapping_Size,
         PROT_NONE,
         MAP_PRIVATE + Map_Anonymous,
         -1,
         0);
      if Item.Mapping = Failed_Mapping then
         Free_Arena (Item);
         Unlock_Pool;
         Locked := False;
         return False;
      end if;

      Stack := Item.Mapping + SSE.Storage_Offset (Page_Size);
      Result :=
        (if Faults.Enabled and then Faults.Fail (Faults.Stack_Protection)
         then -1
         else Mprotect (Stack, Usable_Size, PROT_READ + PROT_WRITE));
      if Result /= 0 then
         Result := Munmap (Item.Mapping, Item.Mapping_Size);
         Free_Arena (Item);
         Unlock_Pool;
         Locked := False;
         if Result /= 0 then
            raise Program_Error with
              "GNATEVL failed to release unusable stack arena";
         end if;
         return False;
      end if;

      Item.Used (0) := True;
      Item.Used_Count := 1;
      Item.Next := Arenas;
      Arenas := Item;
      Active_Arenas := Active_Arenas + 1;
      Live_Stacks := Live_Stacks + 1;
      Live_Usable_Bytes :=
        Live_Usable_Bytes + C.unsigned_long_long (Usable_Size);
      Reserved_Bytes :=
        Reserved_Bytes + C.unsigned_long_long (Item.Mapping_Size);
      Arena_Mappings := Arena_Mappings + 1;
      Arena := Item;
      Slot := 0;
      Unlock_Pool;
      Locked := False;
      return True;
   exception
      when others =>
         --  Never strand the process-wide pool mutex on allocation failure.
         --  Unlock errors are necessarily fatal and replace the original
         --  exception, which is preferable to silently deadlocking creators.
         if Locked then
            Unlock_Pool;
         end if;
         raise;
   end Acquire_Stack;

   procedure Release_Stack
     (Arena : not null Stack_Arena_Access;
      Slot  : Natural;
      Stack : System.Address)
   is
      Position : Stack_Arena_Access;
      Previous : Stack_Arena_Access := null;
      Victim   : Stack_Arena_Access := Arena;
      Result   : C.int;
      Expected : System.Address;
      Locked   : Boolean := False;
   begin
      Lock_Pool;
      Locked := True;
      if Slot >= Arena.Capacity or else not Arena.Used (Slot) then
         Unlock_Pool;
         Locked := False;
         raise Program_Error with "GNATEVL invalid stack-pool release";
      end if;
      Expected :=
        Arena.Mapping
        + SSE.Storage_Offset
            (C.size_t (Get_Page_Size) + C.size_t (Slot) * Arena.Stride);
      if Stack /= Expected then
         Unlock_Pool;
         Locked := False;
         raise Program_Error with "GNATEVL stack-pool address mismatch";
      end if;

      --  Protect first so a stale task pointer faults before this slot can be
      --  reused. Best-effort discard advice may let the kernel reclaim the
      --  now-inaccessible pages; guard safety does not depend on that advice.
      Result :=
        (if Faults.Enabled and then Faults.Fail (Faults.Stack_Protection)
         then -1
         else Mprotect (Stack, Arena.Usable_Size, PROT_NONE));
      if Result /= 0 then
         Unlock_Pool;
         Locked := False;
         raise Program_Error with "GNATEVL stack-pool protection failed";
      end if;
      if not (Faults.Enabled and then Faults.Fail (Faults.Stack_Discard))
        and then Discard_Pages (Stack, Arena.Usable_Size) = 0
      then
         Discarded_Stacks := Discarded_Stacks + 1;
      end if;

      Arena.Used (Slot) := False;
      Arena.Used_Count := Arena.Used_Count - 1;
      Live_Stacks := Live_Stacks - 1;
      Live_Usable_Bytes :=
        Live_Usable_Bytes - C.unsigned_long_long (Arena.Usable_Size);
      if Arena.Used_Count = 0 then
         Position := Arenas;
         while Position /= null and then Position /= Arena loop
            Previous := Position;
            Position := Position.Next;
         end loop;
         if Position = null then
            Unlock_Pool;
            Locked := False;
            raise Program_Error with "GNATEVL lost an empty stack arena";
         end if;
         Result := Munmap (Arena.Mapping, Arena.Mapping_Size);
         if Result /= 0 then
            Unlock_Pool;
            Locked := False;
            raise Program_Error with "GNATEVL stack-arena release failed";
         end if;
         if Previous = null then
            Arenas := Arena.Next;
         else
            Previous.Next := Arena.Next;
         end if;
         Active_Arenas := Active_Arenas - 1;
         Reserved_Bytes :=
           Reserved_Bytes - C.unsigned_long_long (Arena.Mapping_Size);
         Arena_Unmappings := Arena_Unmappings + 1;
         Free_Arena (Victim);
      end if;
      Unlock_Pool;
      Locked := False;
   exception
      when others =>
         if Locked then
            Unlock_Pool;
         end if;
         raise;
   end Release_Stack;

   function Round_Up
     (Value, Alignment : C.size_t) return C.size_t
   is
     ((Value + Alignment - 1) / Alignment * Alignment);

   function Capture return Context_Access is
      Item : constant Context_Access := new Context;
   begin
      Set_Active_Context (Item);
      return Item;
   end Capture;

   function Create
     (Stack_Size : C.size_t;
      Start      : System.Address;
      Argument   : System.Address;
      Return_To  : Context_Access) return Context_Access
   is
      Page_Size   : constant C.size_t := C.size_t (Get_Page_Size);
      Usable_Size : C.size_t;
      Item        : Context_Access := new Context;
      Arena       : Stack_Arena_Access;
      Slot        : Natural;
      Top         : SSE.Integer_Address;
   begin
      if Stack_Size = 0
        or else Start = System.Null_Address
        or else Return_To = null
      then
         Free (Item);
         return null;
      end if;

      Usable_Size := Round_Up (Stack_Size, Page_Size);
      if not Acquire_Stack (Usable_Size, Item.Stack, Arena, Slot) then
         Free (Item);
         return null;
      end if;

      Item.Size := Usable_Size;
      Item.Start := Start;
      Item.Argument := Argument;
      Item.Return_To := Return_To;
      Item.Owns_Mapping := True;
      Item.Pool_Arena := To_Address (Arena);
      Item.Pool_Slot := C.size_t (Slot);
      Top := SSE.To_Integer (Item.Stack) + SSE.Integer_Address (Item.Size);
      Top := Top and not SSE.Integer_Address (16#0F#);
      Initialize_Registers
        (Item.Registers'Address,
         SSE.To_Address (Top),
         Trampoline'Address);
      return Item;
   end Create;

   procedure Switch (From, To : not null Context_Access) is
   begin
      if ASan.Enabled then
         if To.Stack = System.Null_Address or else To.Size = 0 then
            raise Program_Error with
              "GNATEVL ASan destination stack is unknown";
         end if;
         ASan.Start_Switch
           (From.all'Address, To.Stack, To.Size);
      end if;
      Set_Active_Context (To);
      Swap_Registers (From.Registers'Address, To.Registers'Address);
      --  Complete ASan's pending transfer before doing work on the resumed
      --  stack. In particular, this re-enables fake-stack allocation (though
      --  GNATEVL intentionally does not preserve fake stacks across yields).
      Finish_Switch;
      Set_Active_Context (From);
   end Switch;

   procedure Destroy (Item : in out Context_Access) is
      Arena : Stack_Arena_Access;
   begin
      if Item = null then
         return;
      end if;

      if Active_Context = Item then
         Active_Context := null;
      end if;

      if Item.Owns_Mapping then
         Arena := To_Arena (Item.Pool_Arena);
         if Arena = null then
            raise Program_Error with "GNATEVL task stack has no arena";
         end if;
         Release_Stack (Arena, Natural (Item.Pool_Slot), Item.Stack);
      end if;
      Free (Item);
   end Destroy;

   function Stack_Base (Item : Context_Access) return System.Address is
     (if Item = null then System.Null_Address else Item.Stack);

   function Stack_Size (Item : Context_Access) return C.size_t is
     (if Item = null then 0 else Item.Size);

   function Observe_Stack_Pool
     (Snapshot      : System.Address;
      Snapshot_Size : C.size_t) return C.int
   is
      Value  : Snapshot_Addresses.Object_Pointer;
      Locked : Boolean := False;
   begin
      if Snapshot = System.Null_Address
        or else Snapshot_Size /= Stack_Pool_Snapshot'Size / 8
        or else In_Fork_Child /= 0
      then
         return -1;
      end if;
      Value := Snapshot_Addresses.To_Pointer (Snapshot);
      if Value = null then
         return -1;
      end if;

      Lock_Pool;
      Locked := True;
      Value.all :=
        (ABI_Version      => 1,
         Active_Arenas    => Active_Arenas,
         Live_Stacks      => Live_Stacks,
         Live_Usable_Bytes => Live_Usable_Bytes,
         Reserved_Bytes   => Reserved_Bytes,
         Arena_Mappings   => Arena_Mappings,
         Arena_Unmappings => Arena_Unmappings,
         Shared_Stacks    => Shared_Stacks,
         Discarded_Stacks => Discarded_Stacks);
      Unlock_Pool;
      Locked := False;
      return 1;
   exception
      when others =>
         if Locked then
            Unlock_Pool;
         end if;
         return -1;
   end Observe_Stack_Pool;

   procedure Trampoline is
      Item : constant Context_Access := Active_Context;
   begin
      --  A fresh context does not return through Switch, so its first entry
      --  must finish the scheduler-to-task transfer explicitly.
      Finish_Switch;
      if Item = null or else Item.Start = System.Null_Address then
         raise Program_Error;
      end if;

      To_Entry (Item.Start).all (Item.Argument);
      Switch (Item, Item.Return_To);
      raise Program_Error;
   end Trampoline;

end System.Gnatevl.Contexts;
