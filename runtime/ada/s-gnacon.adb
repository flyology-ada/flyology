with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.Storage_Elements;

package body System.Gnatevl.Contexts is
   package C renames Interfaces.C;
   package SSE renames System.Storage_Elements;

   use type C.int;
   use type C.size_t;
   use type SSE.Integer_Address;
   use System.Storage_Elements;

   MAP_PRIVATE : constant := 16#0002#;
   PROT_NONE   : constant := 0;
   PROT_READ   : constant := 1;
   PROT_WRITE  : constant := 2;

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

   Active_Context : Context_Access := null;
   pragma Thread_Local_Storage (Active_Context);

   procedure Set_Active_Context (Item : Context_Access);
   pragma No_Inline (Set_Active_Context);

   procedure Trampoline;
   pragma Convention (C, Trampoline);
   pragma No_Return (Trampoline);

   procedure Set_Active_Context (Item : Context_Access) is
   begin
      --  Resolve the TLS slot on every call. A context may resume on a
      --  different pthread, so retaining the pre-switch TLS address across
      --  Swap_Registers would write into the source thread's slot.
      Active_Context := Item;
   end Set_Active_Context;

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
      Result      : C.int;
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
      Item.Mapping_Size := Usable_Size + 2 * Page_Size;
      Item.Mapping :=
        Mmap
          (System.Null_Address,
           Item.Mapping_Size,
           PROT_NONE,
           MAP_PRIVATE + Map_Anonymous,
           -1,
           0);

      if Item.Mapping = Failed_Mapping then
         Free (Item);
         return null;
      end if;

      Item.Stack := Item.Mapping + SSE.Storage_Offset (Page_Size);
      Result :=
        Mprotect (Item.Stack, Usable_Size, PROT_READ + PROT_WRITE);
      if Result /= 0 then
         Result := Munmap (Item.Mapping, Item.Mapping_Size);
         Free (Item);
         if Result /= 0 then
            raise Program_Error with
              "GNATEVL failed to release unusable task stack";
         end if;
         return null;
      end if;

      Item.Size := Usable_Size;
      Item.Start := Start;
      Item.Argument := Argument;
      Item.Return_To := Return_To;
      Item.Owns_Mapping := True;
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
      Set_Active_Context (To);
      Swap_Registers (From.Registers'Address, To.Registers'Address);
      Set_Active_Context (From);
   end Switch;

   procedure Destroy (Item : in out Context_Access) is
      Result : C.int;
   begin
      if Item = null then
         return;
      end if;

      if Active_Context = Item then
         Active_Context := null;
      end if;

      if Item.Owns_Mapping then
         Result := Munmap (Item.Mapping, Item.Mapping_Size);
         if Result /= 0 then
            raise Program_Error with "GNATEVL task stack release failed";
         end if;
      end if;
      Free (Item);
   end Destroy;

   function Stack_Base (Item : Context_Access) return System.Address is
     (if Item = null then System.Null_Address else Item.Stack);

   function Stack_Size (Item : Context_Access) return C.size_t is
     (if Item = null then 0 else Item.Size);

   procedure Trampoline is
      Item : constant Context_Access := Active_Context;
   begin
      if Item = null or else Item.Start = System.Null_Address then
         raise Program_Error;
      end if;

      To_Entry (Item.Start).all (Item.Argument);
      Switch (Item, Item.Return_To);
      raise Program_Error;
   end Trampoline;

end System.Gnatevl.Contexts;
