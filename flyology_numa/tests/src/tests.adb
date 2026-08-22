with Ada.Finalization;
with Ada.Text_IO;
with Ada.Unchecked_Deallocate_Subpool;
with Flyology_NUMA.Placement;
with Flyology_NUMA.Pools;
with Interfaces;
with System;
with System.Multiprocessors;
with System.Storage_Elements;
with Tests_Config;

--  Checks the description this package reports for the host running the
--  tests. The host is unknown, so these are invariants every host must
--  satisfy rather than values only one host would produce.

procedure Tests is

   package NUMA renames Flyology_NUMA;

   use type NUMA.Node_Id;
   use type NUMA.Distance;
   use type NUMA.Byte_Count;
   use type NUMA.Discovery_Source;
   use type Interfaces.Unsigned_8;
   use type NUMA.Placement.Support_Level;
   use type NUMA.Placement.Placement_Outcome;
   use type Interfaces.Unsigned_64;
   use type System.Multiprocessors.CPU_Range;

   procedure Check (Condition : Boolean; Message : String);

   function Is_macOS (Name : String) return Boolean;

   function Is_macOS (Name : String) return Boolean
   is (Name = "macos");

   function Places_Memory (Arch : String) return Boolean;

   --  The architectures this crate records placement call numbers for.
   function Places_Memory (Arch : String) return Boolean
   is (Arch = "x86_64" or else Arch = "aarch64" or else Arch = "riscv64");

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   Support    : constant NUMA.Support_Report := NUMA.Support;
   Online     : constant NUMA.Node_Set := NUMA.Online_Nodes;
   Allowed    : constant NUMA.Node_Set := NUMA.Allowed_Nodes;
   Processors : Natural := 0;
   Target     : NUMA.Node_Id := NUMA.Node_Id'First;
   Finalized  : Natural := 0;

