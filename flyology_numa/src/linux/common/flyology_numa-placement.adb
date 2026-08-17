--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Unchecked_Conversion;
with Interfaces.C;

with Flyology_NUMA.Bits;
with Flyology_NUMA.Syscall_Numbers;

pragma Elaborate (Flyology_NUMA.Bits);

--  Linux places memory through calls that no C library wraps.  The manual
--  pages for them describe a separate library's wrappers, not the library
--  every program already links, so they are reached through the generic
--  system-call entry point using the numbers this architecture assigns.
package body Flyology_NUMA.Placement is

   use type Interfaces.C.int;
   use type Interfaces.C.long;
   use type Interfaces.C.unsigned_long;

   subtype Long is Interfaces.C.long;
   subtype Unsigned_Long is Interfaces.C.unsigned_long;

   --  Policy modes.
   Mode_Default    : constant Long := 0;
   Mode_Preferred  : constant Long := 1;
   Mode_Bound      : constant Long := 2;
   Mode_Interleave : constant Long := 3;
   Mode_Local      : constant Long := 4;

   --  Ask that pages the range already holds be moved, not only that later
   --  ones be drawn from the named nodes.
   Flag_Move : constant Long := 2;

   --  Ask what node holds a page, rather than what policy governs it.
   Flag_Node : constant Long := 1;

   --  Read the policy of a named address rather than of the thread.
   Flag_Address : constant Long := 2;

   --  Read the nodes this process is permitted to use.
   Flag_Permitted : constant Long := 4;

   --  Error numbers.  Linux gives these the same values on every
   --  architecture this package records call numbers for.
   Error_Permission : constant Interfaces.C.int := 1;
   Error_Memory     : constant Interfaces.C.int := 12;
   Error_Access     : constant Interfaces.C.int := 13;
   Error_Invalid    : constant Interfaces.C.int := 22;
   Error_No_Call    : constant Interfaces.C.int := 38;

   Bits_Per_Long : constant := Unsigned_Long'Size;

   --  The node-bit count handed to the kernel when placing memory.
   --
   --  The kernel decrements this before reading, so a count equal to the
   --  number of bits meant would drop the highest one.  One more than the
   --  highest node number this package represents therefore names every
   --  node it can name, and still asks the kernel to read only the eight
   --  bytes the mask actually has.
   Placing_Bits : constant Long := Max_Node + 2;

   Mask_Words : constant :=
     ((Max_Node + 1) + Bits_Per_Long - 1) / Bits_Per_Long;

   type Node_Mask is
     array (0 .. Mask_Words - 1) of aliased Unsigned_Long;

   Empty_Mask : constant Node_Mask := (others => 0);

   --  Reading the permitted nodes is bounded differently: the kernel
   --  refuses a count below the number of nodes the host could ever have,
   --  which counts nodes that are merely possible and not only those
   --  online.  A host with room for more nodes than this package represents
   --  would otherwise refuse to answer at all, so the reading buffer covers
   --  the largest node count Linux can be built for and nodes above the
   --  represented range are left out of the answer.
   Reading_Bits : constant Long := 1025;

   Reading_Words : constant := 1024 / Bits_Per_Long;

   type Reading_Mask is
     array (0 .. Reading_Words - 1) of aliased Unsigned_Long;

   type Error_Pointer is access all Interfaces.C.int with Convention => C;

   --  Both C libraries this package is built against name the calling
   --  thread's error cell through this function.
   function Error_Location return Error_Pointer
     with Import, Convention => C, External_Name => "__errno_location";

   function Page_Bytes return Interfaces.C.int
     with Import, Convention => C, External_Name => "getpagesize";

   --  The generic system-call entry point takes one fixed argument and then
   --  as many as the call needs, so each shape it is used in is declared
   --  with the variadic convention for one fixed argument.
   function Call_Three
     (Number : Long;
      First  : Long;
      Second : Long;
      Third  : Long) return Long
     with Import, Convention => C_Variadic_1, External_Name => "syscall";

   function Call_Five
     (Number : Long;
      First  : Long;
      Second : Long;
      Third  : Long;
      Fourth : Long;
      Fifth  : Long) return Long
     with Import, Convention => C_Variadic_1, External_Name => "syscall";

   function Call_Six
     (Number : Long;
      First  : Long;
      Second : Long;
      Third  : Long;
      Fourth : Long;
      Fifth  : Long;
      Sixth  : Long) return Long
     with Import, Convention => C_Variadic_1, External_Name => "syscall";

   function To_Long is
     new Ada.Unchecked_Conversion (System.Address, Long);

   function Last_Error return Interfaces.C.int is (Error_Location.all);

   function To_Mask (Nodes : Node_Set) return Node_Mask;

   function From_Mask (Mask : Reading_Mask) return Node_Set;

   function Mode_Of (Policy : Policy_Kind) return Long;

   function Outcome_Of_Error return Placement_Outcome;

   function Detect_Support return Support_Level;

   -------------
   -- To_Mask --
   -------------

   function To_Mask (Nodes : Node_Set) return Node_Mask is
      Result : Node_Mask := Empty_Mask;
      Word   : Natural;
      Offset : Natural;
   begin
      for Node in Node_Id loop
         if Bits.Contains (Nodes, Node) then
            Word := Natural (Node) / Bits_Per_Long;
            Offset := Natural (Node) mod Bits_Per_Long;
            Result (Word) := Result (Word) or (Unsigned_Long (2) ** Offset);
         end if;
      end loop;

      return Result;
   end To_Mask;

   ---------------
   -- From_Mask --
   ---------------

   function From_Mask (Mask : Reading_Mask) return Node_Set is
      Result : Node_Set;
      Word   : Natural;
      Offset : Natural;
   begin
      for Node in Node_Id loop
         Word := Natural (Node) / Bits_Per_Long;
         Offset := Natural (Node) mod Bits_Per_Long;

         if (Mask (Word) and (Unsigned_Long (2) ** Offset)) /= 0 then
            Bits.Include (Result, Node);
         end if;
      end loop;

      return Result;
   end From_Mask;

   -------------
   -- Mode_Of --
   -------------

   --  Report whether the kernel expects a node set with this policy.  It
   --  refuses either of the other two when one arrives, so the spec's
   --  promise that their node argument is ignored has to be kept here.
   function Takes_Nodes (Policy : Policy_Kind) return Boolean is
     (Policy in Preferred | Bound | Interleaved);

   function Mode_Of (Policy : Policy_Kind) return Long is
     (case Policy is
         when Preferred    => Mode_Preferred,
         when Bound        => Mode_Bound,
         when Interleaved  => Mode_Interleave,
         when Local        => Mode_Local,
         when Unrestricted => Mode_Default);

   ----------------------
   -- Outcome_Of_Error --
   ----------------------

   function Outcome_Of_Error return Placement_Outcome is
      Reason : constant Interfaces.C.int := Last_Error;
   begin
      if Reason = Error_Permission or else Reason = Error_Access then
         return Not_Permitted;
      elsif Reason = Error_No_Call then
         return Not_Supported;
      elsif Reason = Error_Memory then
         return Insufficient_Memory;
      elsif Reason = Error_Invalid then
         --  The node set is by far the likeliest part of a request the
         --  kernel calls invalid, so it is named rather than left generic.
         return Unusable_Nodes;
      else
         return Failed;
      end if;
   end Outcome_Of_Error;

   --------------------
   -- Detect_Support --
   --------------------

   function Detect_Support return Support_Level is
      Mode   : aliased Interfaces.C.int := 0;
      Answer : Long;
      Reason : Interfaces.C.int;
   begin
      if not Syscall_Numbers.Known then
         return Unsupported_Host;
      end if;

      --  Reading this thread's own policy changes nothing, so it is a safe
      --  way to learn whether the call is available and permitted.
      Answer :=
        Call_Five
          (Syscall_Numbers.Get_Mempolicy, To_Long (Mode'Address), 0, 0, 0, 0);

      if Answer = 0 then
         return Supported;
      end if;

      Reason := Last_Error;

      if Reason = Error_Permission or else Reason = Error_Access then
         return Denied;
      end if;

      --  A host that described its own memory nodes has the calls that act
      --  on them.  A refusal from such a host came from something between
      --  this process and the kernel, whatever error that something chose
      --  to report, so it is a denial rather than an absence.  Sandboxes
      --  that answer a refused call with "no such call" are the reason this
      --  is not decided on the error number alone.
      if Flyology_NUMA.Support.Source = Host_Report then
         return Denied;
      end if;

      return Unsupported_Host;
   exception
      when others =>
         return Unsupported_Host;
   end Detect_Support;

   --  Support is settled on first use rather than while this package
   --  elaborates.  A sandbox that answers a refused call by ending the
   --  process would otherwise end any program that merely links this crate,
   --  including one that never places any memory.  Settling it later also
   --  lets the answer take account of what the host said about its nodes.
   type Settled_Level is
     (Unsettled, Settled_Supported, Settled_Unsupported, Settled_Denied);

   Cache : Settled_Level := Unsettled with Atomic;

   Detected_Page : constant Byte_Count :=
     (if Page_Bytes > 0 then Byte_Count (Page_Bytes) else 4096);

   -------------
   -- Support --
   -------------

   function Support return Support_Level is
      Known : constant Settled_Level := Cache;
      Found : Support_Level;
   begin
      case Known is
         when Settled_Supported   => return Supported;
         when Settled_Unsupported => return Unsupported_Host;
         when Settled_Denied      => return Denied;
         when Unsettled           => null;
      end case;

      Found := Detect_Support;

      --  Two threads arriving together settle on the same answer, so a
      --  second settling repeats a query and changes nothing.
      Cache :=
        (case Found is
            when Supported        => Settled_Supported,
            when Unsupported_Host => Settled_Unsupported,
            when Denied           => Settled_Denied);

      return Found;
   end Support;

   ---------------
   -- Page_Size --
   ---------------

   function Page_Size return Byte_Count is (Detected_Page);

   --------------
   -- Apply_To --
   --------------

   procedure Apply_To
     (Base   : System.Address;
      Length : Byte_Count;
      Policy : Policy_Kind;
      Nodes  : Node_Set;
      Move   : Boolean := False;
      Result : out Placement_Outcome)
   is
      Mask   : aliased Node_Mask;
      Flags  : Long := 0;
      Answer : Long;
   begin
      case Support is
         when Unsupported_Host =>
            Result := Not_Supported;
            return;
         when Denied =>
            Result := Not_Permitted;
            return;
         when Supported =>
            null;
      end case;

      if Takes_Nodes (Policy) and then Bits.Is_Empty (Nodes) then
         Result := Unusable_Nodes;
         return;
      end if;

      if To_Long (Base) mod Long (Detected_Page) /= 0 then
         Result := Unaligned;
         return;
      end if;

      Mask := (if Takes_Nodes (Policy) then To_Mask (Nodes) else Empty_Mask);

      if Move then
         Flags := Flag_Move;
      end if;

      Answer :=
        Call_Six
          (Syscall_Numbers.Mbind,
           To_Long (Base),
           Long (Length),
           Mode_Of (Policy),
           To_Long (Mask'Address),
           Placing_Bits,
           Flags);

      Result := (if Answer = 0 then Applied else Outcome_Of_Error);
   exception
      when others =>
         Result := Failed;
   end Apply_To;

   ---------------------
   -- Apply_To_Thread --
   ---------------------

   procedure Apply_To_Thread
     (Policy : Policy_Kind;
      Nodes  : Node_Set;
      Result : out Placement_Outcome)
   is
      Mask   : aliased Node_Mask;
      Answer : Long;
   begin
      case Support is
         when Unsupported_Host =>
            Result := Not_Supported;
            return;
         when Denied =>
            Result := Not_Permitted;
            return;
         when Supported =>
            null;
      end case;

      if Takes_Nodes (Policy) and then Bits.Is_Empty (Nodes) then
         Result := Unusable_Nodes;
         return;
      end if;

      Mask := (if Takes_Nodes (Policy) then To_Mask (Nodes) else Empty_Mask);

      Answer :=
        Call_Three
          (Syscall_Numbers.Set_Mempolicy,
           Mode_Of (Policy),
           To_Long (Mask'Address),
           Placing_Bits);

      Result := (if Answer = 0 then Applied else Outcome_Of_Error);
   exception
      when others =>
         Result := Failed;
   end Apply_To_Thread;

   ---------------------
   -- Node_Of_Address --
   ---------------------

   function Node_Of_Address (Location : System.Address) return Node_Query is
      Node   : aliased Interfaces.C.int := 0;
      Answer : Long;
   begin
      if Support /= Supported then
         return No_Node;
      end if;

      Answer :=
        Call_Five
          (Syscall_Numbers.Get_Mempolicy,
           To_Long (Node'Address),
           0,
           0,
           To_Long (Location),
           Flag_Node + Flag_Address);

      if Answer /= 0
        or else Node < 0
        or else Node > Interfaces.C.int (Max_Node)
      then
         return No_Node;
      end if;

      return (Available => True, Node => Node_Id (Node));
   exception
      when others =>
         return No_Node;
   end Node_Of_Address;

   ---------------------
   -- Permitted_Nodes --
   ---------------------

   function Permitted_Nodes return Node_Set is
      Mask   : aliased Reading_Mask := (others => 0);
      Empty  : Node_Set;
      Answer : Long;
   begin
      if Support /= Supported then
         return Empty;
      end if;

      Answer :=
        Call_Five
          (Syscall_Numbers.Get_Mempolicy,
           0,
           To_Long (Mask'Address),
           Reading_Bits,
           0,
           Flag_Permitted);

      if Answer /= 0 then
         return Empty;
      end if;

      return From_Mask (Mask);
   exception
      when others =>
         return Empty;
   end Permitted_Nodes;

end Flyology_NUMA.Placement;
