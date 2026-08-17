--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Reads a memory-node description laid out the way Linux describes itself.
--
--  This package is host-independent text processing. It names the directories
--  it reads instead of assuming them, so the same reader serves a running
--  Linux host and a recorded description held in a test directory. That is
--  what lets node numbering, processor attachment, distance rows, and
--  control-group restriction be exercised on a host that has none of them.
private package Flyology_NUMA.Sysfs is

   --  Where a Linux host keeps its memory-node description.
   Default_Node_Root : constant String := "/sys/devices/system/node";

   --  Where a Linux host keeps its processor description.
   Default_CPU_Root : constant String := "/sys/devices/system/cpu";

   --  Where a Linux host reports the nodes this process may use.
   Default_Status_Path : constant String := "/proc/self/status";

   --  Read a memory-node description rooted at the given directories.
   --
   --  Raises nothing. A description that is absent, unreadable, or malformed
   --  reports Success as false, which leaves the caller to describe the host
   --  some other way rather than to report a description it did not read.
   --  @param Node_Root Directory holding the node0, node1, ... entries.
   --  @param CPU_Root Directory holding the cpu0, cpu1, ... entries.
   --  @param Status_Path Process status file naming the usable nodes.
   --  @param Facts The description that was read.
   --  @param Success True when a node description was read.
   procedure Read
     (Node_Root   : String;
      CPU_Root    : String;
      Status_Path : String;
      Facts       : out Machine_Facts;
      Success     : out Boolean);

end Flyology_NUMA.Sysfs;
