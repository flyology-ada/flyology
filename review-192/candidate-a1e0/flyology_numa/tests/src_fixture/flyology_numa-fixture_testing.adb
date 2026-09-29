with Ada.Text_IO;

with Flyology_NUMA.Bits;
with Flyology_NUMA.Sysfs;

package body Flyology_NUMA.Fixture_Testing is

   Kilobyte : constant Byte_Count := 1024;

   procedure Check (Condition : Boolean; Message : String);

   procedure Load (Fixture_Root : String; Name : String; Facts : out Machine_Facts);

   -----------
   -- Check --
   -----------

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   ----------
   -- Load --
   ----------

   procedure Load (Fixture_Root : String; Name : String; Facts : out Machine_Facts) is
      Root    : constant String := Fixture_Root & "/" & Name;
      Success : Boolean;
   begin
      Sysfs.Read
        (Node_Root   => Root & "/sys/devices/system/node",
         CPU_Root    => Root & "/sys/devices/system/cpu",
         Status_Path => Root & "/proc/self/status",
         Facts       => Facts,
         Success     => Success);

      Check (Success, Name & " description was not read");
      Check (Facts.Source = Host_Report, Name & " was not read from the host");
   end Load;

   ---------
   -- Run --
   ---------

   procedure Run (Fixture_Root : String) is
   begin
      --  Two processor packages, each its own memory node.
      declare
         Facts : Machine_Facts;
      begin
         Load (Fixture_Root, "dual_socket", Facts);

         Check (Bits.Count (Facts.Online) = 2, "dual socket has two nodes");
         Check (Bits.Count (Facts.Nodes (0).Processors) = 4, "dual socket node 0 has four processors");
         Check (Bits.Contains (Facts.Nodes (1).Processors, 5), "dual socket node 1 holds processor 5");
         Check
           (Facts.Owner (5) = (Available => True, Node => 1), "dual socket processor 5 belongs to node 1");
         Check
           (Facts.Nodes (0).Distances (0) = (Available => True, Value => 10),
            "dual socket node 0 is its own nearest node");
         Check
           (Facts.Nodes (0).Distances (1) = (Available => True, Value => 21),
            "dual socket crosses to node 1 at distance 21");
         Check
           (Facts.Nodes (0).Packaging = (Available => True, Value => 0),
            "dual socket node 0 sits on package 0");
         Check
           (Facts.Nodes (1).Packaging = (Available => True, Value => 1),
            "dual socket node 1 sits on package 1");
         Check
           (Facts.Nodes (0).Memory = (Available => True, Bytes => 16_777_216 * Kilobyte),
            "dual socket node 0 reports its memory");
         Check (not Facts.Restricted, "dual socket restricts nothing");
         Check (Facts.Consecutive_Processors, "dual socket numbers processors consecutively");
         Check (Facts.Complete, "dual socket fits within the represented range");
      end;

      --  One package divided into several memory nodes.  The firmware-
      --  declared distance between two nodes of one package is small but not
      --  local, so distance alone does not separate the cases and the
      --  package number has to.
      declare
         Facts : Machine_Facts;
      begin
         Load (Fixture_Root, "snc4", Facts);

         Check (Bits.Count (Facts.Online) = 4, "clustered host has four nodes");
         Check
           (Facts.Nodes (0).Distances (1) = (Available => True, Value => 11),
            "clustered nodes of one package are near each other");
         Check
           (Facts.Nodes (0).Distances (2) = (Available => True, Value => 21),
            "clustered nodes of different packages are far apart");
         Check
           (Facts.Nodes (0).Packaging = Facts.Nodes (1).Packaging,
            "clustered nodes 0 and 1 share one package");
         Check
           (Facts.Nodes (0).Packaging /= Facts.Nodes (2).Packaging,
            "clustered nodes 0 and 2 sit on different packages");
      end;

      --  A node that carries memory and has no processor attached.
      declare
         Facts : Machine_Facts;
      begin
         Load (Fixture_Root, "memory_only", Facts);

         Check (Bits.Count (Facts.Online) = 2, "expander host has two nodes");
         Check (Bits.Is_Empty (Facts.Nodes (1).Processors), "the expander node has no processor");
         Check (not Bits.Is_Empty (Facts.Nodes (0).Processors), "the processor node has processors");
         Check (Bits.Contains (Facts.With_Memory, 1), "the expander node carries memory");
         Check
           (Facts.Nodes (1).Memory = (Available => True, Bytes => 33_554_432 * Kilobyte),
            "the expander node reports its memory");
         Check (not Facts.Nodes (1).Packaging.Available, "a node with no processor names no package");
      end;

      --  Nodes numbered 0, 2 and 5.  A distance row names one value per
      --  online node in increasing order, so its third value belongs to node
      --  5 and nothing belongs to the numbers the host skipped.
      declare
         Facts : Machine_Facts;
      begin
         Load (Fixture_Root, "sparse", Facts);

         Check (Bits.Count (Facts.Online) = 3, "sparse host has three nodes");
         Check
           (Bits.Contains (Facts.Online, 0)
            and then Bits.Contains (Facts.Online, 2)
            and then Bits.Contains (Facts.Online, 5),
            "sparse host reports nodes 0, 2 and 5");
         Check (not Bits.Contains (Facts.Online, 1), "sparse host does not gain a node 1");
         Check
           (Facts.Nodes (0).Distances (2) = (Available => True, Value => 21),
            "the second distance belongs to node 2");
         Check
           (Facts.Nodes (0).Distances (5) = (Available => True, Value => 31),
            "the third distance belongs to node 5");
         Check
           (not Facts.Nodes (0).Distances (1).Available,
            "no distance is recorded for a node the host skipped");
         Check (Facts.Owner (4) = (Available => True, Node => 5), "processor 4 belongs to node 5");
      end;

      --  The host has four nodes and a control group permits two of them.
      declare
         Facts : Machine_Facts;
      begin
         Load (Fixture_Root, "restricted", Facts);

         Check (Bits.Count (Facts.Online) = 4, "the restricted host still reports four nodes");
         Check (Bits.Count (Facts.Allowed) = 2, "the restricted process may use two nodes");
         Check (Facts.Restricted, "the restriction is reported");
         Check
           (Bits.Contains (Facts.Allowed, 1) and then not Bits.Contains (Facts.Allowed, 2),
            "the permitted nodes are the ones the host named");
         Check (Bits.Within (Facts.Allowed, Facts.Online), "no permitted node is outside the online set");
      end;

      --  A processor is offline, so the host's numbering has a gap and the
      --  Ada processor mapping cannot carry it.
      declare
         Facts : Machine_Facts;
      begin
         Load (Fixture_Root, "gapped", Facts);

         Check (Bits.Contains (Facts.Nodes (0).Processors, 3), "the gapped host holds processor 3");
         Check
           (not Bits.Contains (Facts.Nodes (0).Processors, 2), "the gapped host does not hold processor 2");
         Check (not Facts.Consecutive_Processors, "a gap in processor numbering is reported");
      end;

      --  An older host names only the ordinary memory its nodes carry.
      declare
         Facts : Machine_Facts;
      begin
         Load (Fixture_Root, "normal_memory", Facts);

         Check
           (Bits.Contains (Facts.With_Memory, 0) and then Bits.Contains (Facts.With_Memory, 1),
            "an older memory description was not read");
         Check (Facts.Complete, "an older memory description is complete");
      end;

      --  A processor list this package cannot read leaves that node's
      --  processors unknown, which must not pass for a node that genuinely
      --  has none attached.
      declare
         Facts : Machine_Facts;
      begin
         Load (Fixture_Root, "bad_cpulist", Facts);

         Check (not Facts.Complete, "an unreadable processor list is reported as a shortfall");
         Check (Bits.Count (Facts.Nodes (0).Processors) = 4, "the readable node keeps its processors");
         Check (Bits.Is_Empty (Facts.Nodes (1).Processors), "the unreadable node gains no processors");
      end;

      --  A node numbered beyond what this package represents.
      declare
         Facts : Machine_Facts;
      begin
         Load (Fixture_Root, "clamped", Facts);

         Check (not Facts.Complete, "a node beyond the represented range is a shortfall");
         Check (Bits.Count (Facts.Online) = 1, "only the represented node is reported");
         Check (Bits.Contains (Facts.Online, 0), "the represented node is the one the host named");
      end;

      --  A host that does not name the permitted nodes is taken at its word
      --  that every online node may be used.
      declare
         Facts : Machine_Facts;
      begin
         Load (Fixture_Root, "unnamed_allowed", Facts);

         Check (Bits.Count (Facts.Allowed) = 2, "an unnamed permitted set falls back to the online set");
         Check (not Facts.Restricted, "an unnamed permitted set restricts nothing");
         Check (Facts.Complete, "an unnamed permitted set is not a shortfall");
      end;

      --  A permitted-node list the host named and this package could not
      --  read is a shortfall, not permission to use every node.
      declare
         Facts : Machine_Facts;
      begin
         Load (Fixture_Root, "bad_allowed", Facts);

         Check (not Facts.Complete, "an unreadable permitted list is reported as a shortfall");
      end;

      --  Every machine has a processor.  A description attaching none to any
      --  node was not read, however many nodes it named.
      declare
         Facts   : Machine_Facts;
         Success : Boolean;
      begin
         Sysfs.Read
           (Node_Root   => Fixture_Root & "/no_processors/sys/devices/system/node",
            CPU_Root    => Fixture_Root & "/no_processors/sys/devices/system/cpu",
            Status_Path => Fixture_Root & "/no_processors/proc/self/status",
            Facts       => Facts,
            Success     => Success);

         Check (not Success, "a description with no processor is not reported as read");
      end;

      --  A description that is not there is not a description.
      declare
         Facts   : Machine_Facts;
         Success : Boolean;
      begin
         Sysfs.Read
           (Node_Root   => Fixture_Root & "/absent/node",
            CPU_Root    => Fixture_Root & "/absent/cpu",
            Status_Path => Fixture_Root & "/absent/status",
            Facts       => Facts,
            Success     => Success);

         Check (not Success, "an absent description is not reported as read");
      end;

      --  Reading twice into one object must not carry the first result into
      --  the second.
      declare
         Facts   : Machine_Facts;
         Success : Boolean;
      begin
         Load (Fixture_Root, "restricted", Facts);
         Check (Bits.Count (Facts.Online) = 4, "the first read stands");

         Sysfs.Read
           (Node_Root   => Fixture_Root & "/sparse/sys/devices/system/node",
            CPU_Root    => Fixture_Root & "/sparse/sys/devices/system/cpu",
            Status_Path => Fixture_Root & "/sparse/proc/self/status",
            Facts       => Facts,
            Success     => Success);

         Check (Success, "the second read succeeded");
         Check (Bits.Count (Facts.Online) = 3, "the second read reports its own node count");
         Check (not Facts.Owner (8).Available, "a processor from the first read did not survive the second");
         Check
           (not Facts.Nodes (0).Distances (3).Available,
            "a distance from the first read did not survive the second");
      end;

      Ada.Text_IO.Put_Line ("all flyology_numa fixture tests passed");
   end Run;

end Flyology_NUMA.Fixture_Testing;
