--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Interfaces.C;

--  A host with no memory-placement interface.
--
--  macOS is such a host: it describes no memory-node structure and offers
--  nothing that would draw memory from a chosen part of the machine. So is
--  any host this package has not been taught to place memory on.
--
--  Every operation reports Not_Supported rather than succeeding quietly. A
--  quiet success would tell a caller its memory had been placed somewhere
--  particular, which on this host is not true of anywhere.
package body Flyology_NUMA.Placement is

   use type Interfaces.C.int;

   function Page_Bytes return Interfaces.C.int
     with Import, Convention => C, External_Name => "getpagesize";

   --  The page size is still worth reporting: a caller aligning its own
   --  memory needs it whether or not the host can place that memory.
   Detected_Page : constant Byte_Count :=
     (if Page_Bytes > 0 then Byte_Count (Page_Bytes) else 4096);

   -------------
   -- Support --
   -------------

   function Support return Support_Level is (Unsupported_Host);

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
      pragma Unreferenced (Base, Length, Policy, Nodes, Move);
   begin
      Result := Not_Supported;
   end Apply_To;

   ---------------------
   -- Apply_To_Thread --
   ---------------------

   procedure Apply_To_Thread
     (Policy : Policy_Kind;
      Nodes  : Node_Set;
      Result : out Placement_Outcome)
   is
      pragma Unreferenced (Policy, Nodes);
   begin
      Result := Not_Supported;
   end Apply_To_Thread;

   ---------------------
   -- Node_Of_Address --
   ---------------------

   function Node_Of_Address (Location : System.Address) return Node_Query is
      pragma Unreferenced (Location);
   begin
      return No_Node;
   end Node_Of_Address;

   ---------------------
   -- Permitted_Nodes --
   ---------------------

   function Permitted_Nodes return Node_Set is
      Empty : Node_Set;
   begin
      return Empty;
   end Permitted_Nodes;

end Flyology_NUMA.Placement;
