--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_NUMA.Bits is

   --  Return the word holding Member.
   function Word_Of (Member : Natural) return Natural
   is (Member / Bits_Per_Word);

   --  Return a word with only Member's bit set.
   function Single_Bit (Member : Natural) return Word
   is (Word (2)**(Member mod Bits_Per_Word));

   --  Return the number of set bits in Value.
   function Population (Value : Word) return Natural;

   ----------------
   -- Population --
   ----------------

   function Population (Value : Word) return Natural is
      Total : Natural := 0;
   begin
      for Index in 0 .. Bits_Per_Word - 1 loop
         if (Value and Single_Bit (Index)) /= 0 then
            Total := Total + 1;
         end if;
      end loop;

      return Total;
   end Population;

   --------------
   -- Contains --
   --------------

   function Contains (Set : Node_Set; Node : Node_Id) return Boolean
   is ((Set.Bits (Word_Of (Natural (Node))) and Single_Bit (Natural (Node))) /= 0);

   function Contains (Set : Processor_Set; Processor : Processor_Id) return Boolean
   is ((Set.Bits (Word_Of (Natural (Processor))) and Single_Bit (Natural (Processor))) /= 0);

   -----------
   -- Count --
   -----------

   function Count (Set : Node_Set) return Natural is
      Total : Natural := 0;
   begin
      for Value of Set.Bits loop
         Total := Total + Population (Value);
      end loop;

      return Total;
   end Count;

   function Count (Set : Processor_Set) return Natural is
      Total : Natural := 0;
   begin
      for Value of Set.Bits loop
         Total := Total + Population (Value);
      end loop;

      return Total;
   end Count;

   -------------
   -- Include --
   -------------

   procedure Include (Set : in out Node_Set; Node : Node_Id) is
      Index : constant Natural := Word_Of (Natural (Node));
   begin
      Set.Bits (Index) := Set.Bits (Index) or Single_Bit (Natural (Node));
   end Include;

   procedure Include (Set : in out Processor_Set; Processor : Processor_Id) is
      Index : constant Natural := Word_Of (Natural (Processor));
   begin
      Set.Bits (Index) := Set.Bits (Index) or Single_Bit (Natural (Processor));
   end Include;

   --------------
   -- Is_Empty --
   --------------

   function Is_Empty (Set : Node_Set) return Boolean
   is (for all Value of Set.Bits => Value = 0);

   function Is_Empty (Set : Processor_Set) return Boolean
   is (for all Value of Set.Bits => Value = 0);

   -----------------
   -- Restrict_To --
   -----------------

   procedure Restrict_To (Set : in out Node_Set; Mask : Node_Set) is
   begin
      for Index in Set.Bits'Range loop
         Set.Bits (Index) := Set.Bits (Index) and Mask.Bits (Index);
      end loop;
   end Restrict_To;

   ------------
   -- Within --
   ------------

   function Within (Subset : Node_Set; Superset : Node_Set) return Boolean
   is (for all Index in Subset.Bits'Range => (Subset.Bits (Index) and not Superset.Bits (Index)) = 0);

   -----------
   -- First --
   -----------

   function First (Set : Node_Set) return Node_Cursor is
   begin
      for Index in 0 .. Max_Node loop
         if Contains (Set, Node_Id (Index)) then
            return Index;
         end if;
      end loop;

      return Max_Node + 1;
   end First;

   function First (Set : Processor_Set) return Processor_Cursor is
   begin
      for Index in 0 .. Max_Processor loop
         if Contains (Set, Processor_Id (Index)) then
            return Index;
         end if;
      end loop;

      return Max_Processor + 1;
   end First;

   ----------
   -- Next --
   ----------

   function Next (Set : Node_Set; Position : Node_Cursor) return Node_Cursor is
   begin
      for Index in Position + 1 .. Max_Node loop
         if Contains (Set, Node_Id (Index)) then
            return Index;
         end if;
      end loop;

      return Max_Node + 1;
   end Next;

   function Next (Set : Processor_Set; Position : Processor_Cursor) return Processor_Cursor is
   begin
      for Index in Position + 1 .. Max_Processor loop
         if Contains (Set, Processor_Id (Index)) then
            return Index;
         end if;
      end loop;

      return Max_Processor + 1;
   end Next;

   -----------------
   -- Has_Element --
   -----------------

   function Has_Element (Set : Node_Set; Position : Node_Cursor) return Boolean
   is (Position <= Max_Node and then Contains (Set, Node_Id (Position)));

   function Has_Element (Set : Processor_Set; Position : Processor_Cursor) return Boolean
   is (Position <= Max_Processor and then Contains (Set, Processor_Id (Position)));

   -------------
   -- Element --
   -------------

   function Element (Set : Node_Set; Position : Node_Cursor) return Node_Id is
      pragma Unreferenced (Set);
   begin
      return Node_Id (Position);
   end Element;

   function Element (Set : Processor_Set; Position : Processor_Cursor) return Processor_Id is
      pragma Unreferenced (Set);
   begin
      return Processor_Id (Position);
   end Element;

end Flyology_NUMA.Bits;
