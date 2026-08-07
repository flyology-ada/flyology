with Ada.Command_Line;
with Flyology.Observability;
with Interfaces.C;
with System;
with System.Flyology.Contexts;

--  Exercise System.Flyology.Contexts.Create with stack sizes whose page
--  round-up, arena stride, or arena mapping length cannot be represented in
--  size_t. Each scenario runs in its own process because an accepted
--  unrepresentable size hands the caller a stack with no writable bytes, and
--  initializing the register image on that stack faults on architectures
--  whose entry convention stores below the stack top.
procedure Stack_Size_Limits_Child is
   package C renames Interfaces.C;
   package Contexts renames System.Flyology.Contexts;
   package Observation renames Flyology.Observability;

   use type System.Address;
   use type C.size_t;
   use type Contexts.Context_Access;
   use type Observation.Counter;

   procedure Immediate_Exit (Status : C.int);
   pragma Import (C, Immediate_Exit, "_exit");

   function Get_Page_Size return C.int;
   pragma Import (C, Get_Page_Size, "getpagesize");

   --  System.Flyology.Contexts requests at least this much guard space per
   --  stack, rounded up to the host page size.
   Guard_Bytes : constant C.size_t := 64 * 1_024;

   --  Never entered. Create only records the entry address.
   procedure Unreachable_Entry (Argument : System.Address);

   procedure Unreachable_Entry (Argument : System.Address) is
      pragma Unreferenced (Argument);
   begin
      raise Program_Error with "rejected context was dispatched";
   end Unreachable_Entry;

   function Page_Size return C.size_t is (C.size_t (Get_Page_Size));

   function Round_Up (Value, Alignment : C.size_t) return C.size_t is
     ((Value + Alignment - 1) / Alignment * Alignment);

   procedure Expect_Rejected (Requested : C.size_t);

   procedure Expect_Rejected (Requested : C.size_t) is
      Return_To : Contexts.Context_Access := Contexts.Capture;
      Item      : Contexts.Context_Access;
   begin
      Item :=
        Contexts.Create
          (Stack_Size => Requested,
           Start      => Unreachable_Entry'Address,
           Argument   => System.Null_Address,
           Return_To  => Return_To);
      if Item /= null then
         --  Accepting an unrepresentable size is the defect: the caller now
         --  holds a context whose stack has no writable bytes.
         Contexts.Destroy (Item);
         Contexts.Destroy (Return_To);
         Immediate_Exit (11);
      end if;
      Contexts.Destroy (Return_To);
   exception
      when others =>
         --  Create reports failure by returning null. An exception escaping
         --  the wrapped arena arithmetic instead leaks the context record and
         --  reaches callers that have no handler for it.
         Immediate_Exit (12);
   end Expect_Rejected;

   procedure Expect_Accepted (Requested : C.size_t);

   procedure Expect_Accepted (Requested : C.size_t) is
      Return_To : Contexts.Context_Access := Contexts.Capture;
      Item      : Contexts.Context_Access;
   begin
      Item :=
        Contexts.Create
          (Stack_Size => Requested,
           Start      => Unreachable_Entry'Address,
           Argument   => System.Null_Address,
           Return_To  => Return_To);
      if Item = null then
         Contexts.Destroy (Return_To);
         Immediate_Exit (13);
      end if;
      if Contexts.Stack_Size (Item) /= Round_Up (Requested, Page_Size)
        or else Contexts.Stack_Base (Item) = System.Null_Address
      then
         Contexts.Destroy (Item);
         Contexts.Destroy (Return_To);
         Immediate_Exit (14);
      end if;
      Contexts.Destroy (Item);
      Contexts.Destroy (Return_To);
   end Expect_Accepted;

   procedure Expect_Empty_Pool;

   procedure Expect_Empty_Pool is
      Pool : constant Observation.Stack_Pool_Snapshot :=
        Observation.Stack_Pool;
   begin
      --  A rejected request must retain no stack, arena, or reserved address
      --  space, and an accepted one must release both on Destroy.
      if Pool.Live_Stacks /= 0
        or else Pool.Active_Arenas /= 0
        or else Pool.Reserved_Bytes /= 0
        or else Pool.Arena_Unmappings /= Pool.Arena_Mappings
      then
         Immediate_Exit (15);
      end if;
   end Expect_Empty_Pool;
begin
   if Ada.Command_Line.Argument_Count /= 1 then
      return;
   end if;

   declare
      Scenario : constant String := Ada.Command_Line.Argument (1);
   begin
      if Scenario = "round-up-wrap" then
         --  The classic (size_t) -1 request. Rounding up to the page size
         --  wraps to zero usable bytes.
         Expect_Rejected (C.size_t'Last);
      elsif Scenario = "stride-wrap" then
         --  Page-aligned, so the round-up is exact; the per-slot stride
         --  usable + guard wraps to zero and divides the arena capacity.
         Expect_Rejected (C.size_t'Last - Guard_Bytes + 1);
      elsif Scenario = "mapping-wrap" then
         --  The stride is representable but the single-slot arena mapping
         --  length stride + guard is not.
         Expect_Rejected (C.size_t'Last - 2 * Guard_Bytes + 1);
      elsif Scenario = "unmappable" then
         --  Representable throughout, yet far larger than any host mapping.
         --  Create must still report failure through a null result.
         Expect_Rejected (C.size_t'Last / 4);
      elsif Scenario = "accepted" then
         Expect_Accepted (64 * 1_024);
      else
         Immediate_Exit (16);
      end if;
   end;

   Expect_Empty_Pool;
   Immediate_Exit (0);
exception
   when others =>
      Immediate_Exit (17);
end Stack_Size_Limits_Child;
