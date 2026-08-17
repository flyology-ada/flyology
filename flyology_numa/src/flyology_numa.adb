--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_NUMA.Bits;
with Flyology_NUMA.Platform;

--  Discovery runs while this body elaborates, so the body it calls must be
--  elaborated first.  The static model works that out on its own; stating it
--  keeps the guarantee under the dynamic model too.  Elaborate_All would not
--  do: its closure reaches back through Platform's spec to this very body.
pragma Elaborate (Flyology_NUMA.Platform);

package body Flyology_NUMA is

   --  Every processor this package represents must be nameable as an Ada
   --  processor, so that To_CPU's only reason to decline is host numbering.
   pragma Compile_Time_Error
     (Max_Processor + 1 > Natural (System.Multiprocessors.CPU_Range'Last),
      "host processor numbers exceed the Ada processor range");

   --  The host description is read once, here, so that every query is a
   --  plain memory read and no query can fail part way through a program.
   --  Platform.Discover reports an unanswering host rather than raising.
   Facts : constant Machine_Facts := Platform.Discover;

   --------------
   -- Value_Or --
   --------------

   function Value_Or
     (Result   : Byte_Query;
      Fallback : Byte_Count) return Byte_Count is
     (if Result.Available then Result.Bytes else Fallback);

   function Value_Or
     (Result   : Distance_Query;
      Fallback : Distance) return Distance is
     (if Result.Available then Result.Value else Fallback);

   function Value_Or
     (Result   : Value_Query;
      Fallback : Natural) return Natural is
     (if Result.Available then Result.Value else Fallback);

   --------------
   -- Contains --
   --------------

   function Contains (Set : Node_Set; Node : Node_Id) return Boolean is
     (Bits.Contains (Set, Node));

   function Contains
     (Set : Processor_Set; Processor : Processor_Id) return Boolean is
     (Bits.Contains (Set, Processor));

   -----------
   -- Count --
   -----------

   function Count (Set : Node_Set) return Natural is (Bits.Count (Set));

   function Count (Set : Processor_Set) return Natural is (Bits.Count (Set));

   -----------
   -- First --
   -----------

   function First (Set : Node_Set) return Node_Cursor is
     (Bits.First (Set));

   function First (Set : Processor_Set) return Processor_Cursor is
     (Bits.First (Set));

   ----------
   -- Next --
   ----------

   function Next
     (Set : Node_Set; Position : Node_Cursor) return Node_Cursor is
     (Bits.Next (Set, Position));

   function Next
     (Set : Processor_Set; Position : Processor_Cursor)
      return Processor_Cursor is
     (Bits.Next (Set, Position));

   -----------------
   -- Has_Element --
   -----------------

   function Has_Element
     (Set : Node_Set; Position : Node_Cursor) return Boolean is
     (Bits.Has_Element (Set, Position));

   function Has_Element
     (Set : Processor_Set; Position : Processor_Cursor) return Boolean is
     (Bits.Has_Element (Set, Position));

   -------------
   -- Element --
   -------------

   function Element (Set : Node_Set; Position : Node_Cursor) return Node_Id is
      pragma Unreferenced (Set);
   begin
      return Node_Id (Position);
   end Element;

   function Element
     (Set : Processor_Set; Position : Processor_Cursor) return Processor_Id is
      pragma Unreferenced (Set);
   begin
      return Processor_Id (Position);
   end Element;

   -------------
   -- Support --
   -------------

   function Support return Support_Report is
     ((Source                 => Facts.Source,
       Restricted             => Facts.Restricted,
       Complete               => Facts.Complete,
       Consecutive_Processors => Facts.Consecutive_Processors));

   ------------------
   -- Online_Nodes --
   ------------------

   function Online_Nodes return Node_Set is (Facts.Online);

   -------------------
   -- Allowed_Nodes --
   -------------------

   function Allowed_Nodes return Node_Set is (Facts.Allowed);

   ----------------
   -- Node_Count --
   ----------------

   function Node_Count return Positive is (Bits.Count (Facts.Online));

   -------------------
   -- Processors_Of --
   -------------------

   function Processors_Of (Node : Node_Id) return Processor_Set is
     (Facts.Nodes (Node).Processors);

   -------------
   -- Node_Of --
   -------------

   function Node_Of (Processor : Processor_Id) return Node_Query is
     (Facts.Owner (Processor));

   ------------------
   -- Memory_Bytes --
   ------------------

   function Memory_Bytes (Node : Node_Id) return Byte_Query is
     (Facts.Nodes (Node).Memory);

   -------------------
   -- Node_Distance --
   -------------------

   function Node_Distance
     (From : Node_Id; To : Node_Id) return Distance_Query is
     (Facts.Nodes (From).Distances (To));

   ----------------
   -- Package_Of --
   ----------------

   function Package_Of (Node : Node_Id) return Value_Query is
     (Facts.Nodes (Node).Packaging);

   ---------------
   -- Is_Online --
   ---------------

   function Is_Online (Node : Node_Id) return Boolean is
     (Bits.Contains (Facts.Online, Node));

   ----------------
   -- Is_Allowed --
   ----------------

   function Is_Allowed (Node : Node_Id) return Boolean is
     (Bits.Contains (Facts.Allowed, Node));

   ----------------
   -- Has_Memory --
   ----------------

   function Has_Memory (Node : Node_Id) return Boolean is
     (Bits.Contains (Facts.With_Memory, Node));

   --------------------
   -- Has_Processors --
   --------------------

   function Has_Processors (Node : Node_Id) return Boolean is
     (not Bits.Is_Empty (Facts.Nodes (Node).Processors));

   ------------
   -- To_CPU --
   ------------

   function To_CPU
     (Processor : Processor_Id) return System.Multiprocessors.CPU_Range is
   begin
      --  A processor the host never described cannot be named, and neither
      --  can any processor once the host's numbering has a gap, because the
      --  arithmetic below would then name a different processor.
      if not Facts.Consecutive_Processors
        or else not Facts.Owner (Processor).Available
      then
         return System.Multiprocessors.Not_A_Specific_CPU;
      end if;

      return System.Multiprocessors.CPU_Range (Natural (Processor) + 1);
   end To_CPU;

end Flyology_NUMA;
