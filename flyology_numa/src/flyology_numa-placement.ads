--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with System;

--  Places memory on chosen nodes.
--
--  The parent package reports what the host has. This package acts on it.
--  The two are separate because reading a description always succeeds and
--  acting on one often does not: a host may have no placement interface at
--  all, and a process may be refused the one its host has.
--
--  Support reports which of those applies before anything is attempted, and
--  every operation reports its own outcome. Nothing here raises.
--
--  Placement governs where pages come from. It does not move a running
--  thread; a thread is placed with the CPU aspect or a dispatching domain,
--  using the processors the parent package reports for a node.

package Flyology_NUMA.Placement is

   --  Whether this process can place memory on this host.
   --
   --  @enum Supported The host provides placement and this process may use
   --     it.
   --  @enum Unsupported_Host The host has no memory-placement interface.
   --     macOS is such a host, and so is a Linux host built without
   --     memory-node support or running an architecture this package does
   --     not know the placement calls for.
   --  @enum Denied The host provides placement and this process is not
   --     permitted to use it. A container sandbox commonly causes this: the
   --     machine underneath has memory nodes, and the process may not act on
   --     them. It is not the same as a host without the facility.
   type Support_Level is (Supported, Unsupported_Host, Denied);

   --  Report whether this process can place memory.
   --  @return What this process may do on this host.
   function Support return Support_Level;

   --  How pages should be drawn from a set of nodes.
   --
   --  @enum Preferred Draw from the lowest-numbered node in the set, and
   --     from elsewhere rather than fail when it cannot satisfy the
   --     request. The host's interface takes one node here, so any further
   --     node in the set contributes nothing. Use Bound or Interleaved to
   --     name several.
   --  @enum Bound Draw only from the set. A request the set cannot satisfy
   --     fails rather than drawing from elsewhere, which can mean running
   --     out of memory while other nodes still have some.
   --  @enum Interleaved Draw from the set in rotation, one page at a time.
   --     This trades the latency of a nearby node for the combined transfer
   --     rate of several, which suits memory read by every node at once.
   --  @enum Local Draw from the node of whichever processor first touches
   --     each page. The node set is not used.
   --  @enum Unrestricted Remove any policy and return to the host default.
   --     The node set is not used.
   type Policy_Kind is (Preferred, Bound, Interleaved, Local, Unrestricted);

   --  What became of a placement request.
   --
   --  @enum Applied The host accepted the request.
   --  @enum Not_Supported This host has no memory-placement interface.
   --  @enum Not_Permitted This process may not place memory, or may not
   --     place it on the nodes it asked for.
   --  @enum Unusable_Nodes The node set is empty, or names a node the host
   --     does not have online, when the policy needs one.
   --  @enum Unaligned The range does not begin on a page boundary. Placement
   --     acts on whole pages, so a range that begins inside one cannot be
   --     placed. Page_Size reports the boundary to use.
   --  @enum Insufficient_Memory The host could not satisfy the request.
   --  @enum Failed The host refused the request for another reason.
   type Placement_Outcome is
     (Applied, Not_Supported, Not_Permitted, Unusable_Nodes, Unaligned, Insufficient_Memory, Failed);

   --  Return the page size that placement acts in units of.
   --
   --  A range passed to Apply_To must begin on a multiple of this, and is
   --  placed up to the page boundary at or beyond its end.
   --  @return The host page size in bytes.
   function Page_Size return Byte_Count;

   --  Place the pages of a memory range on Nodes.
   --
   --  This governs pages the range acquires from now on. Pages it already
   --  holds stay where they are unless Move is requested.
   --
   --  Move is a request, not a guarantee. Pages shared with another process
   --  are left alone, and Applied reports that the host accepted the policy
   --  rather than that every page moved. Node_Of_Address reports where a
   --  particular page actually ended up.
   --
   --  Base must begin on a Page_Size boundary; the range extends to the page
   --  boundary at or beyond Base + Length.
   --
   --  @param Base First byte of the range, on a page boundary.
   --  @param Length Number of bytes in the range.
   --  @param Policy How pages should be drawn from Nodes.
   --  @param Nodes The nodes to draw from. Ignored for Local and
   --     Unrestricted.
   --  @param Move Whether to move the pages the range already holds.
   --  @param Result What became of the request.
   procedure Apply_To
     (Base   : System.Address;
      Length : Byte_Count;
      Policy : Policy_Kind;
      Nodes  : Node_Set;
      Move   : Boolean := False;
      Result : out Placement_Outcome);

   --  Place the memory this thread acquires from now on.
   --
   --  This governs later allocations by the calling thread, whatever their
   --  source. It does not move memory the thread already holds, and a thread
   --  created afterwards inherits it.
   --
   --  @param Policy How pages should be drawn from Nodes.
   --  @param Nodes The nodes to draw from. Ignored for Local and
   --     Unrestricted.
   --  @param Result What became of the request.
   procedure Apply_To_Thread (Policy : Policy_Kind; Nodes : Node_Set; Result : out Placement_Outcome);

   --  Report which node holds the page containing an address.
   --
   --  Asking this of a page the process has not yet touched causes it to be
   --  acquired, because the host answers by placing the page. Ask only about
   --  memory already written to.
   --
   --  @param Location An address within the page to ask about.
   --  @return The node holding that page, or No_Node.
   function Node_Of_Address (Location : System.Address) return Node_Query;

   --  Report the nodes this process may place memory on, as the host says
   --  now rather than as it said when the parent package was elaborated.
   --
   --  This differs from Allowed_Nodes when the process was moved between
   --  control groups after it started.
   --  @return The permitted node set, empty when the host does not say.
   function Permitted_Nodes return Node_Set;

end Flyology_NUMA.Placement;
