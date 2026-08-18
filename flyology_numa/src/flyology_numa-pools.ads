--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with System.Storage_Elements;
with System.Storage_Pools.Subpools;

with Flyology_NUMA.Placement;

--  Allocates from a chosen memory node.
--
--  Ada already has a place to say where an object's memory comes from: the
--  storage pool of its access type. This package supplies one whose
--  subpools are memory nodes, so the node an object lives on is named at
--  the point it is created:
--
--     Arena : Node_Pool (Policy => Flyology_NUMA.Placement.Bound,
--                        Extent => 1024 * 1024);
--     type Sample_Access is access Sample
--       with Storage_Pool => Arena;
--
--     Item : constant Sample_Access :=
--       new (On_Node (Arena, Near)) Sample'(...);
--
--  The pool asks the host for whole pages and places each of them before
--  handing any out, so an object allocated from a node's subpool comes from
--  that node rather than merely being intended for it. How firmly depends on
--  the policy: Bound draws only from the node, while Preferred lets the host
--  draw from elsewhere when the node cannot satisfy the request.
--
--  Allocation succeeds whether or not placement did. A host that cannot
--  place memory, and a host that refuses this process the placement it
--  asked for, both still serve the allocation from wherever they choose;
--  memory in the wrong place runs, and no memory does not. Placement_Reached
--  reports which happened.
--
--  A pool is not task safe. Allocating from one subpool in two tasks at once
--  can hand both the same address. Give each task its own pool, or serialize
--  the allocations, or use this only where one task allocates.
package Flyology_NUMA.Pools is

   --  A reference to one of a pool's subpools, which for this pool is one
   --  of its memory nodes.
   subtype Subpool_Handle is
     System.Storage_Pools.Subpools.Subpool_Handle;

   --  The placement policies that draw memory from a named set of nodes.
   --
   --  A pool exists to put memory on a node, so the two policies that name
   --  no node are not among the ones it can be given. Asking for memory from
   --  wherever the host likes needs no pool of this kind.
   subtype Binding_Policy is Placement.Policy_Kind
     range Placement.Preferred .. Placement.Interleaved;

   --  A storage pool whose subpools are memory nodes.
   --
   --  Memory is handed out by advancing through pages already obtained, and
   --  is returned to the host only when a subpool is deallocated or the
   --  pool goes out of scope. Freeing one object does nothing; this suits
   --  a body of memory built up and then discarded together, which is what
   --  a node-bound arena usually is.
   --
   --  Policy says how pages are drawn from the node a subpool stands for.
   --  Extent says how much memory to obtain at a time; a request larger than
   --  that obtains what it needs instead.
   --
   --  Allocation raises Storage_Error when the host will give the pool no
   --  more memory, and Program_Error when an allocation names no subpool.
   type Node_Pool
     (Policy : Binding_Policy;
      Extent : Byte_Count)
   is new System.Storage_Pools.Subpools.Root_Storage_Pool_With_Subpools
     with private;

   --  Return the subpool of Pool that draws memory from Node.
   --
   --  The subpool is made on first use and lives until Pool does. Asking
   --  again for the same node returns the same subpool.
   --  @param Pool The pool to take the subpool from.
   --  @param Node The node the subpool should draw memory from.
   --  @return The subpool for that node.
   function On_Node
     (Pool : in out Node_Pool; Node : Node_Id) return Subpool_Handle;

   --  Report whether the host accepted the placement of every page this
   --  node's subpool has obtained.
   --
   --  False means the host has no placement, or refused this process the
   --  placement it asked for, and the pages came from wherever the host
   --  chose. It does not mean allocation failed. False is also the answer
   --  before any page has been obtained, there being nothing placed yet.
   --
   --  True means the host accepted the request, which under Bound means the
   --  pages are on that node. Under Preferred the host was free to draw from
   --  elsewhere for pages the node could not satisfy.
   --  @param Pool The pool to inspect.
   --  @param Node The node whose subpool to inspect.
   --  @return True when the host accepted placement of every page obtained.
   function Placement_Reached
     (Pool : Node_Pool; Node : Node_Id) return Boolean;

   --  Return the number of bytes Pool has obtained from the host for Node.
   --  @param Pool The pool to inspect.
   --  @param Node The node whose subpool to inspect.
   --  @return Bytes obtained, including any not yet handed out.
   function Reserved_Bytes
     (Pool : Node_Pool; Node : Node_Id) return Byte_Count;

private

   package Subpools renames System.Storage_Pools.Subpools;

   use type System.Storage_Elements.Storage_Count;

   type Page_Run;

   type Page_Run_Access is access Page_Run;

   --  One block of pages obtained from the host and handed out by advancing
   --  through it.
   type Page_Run is record
      Base   : System.Address := System.Null_Address;
      Extent : Byte_Count     := 0;
      Used   : Byte_Count     := 0;
      Placed : Boolean        := False;
      Next   : Page_Run_Access;
   end record;

   type Node_Subpool is new Subpools.Root_Subpool with record
      Node : Node_Id := Node_Id'First;
      Runs : Page_Run_Access;
   end record;

   --  The subpools live in the pool rather than on the heap.  A subpool
   --  handle is a plain reference by definition, so a subpool cannot be
   --  created through one, and a node's subpool lasts exactly as long as
   --  the pool it belongs to anyway.
   type Subpool_Table is array (Node_Id) of aliased Node_Subpool;

   type Presence_Table is array (Node_Id) of Boolean;

   type Node_Pool
     (Policy : Binding_Policy;
      Extent : Byte_Count)
   is new Subpools.Root_Storage_Pool_With_Subpools with record
      Table   : Subpool_Table;
      Present : Presence_Table := (others => False);
   end record;

   --  Hand out storage from the node a subpool stands for. The runtime
   --  calls this for an allocation that names a subpool.
   --  @param Pool The pool the subpool belongs to.
   --  @param Storage_Address The address handed out.
   --  @param Size_In_Storage_Elements How much storage to hand out.
   --  @param Alignment The alignment the storage must begin on.
   --  @param Subpool The subpool to draw from.
   --  @exclude
   overriding procedure Allocate_From_Subpool
     (Pool                     : in out Node_Pool;
      Storage_Address          : out System.Address;
      Size_In_Storage_Elements : System.Storage_Elements.Storage_Count;
      Alignment                : System.Storage_Elements.Storage_Count;
      Subpool                  : not null Subpool_Handle);

   --  Make a subpool without naming a node, which draws from the lowest
   --  node this process may use. On_Node names one.
   --  @param Pool The pool to make the subpool in.
   --  @return The subpool for that node.
   --  @exclude
   overriding function Create_Subpool
     (Pool : in out Node_Pool) return not null Subpool_Handle;

   --  Return a subpool's pages to the host. The runtime calls this from
   --  Ada.Unchecked_Deallocate_Subpool and when the pool is finalized.
   --  @param Pool The pool the subpool belongs to.
   --  @param Subpool The subpool whose pages to return.
   --  @exclude
   overriding procedure Deallocate_Subpool
     (Pool    : in out Node_Pool;
      Subpool : in out Subpool_Handle);

end Flyology_NUMA.Pools;