begin
   --  Every host has at least one memory domain, including a host that has
   --  no memory-node structure at all.  Node_Count returns Positive, so an
   --  empty online set raises here rather than reporting zero nodes.
   Check (NUMA.Count (Online) = NUMA.Node_Count, "the online set disagrees with the node count");
   Check (NUMA.Count (Allowed) >= 1, "this process may use no node");

   --  A node this process may use is a node the host has.
   for Node of Allowed loop
      Check (NUMA.Is_Online (Node), "a permitted node is not among the online nodes");
   end loop;

   Check
     (Support.Restricted = (NUMA.Count (Allowed) < NUMA.Count (Online)),
      "the restriction report disagrees with the permitted set");

   --  A processor belongs to the node whose processor set holds it.
   for Node of Online loop
      for Processor of NUMA.Processors_Of (Node) loop
         declare
            Owner : constant NUMA.Node_Query := NUMA.Node_Of (Processor);
         begin
            Check (Owner.Available, "an attached processor names no node");
            Check (Owner.Node = Node, "a processor is attached to a node that disowns it");
         end;

         Check (NUMA.Has_Processors (Node), "a node with an attached processor reports none");

         Processors := Processors + 1;
      end loop;
   end loop;

   Check (Processors >= 1, "the host reports no processor");

   --  A node is nearer to itself than to any other node.
   for Node of Online loop
      declare
         Local : constant NUMA.Distance_Query := NUMA.Node_Distance (Node, Node);
      begin
         if Local.Available then
            for Other of Online loop
               declare
                  Away : constant NUMA.Distance_Query := NUMA.Node_Distance (Node, Other);
               begin
                  if Away.Available then
                     Check
                       (Local.Value <= Away.Value,
                        "a node is reported nearer to another node " & "than to itself");
                  end if;
               end;
            end loop;
         end if;
      end;
   end loop;

   --  A host that numbers its processors consecutively can name all of them
   --  as Ada processors, and a host that does not can name none.
   for Node of Online loop
      for Processor of NUMA.Processors_Of (Node) loop
         if Support.Consecutive_Processors then
            Check
              (NUMA.To_CPU (Processor) /= System.Multiprocessors.Not_A_Specific_CPU,
               "a consecutively numbered processor cannot be named");
         else
            Check
              (NUMA.To_CPU (Processor) = System.Multiprocessors.Not_A_Specific_CPU,
               "a processor was named despite a gap in host numbering");
         end if;
      end loop;
   end loop;

   --  A fallback describes exactly one node holding every processor.
   if Support.Source = NUMA.Single_Domain then
      Check (NUMA.Node_Count = 1, "a uniform host reports more than one node");
      Check (not Support.Restricted, "a uniform host reports a restriction");
   end if;

   --  macOS describes no memory-node structure and does report its memory.
   if Is_macOS (Tests_Config.Alire_Host_OS) then
      Check (Support.Source = NUMA.Single_Domain, "macOS was read as having memory nodes");
      Check (NUMA.Memory_Bytes (0).Available, "macOS did not report its memory size");
      Check (NUMA.Value_Or (NUMA.Memory_Bytes (0), 0) > 0, "macOS reported an empty memory size");
   end if;

   --  Placement acts on the description the parent package reports, and
   --  reports its own outcome for every attempt.
   declare
      use type System.Storage_Elements.Integer_Address;
      use type System.Storage_Elements.Storage_Offset;

      Page : constant NUMA.Byte_Count := NUMA.Placement.Page_Size;

      type Block is array (NUMA.Byte_Count range <>) of aliased Interfaces.Unsigned_8;
      type Block_Access is access Block;

      --  Two pages of room guarantee one whole page starting on a boundary
      --  somewhere inside, whatever the heap returned.
      Room    : constant Block_Access := new Block (1 .. 2 * Page);
      Start   : constant System.Address := Room (1)'Address;
      Skew    : constant System.Storage_Elements.Integer_Address :=
        System.Storage_Elements.To_Integer (Start) mod System.Storage_Elements.Integer_Address (Page);
      Aligned : constant System.Address :=
        (if Skew = 0
         then Start
         else
           Start
           + System.Storage_Elements.Storage_Offset (System.Storage_Elements.Integer_Address (Page) - Skew));

      Result : NUMA.Placement.Placement_Outcome;
      Empty  : NUMA.Node_Set;
   begin
      --  A host that described its own memory nodes has the calls that act
      --  on them, so reporting no way to place memory means the calls were
      --  not reached rather than that the host lacks them.  This is what
      --  catches a call number taken from the wrong architecture's table.
      if Support.Source = NUMA.Host_Report and then Places_Memory (Tests_Config.Alire_Host_Arch) then
         Check
           (NUMA.Placement.Support /= NUMA.Placement.Unsupported_Host,
            "a host describing memory nodes reported no way to use them");
      end if;

      Check (Page > 0, "the host reports no page size");
      Check (Page mod 4096 = 0, "the page size is not a whole number of " & "four-kilobyte pages");
      Check
        (System.Storage_Elements.To_Integer (Aligned) mod System.Storage_Elements.Integer_Address (Page) = 0,
         "the aligned address is not aligned");

      case NUMA.Placement.Support is
         when NUMA.Placement.Unsupported_Host =>
            --  Nothing is placed, and nothing pretends to have been.
            NUMA.Placement.Apply_To (Aligned, Page, NUMA.Placement.Interleaved, Allowed, Result => Result);
            Check (Result = NUMA.Placement.Not_Supported, "a host without placement reported a placement");

            --  No policy is placed, whichever one is asked for.
            for Policy in NUMA.Placement.Policy_Kind loop
               NUMA.Placement.Apply_To_Thread (Policy, Allowed, Result);
               Check
                 (Result = NUMA.Placement.Not_Supported, "a host without placement placed a thread's memory");
            end loop;

            Check
              (not NUMA.Placement.Node_Of_Address (Aligned).Available,
               "a host without placement named a node for an address");

         when NUMA.Placement.Denied           =>
            NUMA.Placement.Apply_To (Aligned, Page, NUMA.Placement.Interleaved, Allowed, Result => Result);
            Check (Result = NUMA.Placement.Not_Permitted, "a denied process reported a placement");

         when NUMA.Placement.Supported        =>
            --  A range that does not begin on a page boundary is refused
            --  before anything is asked of the host.
            NUMA.Placement.Apply_To
              (Aligned + 1, Page, NUMA.Placement.Interleaved, Allowed, Result => Result);
            Check (Result = NUMA.Placement.Unaligned, "an unaligned range was not refused");

            --  A policy that needs nodes cannot run without any.
            NUMA.Placement.Apply_To (Aligned, Page, NUMA.Placement.Bound, Empty, Result => Result);
            Check
              (Result = NUMA.Placement.Unusable_Nodes, "an empty node set was accepted for a bound policy");

            --  Every policy is exercised against the nodes this process may
            --  use, including one whose permitted set holds a single node.
            --
            --  Local and Unrestricted are given a node set on purpose. The
            --  host rejects a policy of either kind that arrives carrying
            --  one, so passing the set a caller naturally has to hand is
            --  what proves the set is dropped before the host sees it.
            for Policy in NUMA.Placement.Policy_Kind loop
               NUMA.Placement.Apply_To (Aligned, Page, Policy, Allowed, Result => Result);
               Check
                 (Result = NUMA.Placement.Applied,
                  "a permitted "
                  & NUMA.Placement.Policy_Kind'Image (Policy)
                  & " placement was refused: "
                  & NUMA.Placement.Placement_Outcome'Image (Result));
            end loop;

            NUMA.Placement.Apply_To (Aligned, Page, NUMA.Placement.Interleaved, Allowed, Result => Result);
            Check
              (Result = NUMA.Placement.Applied,
               "a permitted interleave was refused: " & NUMA.Placement.Placement_Outcome'Image (Result));

            --  Placing this thread's later allocations is a different host
            --  call from placing a range, and on some architectures its
            --  number sits where another call's number sits on others. A
            --  wrong number here would reach a working but unrelated
            --  service, so the call is made and its outcome checked.
            for Policy in NUMA.Placement.Policy_Kind loop
               NUMA.Placement.Apply_To_Thread (Policy, Allowed, Result);
               Check
                 (Result = NUMA.Placement.Applied,
                  "a permitted "
                  & NUMA.Placement.Policy_Kind'Image (Policy)
                  & " thread policy was refused: "
                  & NUMA.Placement.Placement_Outcome'Image (Result));
            end loop;

            NUMA.Placement.Apply_To_Thread (NUMA.Placement.Interleaved, Allowed, Result);
            Check
              (Result = NUMA.Placement.Applied,
               "a permitted thread policy was refused: " & NUMA.Placement.Placement_Outcome'Image (Result));

            NUMA.Placement.Apply_To_Thread (NUMA.Placement.Unrestricted, Empty, Result);
            Check (Result = NUMA.Placement.Applied, "releasing a thread policy was refused");

            --  Once the page is written to it exists somewhere, and that
            --  somewhere is a node this process may use.
            Room (1) := 1;

            declare
               Where : constant NUMA.Node_Query := NUMA.Placement.Node_Of_Address (Room (1)'Address);
            begin
               Check (Where.Available, "a written page was not reported on any node");
               Check (NUMA.Is_Online (Where.Node), "a page was reported on a node the host lacks");
            end;

            --  Returning the range to the host default must be accepted.
            NUMA.Placement.Apply_To (Aligned, Page, NUMA.Placement.Unrestricted, Empty, Result => Result);
            Check (Result = NUMA.Placement.Applied, "releasing a placement was refused");

            declare
               Permitted : constant NUMA.Node_Set := NUMA.Placement.Permitted_Nodes;
            begin
               Check (NUMA.Count (Permitted) >= 1, "a supported host permits no node");

               for Node of Permitted loop
                  Check (NUMA.Is_Online (Node), "a permitted node is not online");
               end loop;
            end;
      end case;

      Ada.Text_IO.Put_Line ("placement:  " & NUMA.Placement.Support_Level'Image (NUMA.Placement.Support));
      Ada.Text_IO.Put_Line ("page:       " & NUMA.Byte_Count'Image (Page));
   end;

   --  The lowest node this process may use serves as the pool's node.
   for Node of Allowed loop
      Target := Node;
      exit;
   end loop;

   --  A pool whose subpools are memory nodes.
   declare
      package Node_Pools renames NUMA.Pools;

      use type System.Storage_Elements.Integer_Address;
      use type System.Address;
      Count : constant := 400;

      --  A small extent on purpose, so that this many objects outgrow the
      --  first block and the pool has to obtain more than one.
      Arena : Node_Pools.Node_Pool (Policy => NUMA.Placement.Bound, Extent => 4096);

      type Sample is record
         Value : Interfaces.Unsigned_64;
         Rest  : Interfaces.Unsigned_64;
      end record;

      type Sample_Access is access Sample with Storage_Pool => Arena;

      Near   : constant NUMA.Node_Id := Target;
      Holder : constant Node_Pools.Subpool_Handle := Node_Pools.On_Node (Arena, Near);

      Items : array (1 .. Count) of Sample_Access;
   begin
      Check
        (Node_Pools.Reserved_Bytes (Arena, Near) = 0, "a pool reserved memory before it was asked for any");

      for Index in Items'Range loop
         Items (Index) := new (Holder) Sample'(Value => Interfaces.Unsigned_64 (Index), Rest => 0);
      end loop;

      --  The memory is real, distinct, and holds what was written to it.
      for Index in Items'Range loop
         Check
           (Items (Index).Value = Interfaces.Unsigned_64 (Index),
            "an allocated object did not keep its value");
         Check
           (System.Storage_Elements.To_Integer (Items (Index).all'Address) mod Sample'Alignment = 0,
            "an allocated object is not aligned for its type");

         if Index > 1 then
            Check
              (Items (Index).all'Address /= Items (Index - 1).all'Address,
               "two allocations shared one address");
         end if;
      end loop;

      Check
        (Node_Pools.Reserved_Bytes (Arena, Near) >= NUMA.Byte_Count (Count) * 16,
         "a pool reserved less memory than it handed out");

      --  Asking for a node that was never used costs nothing.
      for Node of Online loop
         if Node /= Near then
            Check (Node_Pools.Reserved_Bytes (Arena, Node) = 0, "an unused node reserved memory");
            Check
              (not Node_Pools.Placement_Reached (Arena, Node), "an unused node reported its memory placed");
         end if;
      end loop;

      --  On a host that places memory, the pages really are on the node the
      --  subpool names.  That is the whole point of the pool, so it is
      --  checked against the host rather than against the pool's own record.
      if NUMA.Placement.Support = NUMA.Placement.Supported then
         Check
           (Node_Pools.Placement_Reached (Arena, Near), "a placing host did not place a node pool's memory");

         for Index in 1 .. 8 loop
            declare
               Where : constant NUMA.Node_Query := NUMA.Placement.Node_Of_Address (Items (Index).all'Address);
            begin
               Check (Where.Available, "an allocated object was not reported on any node");
               Check (Where.Node = Near, "an object allocated for one node is held by another");
            end;
         end loop;
      else
         Check
           (not Node_Pools.Placement_Reached (Arena, Near),
            "a host without placement reported memory placed");
      end if;

      Ada.Text_IO.Put_Line ("pool node:  " & NUMA.Node_Id'Image (Near));
      Ada.Text_IO.Put_Line ("pool bytes: " & NUMA.Byte_Count'Image (Node_Pools.Reserved_Bytes (Arena, Near)));
      Ada.Text_IO.Put_Line ("pool placed:" & Boolean'Image (Node_Pools.Placement_Reached (Arena, Near)));
   end;

   --  Objects with finalization live in the pool's own pages, and so do the
   --  records the runtime keeps in order to finalize them. A pool that gave
   --  its pages back before the runtime had finished with them would take
   --  those records with it.
   declare
      package Node_Pools renames NUMA.Pools;

      type Marker is new Ada.Finalization.Controlled with null record;

      overriding
      procedure Finalize (Item : in out Marker);

      overriding
      procedure Finalize (Item : in out Marker) is
         pragma Unreferenced (Item);
      begin
         Finalized := Finalized + 1;
      end Finalize;
   begin
      declare
         Arena : Node_Pools.Node_Pool (Policy => NUMA.Placement.Bound, Extent => 4096);

         type Marker_Access is access Marker with Storage_Pool => Arena;

         Holder : constant Node_Pools.Subpool_Handle := Node_Pools.On_Node (Arena, Target);

         Kept : array (1 .. 5) of Marker_Access;
      begin
         for Index in Kept'Range loop
            Kept (Index) := new (Holder) Marker;
         end loop;

         Check (Finalized = 0, "an object was finalized while still in use");
      end;

      Check
        (Finalized = 5,
         "a pool going out of scope did not finalize what it held:" & Natural'Image (Finalized));
   end;

   --  A subpool given back and then asked for again.
   declare
      package Node_Pools renames NUMA.Pools;

      Arena : Node_Pools.Node_Pool (Policy => NUMA.Placement.Bound, Extent => 4096);

      type Count_Access is access Interfaces.Unsigned_64 with Storage_Pool => Arena;

      Holder : Node_Pools.Subpool_Handle := Node_Pools.On_Node (Arena, Target);
      First  : constant Count_Access := new (Holder) Interfaces.Unsigned_64'(7);
   begin
      Check (First.all = 7, "an allocation did not keep its value");
      Check (Node_Pools.Reserved_Bytes (Arena, Target) > 0, "a used node reserved no memory");

      Ada.Unchecked_Deallocate_Subpool (Holder);

      Check
        (Node_Pools.Reserved_Bytes (Arena, Target) = 0,
         "a node kept memory after its subpool was given back");

      declare
         Again : constant Node_Pools.Subpool_Handle := Node_Pools.On_Node (Arena, Target);
         Later : constant Count_Access := new (Again) Interfaces.Unsigned_64'(9);
      begin
         Check (Later.all = 9, "a node could not be used again after being given back");
         Check
           (Node_Pools.Reserved_Bytes (Arena, Target) > 0,
            "a node served an allocation without reserving memory");
      end;
   end;

   --  An object needing more alignment than the one before it leaves has to
   --  be padded forward, which is the only case where the padding is not
   --  zero.
   declare
      package Node_Pools renames NUMA.Pools;

      use type System.Storage_Elements.Integer_Address;

      Arena : Node_Pools.Node_Pool (Policy => NUMA.Placement.Bound, Extent => 4096);

      type Wide is record
         Value : Interfaces.Unsigned_64;
      end record
      with Alignment => 16;

      type Byte_Access is access Interfaces.Unsigned_8 with Storage_Pool => Arena;
      type Wide_Access is access Wide with Storage_Pool => Arena;

      Holder : constant Node_Pools.Subpool_Handle := Node_Pools.On_Node (Arena, Target);
   begin
      for Index in 1 .. 8 loop
         declare
            Odd  : constant Byte_Access := new (Holder) Interfaces.Unsigned_8'(1);
            Item : constant Wide_Access := new (Holder) Wide'(Value => Interfaces.Unsigned_64 (Index));
         begin
            Check (Odd.all = 1, "a byte allocation did not keep its value");
            Check (Item.Value = Interfaces.Unsigned_64 (Index), "a padded allocation did not keep its value");
            Check
              (System.Storage_Elements.To_Integer (Item.all'Address) mod 16 = 0,
               "a padded allocation is not aligned for its type");
         end;
      end loop;
   end;

   --  Everything below needs a host with more than one memory domain, which
   --  is what makes choosing between them mean anything. On a host with one
   --  node none of it runs, and nothing here is checked.
   if NUMA.Placement.Support = NUMA.Placement.Supported and then NUMA.Count (Allowed) >= 2 then
      --  Memory bound to a node is held by that node, and by each of them
      --  in turn rather than only by whichever one the host prefers.
      declare
         package Node_Pools renames NUMA.Pools;
      begin
         for Node of Allowed loop
            declare
               Arena : Node_Pools.Node_Pool (Policy => NUMA.Placement.Bound, Extent => 4096);

               type Value_Access is access Interfaces.Unsigned_64 with Storage_Pool => Arena;

               Holder : constant Node_Pools.Subpool_Handle := Node_Pools.On_Node (Arena, Node);
               Item   : constant Value_Access := new (Holder) Interfaces.Unsigned_64'(1);
               Where  : constant NUMA.Node_Query := NUMA.Placement.Node_Of_Address (Item.all'Address);
            begin
               Check
                 (Node_Pools.Placement_Reached (Arena, Node),
                  "a bound pool did not reach node" & NUMA.Node_Id'Image (Node));
               Check (Where.Available, "an allocated object was not reported on any node");
               Check
                 (Where.Node = Node,
                  "memory bound to node"
                  & NUMA.Node_Id'Image (Node)
                  & " is held by node"
                  & NUMA.Node_Id'Image (Where.Node));
            end;
         end loop;
      end;

      --  A node is further from another than from itself, which a host with
      --  one node cannot show.
      declare
         Apart : Boolean := False;
      begin
         for Node of Allowed loop
            for Other of Allowed loop
               declare
                  Near : constant NUMA.Distance_Query := NUMA.Node_Distance (Node, Node);
                  Away : constant NUMA.Distance_Query := NUMA.Node_Distance (Node, Other);
               begin
                  if Node /= Other
                    and then Near.Available
                    and then Away.Available
                    and then Away.Value > Near.Value
                  then
                     Apart := True;
                  end if;
               end;
            end loop;
         end loop;

         Check (Apart, "no node is further from another than from itself");
      end;

      --  Interleaving spreads consecutive pages over the nodes rather than
      --  drawing them all from one.
      declare
         use type System.Storage_Elements.Integer_Address;
         use type System.Storage_Elements.Storage_Offset;

         Span_Pages : constant := 16;

         Page : constant NUMA.Byte_Count := NUMA.Placement.Page_Size;

         type Span is array (NUMA.Byte_Count range <>) of aliased Interfaces.Unsigned_8;
         type Span_Access is access Span;

         Room    : constant Span_Access := new Span (1 .. (Span_Pages + 1) * Page);
         Start   : constant System.Address := Room (1)'Address;
         Skew    : constant System.Storage_Elements.Integer_Address :=
           System.Storage_Elements.To_Integer (Start) mod System.Storage_Elements.Integer_Address (Page);
         Aligned : constant System.Address :=
           (if Skew = 0
            then Start
            else
              Start
              + System.Storage_Elements.Storage_Offset
                  (System.Storage_Elements.Integer_Address (Page) - Skew));

         Found    : array (NUMA.Node_Id) of Boolean := (others => False);
         Distinct : Natural := 0;
         Result   : NUMA.Placement.Placement_Outcome;
      begin
         NUMA.Placement.Apply_To
           (Base   => Aligned,
            Length => Span_Pages * Page,
            Policy => NUMA.Placement.Interleaved,
            Nodes  => Allowed,
            Result => Result);

         Check
           (Result = NUMA.Placement.Applied,
            "an interleave over the permitted nodes was refused: "
            & NUMA.Placement.Placement_Outcome'Image (Result));

         for Index in 0 .. Span_Pages - 1 loop
            declare
               Somewhere : constant System.Address :=
                 Aligned + System.Storage_Elements.Storage_Offset (NUMA.Byte_Count (Index) * Page);

               Cell : Interfaces.Unsigned_8
               with Import, Address => Somewhere;

               Where : NUMA.Node_Query;
            begin
               --  The page has to exist before it can be said to be
               --  anywhere, so it is written to first.
               Cell := Interfaces.Unsigned_8 (Index mod 256);

               Where := NUMA.Placement.Node_Of_Address (Somewhere);

               if Where.Available and then not Found (Where.Node) then
                  Found (Where.Node) := True;
                  Distinct := Distinct + 1;
               end if;
            end;
         end loop;

         Check
           (Distinct >= 2,
            "interleaving over"
            & Natural'Image (NUMA.Count (Allowed))
            & " nodes put every page on"
            & Natural'Image (Distinct));

         Ada.Text_IO.Put_Line
           ("interleave: " & Natural'Image (Distinct) & " nodes of" & Natural'Image (NUMA.Count (Allowed)));
      end;
   end if;

   Ada.Text_IO.Put_Line ("nodes:      " & Natural'Image (NUMA.Node_Count));
   Ada.Text_IO.Put_Line ("permitted:  " & Natural'Image (NUMA.Count (Allowed)));
   Ada.Text_IO.Put_Line ("processors: " & Natural'Image (Processors));
   Ada.Text_IO.Put_Line ("source:     " & NUMA.Discovery_Source'Image (Support.Source));
   Ada.Text_IO.Put_Line ("complete:   " & Boolean'Image (Support.Complete));
   Ada.Text_IO.Put_Line ("all flyology_numa host tests passed");
end Tests;
