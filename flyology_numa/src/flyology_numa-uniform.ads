--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

private package Flyology_NUMA.Uniform is

   --  Describe a host whose memory is uniform as one memory node.
   --
   --  The node holds every processor the host reports, carries the whole of
   --  memory, and is its own nearest node. This is the truthful description
   --  of a host without memory-node structure, not a placeholder: such a
   --  host has exactly one memory domain.
   --  @param Memory Total memory to attribute to the node, or No_Bytes when
   --     the caller cannot establish it.
   --  @return A single-node description of this host.
   function Single_Domain_Facts
     (Memory : Byte_Query := No_Bytes) return Machine_Facts;

end Flyology_NUMA.Uniform;
