with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.Address_To_Access_Conversions;
with System.Flyology.ASan;
with System.Flyology.Faults;
with System.Flyology.Stack_Policy;
with System.Storage_Elements;

package body System.Flyology.Contexts is
   package C renames Interfaces.C;
   package ASan renames System.Flyology.ASan;
   package Faults renames System.Flyology.Faults;
   package Sizing renames System.Flyology.Stack_Policy;
   package SSE renames System.Storage_Elements;
   package Context_Addresses is new System.Address_To_Access_Conversions (Context);
   package Snapshot_Addresses is new System.Address_To_Access_Conversions (Stack_Pool_Snapshot);

   use type C.int;
   use type C.size_t;
   use type C.unsigned_long_long;
   use type Context_Addresses.Object_Pointer;
   use type Snapshot_Addresses.Object_Pointer;
   use type SSE.Integer_Address;
   use System.Storage_Elements;

   MAP_PRIVATE               : constant := 16#0002#;
   PROT_NONE                 : constant := 0;
   PROT_READ                 : constant := 1;
   PROT_WRITE                : constant := 2;
   Arena_Slot_Limit          : constant := 64;
   Arena_Class_Bucket_Count  : constant := 64;
   Target_Arena_Bytes        : constant C.size_t := 4 * 1_024 * 1_024;
   Minimum_Stack_Guard_Bytes : constant C.size_t := 64 * 1_024;

   function Map_Anonymous return C.int;
   pragma Import (C, Map_Anonymous, "flyology_map_anonymous");

   type Entry_Point is access procedure (Argument : System.Address);
   pragma Convention (C, Entry_Point);

   function To_Entry is new Ada.Unchecked_Conversion (System.Address, Entry_Point);
   function Failed_Mapping return System.Address
   is (SSE.To_Address (SSE.Integer_Address'Last));

   function Mmap
     (Address : System.Address; Length : C.size_t; Prot : C.int; Flags : C.int; File : C.int; Offset : C.long)
      return System.Address;
   pragma Import (C, Mmap, "mmap");

   function Munmap (Address : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, Munmap, "munmap");

   function Get_Page_Size return C.int;
   pragma Import (C, Get_Page_Size, "getpagesize");

   function Mprotect (Address : System.Address; Length : C.size_t; Prot : C.int) return C.int;
   pragma Import (C, Mprotect, "mprotect");

   function Pool_Lock return C.int;
   pragma Import (C, Pool_Lock, "flyology_stack_pool_lock");

   function Pool_Unlock return C.int;
   pragma Import (C, Pool_Unlock, "flyology_stack_pool_unlock");

   function Discard_Pages (Address : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, Discard_Pages, "flyology_discard_pages");

   function Cold_Pages_Supported return C.int;
   pragma Import (C, Cold_Pages_Supported, "flyology_cold_pages_supported");

   function Cold_Pages (Address : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, Cold_Pages, "flyology_cold_pages");

   function Pageout_Pages_Supported return C.int;
   pragma Import (C, Pageout_Pages_Supported, "flyology_pageout_pages_supported");

   function Pageout_Pages (Address : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, Pageout_Pages, "flyology_pageout_pages");

   function In_Fork_Child return C.int;
   pragma Import (C, In_Fork_Child, "flyology_in_fork_child");

   procedure Initialize_Registers
     (Registers : System.Address; Stack_Top : System.Address; Trampoline : System.Address);
   pragma Import (C, Initialize_Registers, "flyology_context_initialize_registers");

   procedure Swap_Registers (From, To : System.Address);
   pragma Import (C, Swap_Registers, "flyology_context_swap_registers");

   procedure Free is new Ada.Unchecked_Deallocation (Context, Context_Access);

   type Slot_Use_Array is array (Natural range 0 .. Arena_Slot_Limit - 1) of Boolean;
   type Stack_Arena;
   type Stack_Arena_Access is access all Stack_Arena;
   type Arena_Class;
   type Arena_Class_Access is access all Arena_Class;

   subtype Arena_Class_Bucket is Natural range 0 .. Arena_Class_Bucket_Count - 1;
   type Arena_Class_Bucket_Array is array (Arena_Class_Bucket) of Arena_Class_Access;

   type Arena_Class is record
      Usable_Size     : C.size_t := 0;
      Guard_Size      : C.size_t := 0;
      Stride          : C.size_t := 0;
      Capacity        : Natural := 0;
      Arena_Count     : Natural := 0;
      Nonfull_Arenas  : Stack_Arena_Access := null;
      Bucket          : Arena_Class_Bucket := 0;
      Bucket_Previous : Arena_Class_Access := null;
      Bucket_Next     : Arena_Class_Access := null;
   end record;

   type Stack_Arena is record
      Mapping          : System.Address := System.Null_Address;
      Mapping_Size     : C.size_t := 0;
      Class            : Arena_Class_Access := null;
      Used_Count       : Natural := 0;
      Used             : Slot_Use_Array := (others => False);
      Nonfull_Previous : Stack_Arena_Access := null;
      Nonfull_Next     : Stack_Arena_Access := null;
      Is_Nonfull       : Boolean := False;
   end record;

   function To_Arena is new Ada.Unchecked_Conversion (System.Address, Stack_Arena_Access);
   function To_Address is new Ada.Unchecked_Conversion (Stack_Arena_Access, System.Address);
   procedure Free_Arena is new Ada.Unchecked_Deallocation (Stack_Arena, Stack_Arena_Access);
   procedure Free_Class is new Ada.Unchecked_Deallocation (Arena_Class, Arena_Class_Access);

   Arena_Classes     : Arena_Class_Bucket_Array := (others => null);
   Active_Arenas     : C.unsigned_long_long := 0;
   Live_Stacks       : C.unsigned_long_long := 0;
   Live_Usable_Bytes : C.unsigned_long_long := 0;
   Reserved_Bytes    : C.unsigned_long_long := 0;
   Arena_Mappings    : C.unsigned_long_long := 0;
   Arena_Unmappings  : C.unsigned_long_long := 0;
   Shared_Stacks     : C.unsigned_long_long := 0;
   Discarded_Stacks  : C.unsigned_long_long := 0;

   procedure Lock_Pool;
   procedure Unlock_Pool;
   function Arena_Capacity (Stride : C.size_t) return Natural;
   function Class_Bucket_For (Usable_Size, Page_Size : C.size_t) return Arena_Class_Bucket;
   function Find_Class (Usable_Size, Guard_Size, Page_Size : C.size_t) return Arena_Class_Access;
   procedure Link_Class (Item : not null Arena_Class_Access);
   procedure Unlink_Class (Item : not null Arena_Class_Access);
   procedure Link_Nonfull (Item : not null Stack_Arena_Access);
   procedure Unlink_Nonfull (Item : not null Stack_Arena_Access);
   function Acquire_Stack
     (Usable_Size : C.size_t; Stack : out System.Address; Arena : out Stack_Arena_Access; Slot : out Natural)
      return Boolean;
   procedure Release_Stack (Arena : not null Stack_Arena_Access; Slot : Natural; Stack : System.Address);

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
         ASan.Finish_Switch (Source_Address, Source_Bottom, Source_Size);
         Source := Context_Addresses.To_Pointer (Source_Address);
         if Source = null then
            raise Program_Error with "Flyology ASan switch has no source context";
         end if;
         if Source_Bottom = System.Null_Address or else Source_Size = 0 then
            raise Program_Error with "Flyology ASan did not report the source stack";
         end if;
         if Source.Owns_Mapping then
            if Source.Stack /= Source_Bottom or else Source.Size /= Source_Size then
               raise Program_Error with "Flyology ASan reported inconsistent task stack bounds";
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
         raise Program_Error with "Flyology stack-pool lock failed";
      end if;
   end Lock_Pool;

   procedure Unlock_Pool is
   begin
      if Pool_Unlock /= 0 then
         raise Program_Error with "Flyology stack-pool unlock failed";
      end if;
   end Unlock_Pool;

   --  Arena classes and non-full links are process-wide metadata. Every
   --  helper below is called only while the stack-pool mutex is held.

   function Arena_Capacity (Stride : C.size_t) return Natural is
      Whole_Slots : C.size_t;
   begin
      if Stride >= Target_Arena_Bytes then
         return 1;
      end if;

      --  Round the target up instead of down. The class therefore maps at
      --  least the target when a second slot fits, while the slot limit keeps
      --  the free-slot bitmap and allocation scan bounded.
      Whole_Slots := Target_Arena_Bytes / Stride;
      if Target_Arena_Bytes mod Stride /= 0 then
         Whole_Slots := Whole_Slots + 1;
      end if;
      return Natural'Min (Arena_Slot_Limit, Natural (Whole_Slots));
   end Arena_Capacity;

   function Class_Bucket_For (Usable_Size, Page_Size : C.size_t) return Arena_Class_Bucket
   is (Arena_Class_Bucket ((Usable_Size / Page_Size) mod C.size_t (Arena_Class_Bucket_Count)));

   function Find_Class (Usable_Size, Guard_Size, Page_Size : C.size_t) return Arena_Class_Access is
      Item : Arena_Class_Access := Arena_Classes (Class_Bucket_For (Usable_Size, Page_Size));
   begin
      while Item /= null loop
         if Item.Usable_Size = Usable_Size and then Item.Guard_Size = Guard_Size then
            return Item;
         end if;
         Item := Item.Bucket_Next;
      end loop;
      return null;
   end Find_Class;

   procedure Link_Class (Item : not null Arena_Class_Access) is
   begin
      Item.Bucket_Previous := null;
      Item.Bucket_Next := Arena_Classes (Item.Bucket);
      if Item.Bucket_Next /= null then
         Item.Bucket_Next.Bucket_Previous := Item;
      end if;
      Arena_Classes (Item.Bucket) := Item;
   end Link_Class;

   procedure Unlink_Class (Item : not null Arena_Class_Access) is
   begin
      if Item.Bucket_Previous = null then
         Arena_Classes (Item.Bucket) := Item.Bucket_Next;
      else
         Item.Bucket_Previous.Bucket_Next := Item.Bucket_Next;
      end if;
      if Item.Bucket_Next /= null then
         Item.Bucket_Next.Bucket_Previous := Item.Bucket_Previous;
      end if;
      Item.Bucket_Previous := null;
      Item.Bucket_Next := null;
   end Unlink_Class;

   procedure Link_Nonfull (Item : not null Stack_Arena_Access) is
      Class : constant Arena_Class_Access := Item.Class;
   begin
      if Class = null or else Item.Is_Nonfull or else Item.Used_Count >= Class.Capacity then
         raise Program_Error with "Flyology invalid non-full arena insertion";
      end if;
      Item.Nonfull_Previous := null;
      Item.Nonfull_Next := Class.Nonfull_Arenas;
      if Item.Nonfull_Next /= null then
         Item.Nonfull_Next.Nonfull_Previous := Item;
      end if;
      Class.Nonfull_Arenas := Item;
      Item.Is_Nonfull := True;
   end Link_Nonfull;

   procedure Unlink_Nonfull (Item : not null Stack_Arena_Access) is
      Class : constant Arena_Class_Access := Item.Class;
   begin
      if Class = null or else not Item.Is_Nonfull then
         raise Program_Error with "Flyology invalid non-full arena removal";
      end if;
      if Item.Nonfull_Previous = null then
         Class.Nonfull_Arenas := Item.Nonfull_Next;
      else
         Item.Nonfull_Previous.Nonfull_Next := Item.Nonfull_Next;
      end if;
      if Item.Nonfull_Next /= null then
         Item.Nonfull_Next.Nonfull_Previous := Item.Nonfull_Previous;
      end if;
      Item.Nonfull_Previous := null;
      Item.Nonfull_Next := null;
      Item.Is_Nonfull := False;
   end Unlink_Nonfull;

   function Round_Up (Value, Alignment : C.size_t) return C.size_t
   is ((Value + Alignment - 1) / Alignment * Alignment);

   function Guard_Bytes (Page_Size : C.size_t) return C.size_t
   is (Round_Up (Minimum_Stack_Guard_Bytes, Page_Size));

   function Acquire_Stack
     (Usable_Size : C.size_t; Stack : out System.Address; Arena : out Stack_Arena_Access; Slot : out Natural)
      return Boolean
   is
      Page_Size     : constant C.size_t := C.size_t (Get_Page_Size);
      Guard_Size    : constant C.size_t := Guard_Bytes (Page_Size);
      Stride        : constant C.size_t := Usable_Size + Guard_Size;
      Class         : Arena_Class_Access;
      Created_Class : Arena_Class_Access := null;
      Item          : Stack_Arena_Access;
      Capacity      : Natural;
      Result        : C.int;
      Locked        : Boolean := False;
   begin
      Stack := System.Null_Address;
      Arena := null;
      Slot := 0;

      --  size_t is modular, so an oversized request would silently wrap the
      --  stride and the arena mapping length instead of failing. Reject it
      --  here: a wrapped stride divides the arena capacity by zero, and a
      --  wrapped mapping length maps nothing while still handing out slot
      --  addresses.
      if not Sizing.Mappable (Usable_Size, Guard_Size) then
         return False;
      end if;

      Lock_Pool;
      Locked := True;

      Class := Find_Class (Usable_Size, Guard_Size, Page_Size);
      Item := (if Class = null then null else Class.Nonfull_Arenas);
      if Item /= null then
         for Index in 0 .. Class.Capacity - 1 loop
            if not Item.Used (Index) then
               Stack :=
                 Item.Mapping + SSE.Storage_Offset (Class.Guard_Size + C.size_t (Index) * Class.Stride);
               Result :=
                 (if Faults.Enabled and then Faults.Fail (Faults.Stack_Protection)
                  then -1
                  else Mprotect (Stack, Usable_Size, PROT_READ + PROT_WRITE));
               if Result /= 0 then
                  Unlock_Pool;
                  Locked := False;
                  return False;
               end if;
               Item.Used (Index) := True;
               Item.Used_Count := Item.Used_Count + 1;
               if Item.Used_Count = Class.Capacity then
                  Unlink_Nonfull (Item);
               end if;
               Live_Stacks := Live_Stacks + 1;
               Live_Usable_Bytes := Live_Usable_Bytes + C.unsigned_long_long (Usable_Size);
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
         raise Program_Error with "Flyology stack arena has no advertised free slot";
      end if;

      if Class = null then
         Capacity := Arena_Capacity (Stride);
         Class := new Arena_Class;
         Created_Class := Class;
         Class.Usable_Size := Usable_Size;
         Class.Guard_Size := Guard_Size;
         Class.Stride := Stride;
         Class.Capacity := Capacity;
         Class.Bucket := Class_Bucket_For (Usable_Size, Page_Size);
      else
         Capacity := Class.Capacity;
      end if;

      begin
         Item := new Stack_Arena;
      exception
         when others =>
            if Created_Class /= null then
               Free_Class (Created_Class);
            end if;
            raise;
      end;
      Item.Class := Class;
      Item.Mapping_Size := C.size_t (Capacity) * Stride + Guard_Size;
      if Faults.Enabled and then Faults.Fail (Faults.Stack_Mapping) then
         Free_Arena (Item);
         if Created_Class /= null then
            Free_Class (Created_Class);
         end if;
         Unlock_Pool;
         Locked := False;
         return False;
      end if;
      Item.Mapping :=
        Mmap (System.Null_Address, Item.Mapping_Size, PROT_NONE, MAP_PRIVATE + Map_Anonymous, -1, 0);
      if Item.Mapping = Failed_Mapping then
         Free_Arena (Item);
         if Created_Class /= null then
            Free_Class (Created_Class);
         end if;
         Unlock_Pool;
         Locked := False;
         return False;
      end if;

      Stack := Item.Mapping + SSE.Storage_Offset (Guard_Size);
      Result :=
        (if Faults.Enabled and then Faults.Fail (Faults.Stack_Protection)
         then -1
         else Mprotect (Stack, Usable_Size, PROT_READ + PROT_WRITE));
      if Result /= 0 then
         Result := Munmap (Item.Mapping, Item.Mapping_Size);
         Free_Arena (Item);
         if Created_Class /= null then
            Free_Class (Created_Class);
         end if;
         Unlock_Pool;
         Locked := False;
         if Result /= 0 then
            raise Program_Error with "Flyology failed to release unusable stack arena";
         end if;
         return False;
      end if;

      Item.Used (0) := True;
      Item.Used_Count := 1;
      Class.Arena_Count := Class.Arena_Count + 1;
      if Created_Class /= null then
         Link_Class (Class);
         Created_Class := null;
      end if;
      if Capacity > 1 then
         Link_Nonfull (Item);
      end if;
      Active_Arenas := Active_Arenas + 1;
      Live_Stacks := Live_Stacks + 1;
      Live_Usable_Bytes := Live_Usable_Bytes + C.unsigned_long_long (Usable_Size);
      Reserved_Bytes := Reserved_Bytes + C.unsigned_long_long (Item.Mapping_Size);
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

   procedure Release_Stack (Arena : not null Stack_Arena_Access; Slot : Natural; Stack : System.Address) is
      Class        : constant Arena_Class_Access := Arena.Class;
      Victim       : Stack_Arena_Access := Arena;
      Victim_Class : Arena_Class_Access := null;
      Result       : C.int;
      Expected     : System.Address;
      Was_Full     : Boolean;
      Discarded    : Boolean := False;
      Locked       : Boolean := False;
   begin
      Lock_Pool;
      Locked := True;
      if Class = null or else Slot >= Class.Capacity or else not Arena.Used (Slot) then
         Unlock_Pool;
         Locked := False;
         raise Program_Error with "Flyology invalid stack-pool release";
      end if;
      Expected := Arena.Mapping + SSE.Storage_Offset (Class.Guard_Size + C.size_t (Slot) * Class.Stride);
      if Stack /= Expected then
         Unlock_Pool;
         Locked := False;
         raise Program_Error with "Flyology stack-pool address mismatch";
      end if;

      --  Protect first so a stale task pointer faults before this slot can be
      --  reused. Best-effort discard advice may let the kernel reclaim the
      --  now-inaccessible pages; guard safety does not depend on that advice.
      Result :=
        (if Faults.Enabled and then Faults.Fail (Faults.Stack_Protection)
         then -1
         else Mprotect (Stack, Class.Usable_Size, PROT_NONE));
      if Result /= 0 then
         Unlock_Pool;
         Locked := False;
         raise Program_Error with "Flyology stack-pool protection failed";
      end if;
      if not (Faults.Enabled and then Faults.Fail (Faults.Stack_Discard))
        and then Discard_Pages (Stack, Class.Usable_Size) = 0
      then
         Discarded := True;
      end if;

      Was_Full := Arena.Used_Count = Class.Capacity;
      if Arena.Used_Count = 1 then
         Result := Munmap (Arena.Mapping, Arena.Mapping_Size);
         if Result /= 0 then
            Unlock_Pool;
            Locked := False;
            raise Program_Error with "Flyology stack-arena release failed";
         end if;
         if Arena.Is_Nonfull then
            Unlink_Nonfull (Arena);
         end if;
      end if;

      Arena.Used (Slot) := False;
      Arena.Used_Count := Arena.Used_Count - 1;
      Live_Stacks := Live_Stacks - 1;
      Live_Usable_Bytes := Live_Usable_Bytes - C.unsigned_long_long (Class.Usable_Size);
      if Discarded then
         Discarded_Stacks := Discarded_Stacks + 1;
      end if;
      if Arena.Used_Count = 0 then
         Class.Arena_Count := Class.Arena_Count - 1;
         if Class.Arena_Count = 0 then
            if Class.Nonfull_Arenas /= null then
               Unlock_Pool;
               Locked := False;
               raise Program_Error with "Flyology empty stack class retained an arena";
            end if;
            Unlink_Class (Class);
            Victim_Class := Class;
         end if;
         Active_Arenas := Active_Arenas - 1;
         Reserved_Bytes := Reserved_Bytes - C.unsigned_long_long (Arena.Mapping_Size);
         Arena_Unmappings := Arena_Unmappings + 1;
         Free_Arena (Victim);
         if Victim_Class /= null then
            Free_Class (Victim_Class);
         end if;
      elsif Was_Full then
         Link_Nonfull (Arena);
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

   function Capture return Context_Access is
      Item : constant Context_Access := new Context;
   begin
      Set_Active_Context (Item);
      return Item;
   end Capture;

   function Create
     (Stack_Size : C.size_t; Start : System.Address; Argument : System.Address; Return_To : Context_Access)
      return Context_Access
   is
      Page_Size   : constant C.size_t := C.size_t (Get_Page_Size);
      Guard_Size  : constant C.size_t := Guard_Bytes (Page_Size);
      Usable_Size : C.size_t;
      Item        : Context_Access := new Context;
      Arena       : Stack_Arena_Access;
      Slot        : Natural;
      Top         : SSE.Integer_Address;
   begin
      --  Sizing.Accepts rejects a zero request and every request whose page
      --  round-up would wrap size_t into a smaller usable size - zero for the
      --  classic (size_t) -1 request - or whose arena arithmetic would wrap.
      if not Sizing.Accepts (Stack_Size, Page_Size, Guard_Size)
        or else Start = System.Null_Address
        or else Return_To = null
      then
         Free (Item);
         return null;
      end if;

      Usable_Size := Sizing.Usable_Bytes (Stack_Size, Page_Size, Guard_Size);
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
      Initialize_Registers (Item.Registers'Address, SSE.To_Address (Top), Trampoline'Address);
      return Item;
   end Create;

   procedure Switch (From, To : not null Context_Access) is
   begin
      if ASan.Enabled then
         if To.Stack = System.Null_Address or else To.Size = 0 then
            raise Program_Error with "Flyology ASan destination stack is unknown";
         end if;
         ASan.Start_Switch (From.all'Address, To.Stack, To.Size);
      end if;
      Set_Active_Context (To);
      Swap_Registers (From.Registers'Address, To.Registers'Address);
      --  Complete ASan's pending transfer before doing work on the resumed
      --  stack. In particular, this re-enables fake-stack allocation (though
      --  Flyology intentionally does not preserve fake stacks across yields).
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
            raise Program_Error with "Flyology task stack has no arena";
         end if;
         Release_Stack (Arena, Natural (Item.Pool_Slot), Item.Stack);
      end if;
      Free (Item);
   end Destroy;

   function Stack_Base (Item : Context_Access) return System.Address
   is (if Item = null then System.Null_Address else Item.Stack);

   function Stack_Size (Item : Context_Access) return C.size_t
   is (if Item = null then 0 else Item.Size);

   function Cold_Advice_Supported return Boolean
   is (Cold_Pages_Supported /= 0);

   function Advise_Stack_Cold (Item : not null Context_Access) return C.int is
   begin
      if not Item.Owns_Mapping or else Item.Stack = System.Null_Address or else Item.Size = 0 then
         return -1;
      end if;
      return Cold_Pages (Item.Stack, Item.Size);
   end Advise_Stack_Cold;

   function Pageout_Advice_Supported return Boolean
   is (Pageout_Pages_Supported /= 0);

   function Advise_Stack_Pageout (Item : not null Context_Access) return C.int is
   begin
      if not Item.Owns_Mapping or else Item.Stack = System.Null_Address or else Item.Size = 0 then
         return -1;
      end if;
      return Pageout_Pages (Item.Stack, Item.Size);
   end Advise_Stack_Pageout;

   function Observe_Stack_Pool (Snapshot : System.Address; Snapshot_Size : C.size_t) return C.int is
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
        (ABI_Version       => 1,
         Active_Arenas     => Active_Arenas,
         Live_Stacks       => Live_Stacks,
         Live_Usable_Bytes => Live_Usable_Bytes,
         Reserved_Bytes    => Reserved_Bytes,
         Arena_Mappings    => Arena_Mappings,
         Arena_Unmappings  => Arena_Unmappings,
         Shared_Stacks     => Shared_Stacks,
         Discarded_Stacks  => Discarded_Stacks);
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

end System.Flyology.Contexts;
