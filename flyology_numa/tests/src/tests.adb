with Ada.Text_IO;
with Flyology_NUMA.Placement;
with Interfaces;
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
   use type System.Multiprocessors.CPU_Range;

   procedure Check (Condition : Boolean; Message : String);

   function Is_macOS (Name : String) return Boolean;

   function Is_macOS (Name : String) return Boolean is (Name = "macos");

   function Places_Memory (Arch : String) return Boolean;

   --  The architectures this crate records placement call numbers for.
   function Places_Memory (Arch : String) return Boolean is
     (Arch = "x86_64" or else Arch = "aarch64" or else Arch = "riscv64");

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

begin
   --  Every host has at least one memory domain, including a host that has
   --  no memory-node structure at all.  Node_Count returns Positive, so an
   --  empty online set raises here rather than reporting zero nodes.
   Check (NUMA.Count (Online) = NUMA.Node_Count,
          "the online set disagrees with the node count");
   Check (NUMA.Count (Allowed) >= 1, "this process may use no node");

   --  A node this process may use is a node the host has.
   for Node of Allowed loop
      Check (NUMA.Is_Online (Node),
             "a permitted node is not among the online nodes");
   end loop;

   Check (Support.Restricted = (NUMA.Count (Allowed) < NUMA.Count (Online)),
          "the restriction report disagrees with the permitted set");

   --  A processor belongs to the node whose processor set holds it.
   for Node of Online loop
      for Processor of NUMA.Processors_Of (Node) loop
         declare
            Owner : constant NUMA.Node_Query := NUMA.Node_Of (Processor);
         begin
            Check (Owner.Available, "an attached processor names no node");
            Check (Owner.Node = Node,
                   "a processor is attached to a node that disowns it");
         end;

         Check (NUMA.Has_Processors (Node),
                "a node with an attached processor reports none");

         Processors := Processors + 1;
      end loop;
   end loop;

   Check (Processors >= 1, "the host reports no processor");

   --  A node is nearer to itself than to any other node.
   for Node of Online loop
      declare
         Local : constant NUMA.Distance_Query :=
           NUMA.Node_Distance (Node, Node);
      begin
         if Local.Available then
            for Other of Online loop
               declare
                  Away : constant NUMA.Distance_Query :=
                    NUMA.Node_Distance (Node, Other);
               begin
                  if Away.Available then
                     Check (Local.Value <= Away.Value,
                            "a node is reported nearer to another node "
                            & "than to itself");
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
            Check (NUMA.To_CPU (Processor)
                   /= System.Multiprocessors.Not_A_Specific_CPU,
                   "a consecutively numbered processor cannot be named");
         else
            Check (NUMA.To_CPU (Processor)
                   = System.Multiprocessors.Not_A_Specific_CPU,
                   "a processor was named despite a gap in host numbering");
         end if;
      end loop;
   end loop;

   --  A fallback describes exactly one node holding every processor.
   if Support.Source = NUMA.Single_Domain then
      Check (NUMA.Node_Count = 1,
             "a uniform host reports more than one node");
      Check (not Support.Restricted,
             "a uniform host reports a restriction");
   end if;

   --  macOS describes no memory-node structure and does report its memory.
   if Is_macOS (Tests_Config.Alire_Host_OS) then
      Check (Support.Source = NUMA.Single_Domain,
             "macOS was read as having memory nodes");
      Check (NUMA.Memory_Bytes (0).Available,
             "macOS did not report its memory size");
      Check (NUMA.Value_Or (NUMA.Memory_Bytes (0), 0) > 0,
             "macOS reported an empty memory size");
   end if;

   --  Placement acts on the description the parent package reports, and
   --  reports its own outcome for every attempt.
   declare
      use type System.Storage_Elements.Integer_Address;
      use type System.Storage_Elements.Storage_Offset;
      use type NUMA.Placement.Support_Level;
      use type NUMA.Placement.Placement_Outcome;

      Page : constant NUMA.Byte_Count := NUMA.Placement.Page_Size;

      type Block is array (NUMA.Byte_Count range <>) of aliased
        Interfaces.Unsigned_8;
      type Block_Access is access Block;

      --  Two pages of room guarantee one whole page starting on a boundary
      --  somewhere inside, whatever the heap returned.
      Room    : constant Block_Access := new Block (1 .. 2 * Page);
      Start   : constant System.Address := Room (1)'Address;
      Skew    : constant System.Storage_Elements.Integer_Address :=
        System.Storage_Elements.To_Integer (Start)
        mod System.Storage_Elements.Integer_Address (Page);
      Aligned : constant System.Address :=
        (if Skew = 0 then Start
         else Start
              + System.Storage_Elements.Storage_Offset
                  (System.Storage_Elements.Integer_Address (Page) - Skew));

      Result : NUMA.Placement.Placement_Outcome;
      Empty  : NUMA.Node_Set;
   begin
      --  A host that described its own memory nodes has the calls that act
      --  on them, so reporting no way to place memory means the calls were
      --  not reached rather than that the host lacks them.  This is what
      --  catches a call number taken from the wrong architecture's table.
      if Support.Source = NUMA.Host_Report
        and then Places_Memory (Tests_Config.Alire_Host_Arch)
      then
         Check (NUMA.Placement.Support /= NUMA.Placement.Unsupported_Host,
                "a host describing memory nodes reported no way to use them");
      end if;

      Check (Page > 0, "the host reports no page size");
      Check (Page mod 4096 = 0, "the page size is not a whole number of "
             & "four-kilobyte pages");
      Check (System.Storage_Elements.To_Integer (Aligned)
             mod System.Storage_Elements.Integer_Address (Page) = 0,
             "the aligned address is not aligned");

      case NUMA.Placement.Support is
         when NUMA.Placement.Unsupported_Host =>
            --  Nothing is placed, and nothing pretends to have been.
            NUMA.Placement.Apply_To
              (Aligned, Page, NUMA.Placement.Interleaved, Allowed,
               Result => Result);
            Check (Result = NUMA.Placement.Not_Supported,
                   "a host without placement reported a placement");

            --  No policy is placed, whichever one is asked for.
            for Policy in NUMA.Placement.Policy_Kind loop
               NUMA.Placement.Apply_To_Thread (Policy, Allowed, Result);
               Check (Result = NUMA.Placement.Not_Supported,
                      "a host without placement placed a thread's memory");
            end loop;

            Check (not NUMA.Placement.Node_Of_Address (Aligned).Available,
                   "a host without placement named a node for an address");

         when NUMA.Placement.Denied =>
            NUMA.Placement.Apply_To
              (Aligned, Page, NUMA.Placement.Interleaved, Allowed,
               Result => Result);
            Check (Result = NUMA.Placement.Not_Permitted,
                   "a denied process reported a placement");

         when NUMA.Placement.Supported =>
            --  A range that does not begin on a page boundary is refused
            --  before anything is asked of the host.
            NUMA.Placement.Apply_To
              (Aligned + 1, Page, NUMA.Placement.Interleaved, Allowed,
               Result => Result);
            Check (Result = NUMA.Placement.Unaligned,
                   "an unaligned range was not refused");

            --  A policy that needs nodes cannot run without any.
            NUMA.Placement.Apply_To
              (Aligned, Page, NUMA.Placement.Bound, Empty, Result => Result);
            Check (Result = NUMA.Placement.Unusable_Nodes,
                   "an empty node set was accepted for a bound policy");

            --  Every policy is exercised against the nodes this process may
            --  use, including one whose permitted set holds a single node.
            --
            --  Local and Unrestricted are given a node set on purpose. The
            --  host rejects a policy of either kind that arrives carrying
            --  one, so passing the set a caller naturally has to hand is
            --  what proves the set is dropped before the host sees it.
            for Policy in NUMA.Placement.Policy_Kind loop
               NUMA.Placement.Apply_To
                 (Aligned, Page, Policy, Allowed, Result => Result);
               Check (Result = NUMA.Placement.Applied,
                      "a permitted "
                      & NUMA.Placement.Policy_Kind'Image (Policy)
                      & " placement was refused: "
                      & NUMA.Placement.Placement_Outcome'Image (Result));
            end loop;

            NUMA.Placement.Apply_To
              (Aligned, Page, NUMA.Placement.Interleaved, Allowed,
               Result => Result);
            Check (Result = NUMA.Placement.Applied,
                   "a permitted interleave was refused: "
                   & NUMA.Placement.Placement_Outcome'Image (Result));

            --  Placing this thread's later allocations is a different host
            --  call from placing a range, and on some architectures its
            --  number sits where another call's number sits on others. A
            --  wrong number here would reach a working but unrelated
            --  service, so the call is made and its outcome checked.
            for Policy in NUMA.Placement.Policy_Kind loop
               NUMA.Placement.Apply_To_Thread (Policy, Allowed, Result);
               Check (Result = NUMA.Placement.Applied,
                      "a permitted "
                      & NUMA.Placement.Policy_Kind'Image (Policy)
                      & " thread policy was refused: "
                      & NUMA.Placement.Placement_Outcome'Image (Result));
            end loop;

            NUMA.Placement.Apply_To_Thread
              (NUMA.Placement.Interleaved, Allowed, Result);
            Check (Result = NUMA.Placement.Applied,
                   "a permitted thread policy was refused: "
                   & NUMA.Placement.Placement_Outcome'Image (Result));

            NUMA.Placement.Apply_To_Thread
              (NUMA.Placement.Unrestricted, Empty, Result);
            Check (Result = NUMA.Placement.Applied,
                   "releasing a thread policy was refused");

            --  Once the page is written to it exists somewhere, and that
            --  somewhere is a node this process may use.
            Room (1) := 1;

            declare
               Where : constant NUMA.Node_Query :=
                 NUMA.Placement.Node_Of_Address (Room (1)'Address);
            begin
               Check (Where.Available,
                      "a written page was not reported on any node");
               Check (NUMA.Is_Online (Where.Node),
                      "a page was reported on a node the host lacks");
            end;

            --  Returning the range to the host default must be accepted.
            NUMA.Placement.Apply_To
              (Aligned, Page, NUMA.Placement.Unrestricted, Empty,
               Result => Result);
            Check (Result = NUMA.Placement.Applied,
                   "releasing a placement was refused");

            declare
               Permitted : constant NUMA.Node_Set :=
                 NUMA.Placement.Permitted_Nodes;
            begin
               Check (NUMA.Count (Permitted) >= 1,
                      "a supported host permits no node");

               for Node of Permitted loop
                  Check (NUMA.Is_Online (Node),
                         "a permitted node is not online");
               end loop;
            end;
      end case;

      Ada.Text_IO.Put_Line
        ("placement:  "
         & NUMA.Placement.Support_Level'Image (NUMA.Placement.Support));
      Ada.Text_IO.Put_Line
        ("page:       " & NUMA.Byte_Count'Image (Page));
   end;

   Ada.Text_IO.Put_Line
     ("nodes:      " & Natural'Image (NUMA.Node_Count));
   Ada.Text_IO.Put_Line
     ("permitted:  " & Natural'Image (NUMA.Count (Allowed)));
   Ada.Text_IO.Put_Line
     ("processors: " & Natural'Image (Processors));
   Ada.Text_IO.Put_Line
     ("source:     " & NUMA.Discovery_Source'Image (Support.Source));
   Ada.Text_IO.Put_Line
     ("complete:   " & Boolean'Image (Support.Complete));
   Ada.Text_IO.Put_Line ("all flyology_numa host tests passed");
end Tests;
