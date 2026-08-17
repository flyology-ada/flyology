--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  Set algebra over the node and processor set representations.
--
--  Discovery builds sets while the parent package is still elaborating, so
--  these operations live in their own unit: a set operation that lived in
--  the parent body could not be called to build the parent body's own state.
--  Keeping them here also keeps them free of host dependencies, so the bit
--  arithmetic is ordinary computation that any host can exercise.
private package Flyology_NUMA.Bits is

   function Contains (Set : Node_Set; Node : Node_Id) return Boolean;

   function Contains
     (Set : Processor_Set; Processor : Processor_Id) return Boolean;

   function Count (Set : Node_Set) return Natural;

   function Count (Set : Processor_Set) return Natural;

   procedure Include (Set : in out Node_Set; Node : Node_Id);

   procedure Include (Set : in out Processor_Set; Processor : Processor_Id);

   function Is_Empty (Set : Node_Set) return Boolean;

   function Is_Empty (Set : Processor_Set) return Boolean;

   --  Intersect Set with Mask, keeping only members present in both.
   procedure Restrict_To (Set : in out Node_Set; Mask : Node_Set);

   --  Report whether Subset has no member outside Superset.
   function Within (Subset : Node_Set; Superset : Node_Set) return Boolean;

   function First (Set : Node_Set) return Node_Cursor;

   function First (Set : Processor_Set) return Processor_Cursor;

   function Next (Set : Node_Set; Position : Node_Cursor) return Node_Cursor;

   function Next
     (Set : Processor_Set; Position : Processor_Cursor)
      return Processor_Cursor;

   function Has_Element
     (Set : Node_Set; Position : Node_Cursor) return Boolean;

   function Has_Element
     (Set : Processor_Set; Position : Processor_Cursor) return Boolean;

   function Element (Set : Node_Set; Position : Node_Cursor) return Node_Id;

   function Element
     (Set : Processor_Set; Position : Processor_Cursor) return Processor_Id;

end Flyology_NUMA.Bits;
