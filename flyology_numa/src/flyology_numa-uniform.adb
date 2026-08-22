--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with System.Multiprocessors;

with Flyology_NUMA.Bits;

pragma Elaborate (Flyology_NUMA.Bits);

package body Flyology_NUMA.Uniform is

   --  A node's distance to itself, on the scale host firmware uses.
   Local_Distance : constant Distance := 10;

   --  The one node a uniform host has.
   Only_Node : constant Node_Id := 0;

   --------------------------
   -- Single_Domain_Facts --
   --------------------------

   function Single_Domain_Facts (Memory : Byte_Query := No_Bytes) return Machine_Facts is
      Result    : Machine_Facts;
      Available : Natural;
   begin
      Result.Source := Single_Domain;
      Result.Restricted := False;
      Result.Consecutive_Processors := True;

      Bits.Include (Result.Online, Only_Node);
      Bits.Include (Result.Allowed, Only_Node);
      Bits.Include (Result.With_Memory, Only_Node);

      Result.Nodes (Only_Node).Memory := Memory;
      Result.Nodes (Only_Node).Distances (Only_Node) := (Available => True, Value => Local_Distance);

      Available := Natural (System.Multiprocessors.Number_Of_CPUs);

      --  A host with more processors than this package represents still has
      --  one memory domain, so the node stays correct while the processor
      --  set becomes partial.  Complete records that difference.
      Result.Complete := Available <= Max_Processor + 1;

      for Index in 0 .. Natural'Min (Available - 1, Max_Processor) loop
         Bits.Include (Result.Nodes (Only_Node).Processors, Processor_Id (Index));
         Result.Owner (Processor_Id (Index)) := (Available => True, Node => Only_Node);
      end loop;

      return Result;
   end Single_Domain_Facts;

end Flyology_NUMA.Uniform;
