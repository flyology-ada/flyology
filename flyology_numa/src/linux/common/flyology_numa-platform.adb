--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_NUMA.Sysfs;
with Flyology_NUMA.Uniform;

pragma Elaborate (Flyology_NUMA.Sysfs);
pragma Elaborate (Flyology_NUMA.Uniform);

package body Flyology_NUMA.Platform is

   --------------
   -- Discover --
   --------------

   function Discover return Machine_Facts is
      Facts   : Machine_Facts;
      Success : Boolean;
   begin
      Sysfs.Read
        (Node_Root   => Sysfs.Default_Node_Root,
         CPU_Root    => Sysfs.Default_CPU_Root,
         Status_Path => Sysfs.Default_Status_Path,
         Facts       => Facts,
         Success     => Success);

      if Success then
         return Facts;
      end if;

      --  A Linux host built without memory-node support describes no nodes.
      --  Its memory is uniform, so one node is the truthful description.
      return Uniform.Single_Domain_Facts;
   exception
      when others =>
         return Uniform.Single_Domain_Facts;
   end Discover;

end Flyology_NUMA.Platform;
