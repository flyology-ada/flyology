with Interfaces.C;

package System.Flyology.Contexts is
   pragma Preelaborate;

   type Context is limited private;
   type Context_Access is access all Context;

   function Capture return Context_Access;

   function Create
     (Stack_Size : Interfaces.C.size_t;
      Start      : System.Address;
      Argument   : System.Address;
      Return_To  : Context_Access) return Context_Access;

   procedure Switch (From, To : not null Context_Access);
   procedure Destroy (Item : in out Context_Access);

   function Stack_Base (Item : Context_Access) return System.Address;
   function Stack_Size (Item : Context_Access) return Interfaces.C.size_t;
   function Cold_Advice_Supported return Boolean;
   function Advise_Stack_Cold
     (Item : not null Context_Access) return Interfaces.C.int;
   --  Return 1 when the host accepted nondestructive cold advice, 0 when the
   --  mechanism is unavailable, and -1 when an available host call failed.
   function Pageout_Advice_Supported return Boolean;
   function Advise_Stack_Pageout
     (Item : not null Context_Access) return Interfaces.C.int;
   --  Page-out advice retains the stack mapping and contents but asks the
   --  kernel to reclaim applicable pages immediately. Return values follow
   --  Advise_Stack_Cold.

   type Stack_Pool_Snapshot is record
      ABI_Version       : Interfaces.C.unsigned := 1;
      Active_Arenas     : Interfaces.C.unsigned_long_long := 0;
      Live_Stacks       : Interfaces.C.unsigned_long_long := 0;
      Live_Usable_Bytes : Interfaces.C.unsigned_long_long := 0;
      Reserved_Bytes    : Interfaces.C.unsigned_long_long := 0;
      Arena_Mappings    : Interfaces.C.unsigned_long_long := 0;
      Arena_Unmappings  : Interfaces.C.unsigned_long_long := 0;
      Shared_Stacks     : Interfaces.C.unsigned_long_long := 0;
      Discarded_Stacks  : Interfaces.C.unsigned_long_long := 0;
   end record with Convention => C;

   function Observe_Stack_Pool
     (Snapshot      : System.Address;
      Snapshot_Size : Interfaces.C.size_t) return Interfaces.C.int;
   pragma Export
     (C, Observe_Stack_Pool, "flyology_runtime_observe_stack_pool");

private
   --  Opaque 176-byte machine-state image. The architecture-specific byte
   --  layout and calling-contract rationale live beside the implementation in
   --  runtime/native/context_switch.S; keep this storage in sync with it.
   type Register_Array is
     array (Natural range 0 .. 21) of Interfaces.C.unsigned_long;
   pragma Convention (C, Register_Array);

   type Context is limited record
      Registers   : aliased Register_Array := (others => 0);
      Stack       : System.Address := System.Null_Address;
      Size         : Interfaces.C.size_t := 0;
      Start        : System.Address := System.Null_Address;
      Argument     : System.Address := System.Null_Address;
      Return_To    : Context_Access := null;
      Owns_Mapping : Boolean := False;
      Pool_Arena   : System.Address := System.Null_Address;
      Pool_Slot    : Interfaces.C.size_t := 0;
   end record;
end System.Flyology.Contexts;
