with Ada.Text_IO;
with Flyology_NUMA;
with System.Multiprocessors;
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
