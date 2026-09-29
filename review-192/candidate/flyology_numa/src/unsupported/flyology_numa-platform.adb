--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_NUMA.Uniform;

pragma Elaborate (Flyology_NUMA.Uniform);

--  A host this package has not been taught to read describes no memory
--  nodes to it.  Reporting one node holding every processor keeps every
--  query answerable, and Support reports Single_Domain so that a caller can
--  tell this apart from a host that was read and found to be uniform.

package body Flyology_NUMA.Platform is

   --------------
   -- Discover --
   --------------

   function Discover return Machine_Facts
   is (Uniform.Single_Domain_Facts);

end Flyology_NUMA.Platform;
