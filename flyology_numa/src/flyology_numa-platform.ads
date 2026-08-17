--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

private package Flyology_NUMA.Platform is

   --  Read this host's memory-node description.
   --
   --  This runs during elaboration of the parent package and raises nothing.
   --  A host that describes no memory nodes, or describes them in a way this
   --  package cannot read, is reported as one node holding every processor.
   --  @return What discovery established about this host.
   function Discover return Machine_Facts;

end Flyology_NUMA.Platform;
