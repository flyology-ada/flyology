--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Unchecked_Deallocation;

with Flyology_NUMA.Bits;
with Flyology_NUMA.Mapping;

package body Flyology_NUMA.Pools is

   use type System.Address;
   use type System.Storage_Elements.Integer_Address;
   use type Placement.Placement_Outcome;

   package Elements renames System.Storage_Elements;

   procedure Free is new Ada.Unchecked_Deallocation (Page_Run, Page_Run_Access);

   function Owner (Subpool : not null Subpool_Handle) return Node_Id;

   procedure Obtain
     (Pool : in out Node_Pool; Holder : in out Node_Subpool; Wanted : Byte_Count; Success : out Boolean);

   procedure Discard (Runs : in out Page_Run_Access);

   -----------
   -- Owner --
   -----------

   function Owner (Subpool : not null Subpool_Handle) return Node_Id
   is (Node_Subpool (Subpool.all).Node);

   -------------
   -- Discard --
   -------------

   procedure Discard (Runs : in out Page_Run_Access) is
      Current : Page_Run_Access := Runs;
      Next    : Page_Run_Access;
   begin
      while Current /= null loop
         Next := Current.Next;
         Mapping.Release (Current.Base, Current.Extent);
         Free (Current);
         Current := Next;
      end loop;

      Runs := null;
   end Discard;

   ------------
   -- Obtain --
   ------------

   procedure Obtain
     (Pool : in out Node_Pool; Holder : in out Node_Subpool; Wanted : Byte_Count; Success : out Boolean)
   is
      Extent  : constant Byte_Count := Mapping.Whole_Pages (Byte_Count'Max (Wanted, Pool.Extent));
      Base    : System.Address;
      Outcome : Placement.Placement_Outcome;
      Run     : Page_Run_Access;
      Nodes   : Node_Set;
   begin
      Success := False;

      if Extent = 0 then
         return;
      end if;

      Base := Mapping.Reserve (Extent);

      if Base = System.Null_Address then
         return;
      end if;

      --  The pages are placed before any of them is handed out.  Placing
      --  them afterwards would leave whatever had already been written
      --  where the host first put it.
      Bits.Include (Nodes, Holder.Node);

      Placement.Apply_To
        (Base => Base, Length => Extent, Policy => Pool.Policy, Nodes => Nodes, Result => Outcome);

      --  The memory is usable whatever the host said; only its whereabouts
      --  may not be what was asked for.  Each block records what happened to
      --  it, which is what Placement_Reached reads.

      begin
         Run :=
           new Page_Run'
             (Base   => Base,
              Extent => Extent,
              Used   => 0,
              Placed => Outcome = Placement.Applied,
              Next   => Holder.Runs);
      exception
         --  The pages were obtained and cannot now be recorded, so they go
         --  back rather than staying reserved with nothing naming them.
         when others =>
            Mapping.Release (Base, Extent);
            return;
      end;

      Holder.Runs := Run;
      Success := True;
   end Obtain;

   -------------
   -- On_Node --
   -------------

   function On_Node (Pool : in out Node_Pool; Node : Node_Id) return Subpool_Handle is
   begin
      if not Pool.Present (Node) then
         Pool.Table (Node).Node := Node;
         Subpools.Set_Pool_Of_Subpool (Pool.Table (Node)'Unchecked_Access, Pool);
         Pool.Present (Node) := True;
      end if;

      return Pool.Table (Node)'Unchecked_Access;
   end On_Node;

   --------------------
   -- Create_Subpool --
   --------------------

   --  A subpool with no node named draws from the lowest node this process
   --  may use, which is the only node on a host with one memory domain.
   overriding
   function Create_Subpool (Pool : in out Node_Pool) return not null Subpool_Handle is
      Permitted : constant Node_Set := Allowed_Nodes;
   begin
      return On_Node (Pool, Bits.Element (Permitted, Bits.First (Permitted)));
   end Create_Subpool;

   -----------------------------
   -- Allocate_From_Subpool --
   -----------------------------

   overriding
   procedure Allocate_From_Subpool
     (Pool                     : in out Node_Pool;
      Storage_Address          : out System.Address;
      Size_In_Storage_Elements : Elements.Storage_Count;
      Alignment                : Elements.Storage_Count;
      Subpool                  : not null Subpool_Handle)
   is
      Holder  : Node_Subpool renames Node_Subpool (Subpool.all);
      --  An allocation of nothing still needs an address no other
      --  allocation holds, so it is served a byte.
      Wanted  : constant Byte_Count := Byte_Count'Max (Byte_Count (Size_In_Storage_Elements), 1);
      Step    : constant Byte_Count := Byte_Count (Elements.Storage_Count'Max (Alignment, 1));
      Success : Boolean;
   begin
      Storage_Address := System.Null_Address;

      --  A subpool of another pool would be handed out memory this pool
      --  does not own and would not release.  The subpools live inside the
      --  pool, so belonging to it means being one of them.
      if not Pool.Present (Holder.Node) or else Subpool.all'Address /= Pool.Table (Holder.Node)'Address then
         raise Program_Error with "subpool belongs to another pool";
      end if;

      for Attempt in 1 .. 2 loop
         if Holder.Runs /= null then
            declare
               Run   : Page_Run renames Holder.Runs.all;
               Start : constant Elements.Integer_Address :=
                 Elements.To_Integer (Run.Base) + Elements.Integer_Address (Run.Used);
               Skew  : constant Elements.Integer_Address := Start mod Elements.Integer_Address (Step);
               Pad   : constant Byte_Count :=
                 (if Skew = 0 then 0 else Byte_Count (Elements.Integer_Address (Step) - Skew));
            begin
               if Wanted <= Run.Extent - Run.Used and then Pad <= Run.Extent - Run.Used - Wanted then
                  Run.Used := Run.Used + Pad;
                  Storage_Address := Run.Base + Elements.Storage_Offset (Run.Used);
                  Run.Used := Run.Used + Wanted;
                  return;
               end if;
            end;
         end if;

         --  The current block cannot hold this, so another is obtained and
         --  the placement is tried once more against it.
         exit when Attempt = 2;

         Obtain (Pool, Holder, Wanted + Step, Success);

         if not Success then
            raise Storage_Error with "no memory could be obtained for a node";
         end if;
      end loop;

      raise Storage_Error with "no memory could be obtained for a node";
   end Allocate_From_Subpool;

   ------------------------
   -- Deallocate_Subpool --
   ------------------------

   --  The pages go back to the host.  The subpool object itself is part of
   --  the pool and stays where it is, but the runtime has already detached
   --  it by the time this is reached, so the pool forgets it too: asking for
   --  this node again then claims the subpool afresh, which is what the
   --  runtime expects of a subpool it no longer owns.
   overriding
   procedure Deallocate_Subpool (Pool : in out Node_Pool; Subpool : in out Subpool_Handle) is
   begin
      Discard (Node_Subpool (Subpool.all).Runs);
      Pool.Present (Owner (Subpool)) := False;
   end Deallocate_Subpool;

   -----------------------
   -- Placement_Reached --
   -----------------------

   function Placement_Reached (Pool : Node_Pool; Node : Node_Id) return Boolean is
      Current : Page_Run_Access := Pool.Table (Node).Runs;
   begin
      if not Pool.Present (Node) or else Current = null then
         return False;
      end if;

      while Current /= null loop
         if not Current.Placed then
            return False;
         end if;

         Current := Current.Next;
      end loop;

      return True;
   end Placement_Reached;

   --------------------
   -- Reserved_Bytes --
   --------------------

   function Reserved_Bytes (Pool : Node_Pool; Node : Node_Id) return Byte_Count is
      Total   : Byte_Count := 0;
      Current : Page_Run_Access := Pool.Table (Node).Runs;
   begin

      while Current /= null loop
         Total := Total + Current.Extent;
         Current := Current.Next;
      end loop;

      return Total;
   end Reserved_Bytes;

end Flyology_NUMA.Pools;
