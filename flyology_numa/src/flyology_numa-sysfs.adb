--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Strings.Fixed;
with Ada.Text_IO;

with Flyology_NUMA.Bits;

pragma Elaborate (Flyology_NUMA.Bits);

package body Flyology_NUMA.Sysfs is

   --  Largest number of comma-separated ranges one list may name.
   --
   --  A host that enumerates processors round-robin across its nodes gives
   --  each node a list of single-processor ranges, so a processor list can
   --  need one range per processor.  Bounding this below that would drop
   --  processors from such a host's nodes.
   Max_Ranges : constant := Max_Processor + 1;

   --  Bytes in the kilobyte unit the host uses to report memory.
   Report_Unit : constant Byte_Count := 1024;

   type Value_Range is record
      Low  : Natural := 0;
      High : Natural := 0;
   end record;

   type Range_Array is array (1 .. Max_Ranges) of Value_Range;

   function Is_Space (Item : Character) return Boolean is
     (Item = ' '
      or else Item = ASCII.HT
      or else Item = ASCII.CR
      or else Item = ASCII.LF);

   function Trimmed (Text : String) return String;

   function Read_First_Line (Path : String) return String;

   procedure Parse_Count
     (Text  : String;
      Value : out Byte_Count;
      Valid : out Boolean);

   procedure Parse_Natural
     (Text  : String;
      Value : out Natural;
      Valid : out Boolean);

   procedure Scan_Range_List
     (Text     : String;
      Ranges   : out Range_Array;
      Count    : out Natural;
      Valid    : out Boolean;
      Complete : out Boolean);

   function Read_Node_Set
     (Path     : String;
      Complete : in out Boolean;
      Found    : out Boolean) return Node_Set;

   function Read_Memory_Total (Path : String) return Byte_Query;

   function Node_Directory (Node_Root : String; Node : Node_Id) return String;

   function Image (Value : Natural) return String;

   -----------
   -- Image --
   -----------

   function Image (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   -------------
   -- Trimmed --
   -------------

   function Trimmed (Text : String) return String is
      First : Integer := Text'First;
      Last  : Integer := Text'Last;
   begin
      while First <= Last and then Is_Space (Text (First)) loop
         First := First + 1;
      end loop;

      while Last >= First and then Is_Space (Text (Last)) loop
         Last := Last - 1;
      end loop;

      return Text (First .. Last);
   end Trimmed;

   ---------------------
   -- Read_First_Line --
   ---------------------

   function Read_First_Line (Path : String) return String is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);

      declare
         Line : constant String :=
           (if Ada.Text_IO.End_Of_File (File) then ""
            else Ada.Text_IO.Get_Line (File));
      begin
         Ada.Text_IO.Close (File);
         return Line;
      end;
   exception
      --  A description this package cannot read is a description it does not
      --  have.  Reporting that is the caller's business, not this reader's.
      when others =>
         begin
            if Ada.Text_IO.Is_Open (File) then
               Ada.Text_IO.Close (File);
            end if;
         exception
            when others =>
               null;
         end;
         return "";
   end Read_First_Line;

   -------------------
   -- Parse_Natural --
   -------------------

   procedure Parse_Natural
     (Text  : String;
      Value : out Natural;
      Valid : out Boolean)
   is
      Result : Byte_Count;
   begin
      Parse_Count (Text, Result, Valid);

      if Valid and then Result > Byte_Count (Natural'Last) then
         Valid := False;
      end if;

      Value := (if Valid then Natural (Result) else 0);
   end Parse_Natural;

   -----------------
   -- Parse_Count --
   -----------------

   procedure Parse_Count
     (Text  : String;
      Value : out Byte_Count;
      Valid : out Boolean)
   is
      Result : Byte_Count := 0;
      Digit  : Byte_Count;
   begin
      Value := 0;
      Valid := False;

      if Text'Length = 0 then
         return;
      end if;

      for Item of Text loop
         if Item not in '0' .. '9' then
            return;
         end if;

         Digit := Byte_Count (Character'Pos (Item) - Character'Pos ('0'));

         --  Refuse a number too large to represent rather than wrapping it
         --  into a smaller one that would read as a plausible answer.
         if Result > (Byte_Count'Last - Digit) / 10 then
            return;
         end if;

         Result := Result * 10 + Digit;
      end loop;

      Value := Result;
      Valid := True;
   end Parse_Count;

   ---------------------
   -- Scan_Range_List --
   ---------------------

   procedure Scan_Range_List
     (Text     : String;
      Ranges   : out Range_Array;
      Count    : out Natural;
      Valid    : out Boolean;
      Complete : out Boolean)
   is
      Content : constant String := Trimmed (Text);
      Start   : Integer := Content'First;
      Stop    : Integer;
   begin
      Ranges := (others => (Low => 0, High => 0));
      Count := 0;
      Valid := True;
      Complete := True;

      --  An empty list is a legal answer.  A node carrying memory but no
      --  processor reports exactly this.
      if Content'Length = 0 then
         return;
      end if;

      loop
         Stop := Start;
         while Stop <= Content'Last and then Content (Stop) /= ',' loop
            Stop := Stop + 1;
         end loop;

         declare
            Item  : constant String := Trimmed (Content (Start .. Stop - 1));
            Split : Natural := 0;
            Low   : Natural;
            High  : Natural;
            Ok    : Boolean;
         begin
            if Item'Length = 0 then
               Valid := False;
               return;
            end if;

            for Index in Item'Range loop
               if Item (Index) = '-' then
                  Split := Index;
                  exit;
               end if;
            end loop;

            if Split = 0 then
               Parse_Natural (Item, Low, Ok);
               High := Low;
            else
               Parse_Natural (Item (Item'First .. Split - 1), Low, Ok);

               if Ok then
                  Parse_Natural (Item (Split + 1 .. Item'Last), High, Ok);
               else
                  High := 0;
               end if;
            end if;

            if not Ok or else High < Low then
               Valid := False;
               return;
            end if;

            if Count = Max_Ranges then
               Complete := False;
            else
               Count := Count + 1;
               Ranges (Count) := (Low => Low, High => High);
            end if;
         end;

         exit when Stop > Content'Last;
         Start := Stop + 1;
      end loop;
   end Scan_Range_List;

   --------------------
   -- Node_Directory --
   --------------------

   function Node_Directory
     (Node_Root : String; Node : Node_Id) return String is
     (Node_Root & "/node" & Image (Natural (Node)));

   -------------------
   -- Read_Node_Set --
   -------------------

   function Read_Node_Set
     (Path     : String;
      Complete : in out Boolean;
      Found    : out Boolean) return Node_Set
   is
      Text      : constant String := Read_First_Line (Path);
      Ranges    : Range_Array;
      Count     : Natural;
      Valid     : Boolean;
      Whole     : Boolean;
      Result    : Node_Set;
   begin
      Found := False;

      if Trimmed (Text)'Length = 0 then
         return Result;
      end if;

      Scan_Range_List (Text, Ranges, Count, Valid, Whole);

      if not Valid then
         return Result;
      end if;

      Complete := Complete and then Whole;
      Found := True;

      for Index in 1 .. Count loop
         if Ranges (Index).High > Max_Node then
            Complete := False;
         end if;

         for Value in Ranges (Index).Low
                      .. Natural'Min (Ranges (Index).High, Max_Node)
         loop
            Bits.Include (Result, Node_Id (Value));
         end loop;
      end loop;

      return Result;
   end Read_Node_Set;

   -----------------------
   -- Read_Memory_Total --
   -----------------------

   function Read_Memory_Total (Path : String) return Byte_Query is
      Marker : constant String := "MemTotal:";
      File   : Ada.Text_IO.File_Type;
      Result : Byte_Query := No_Bytes;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
            Mark : constant Natural := Ada.Strings.Fixed.Index (Line, Marker);
         begin
            if Mark > 0 then
               declare
                  Tail  : constant String :=
                    Trimmed (Line (Mark + Marker'Length .. Line'Last));
                  Stop  : Integer := Tail'First;
                  Value : Byte_Count;
                  Valid : Boolean;
               begin
                  while Stop <= Tail'Last
                    and then not Is_Space (Tail (Stop))
                  loop
                     Stop := Stop + 1;
                  end loop;

                  Parse_Count (Tail (Tail'First .. Stop - 1), Value, Valid);

                  --  The host reports this quantity in kilobytes.
                  if Valid and then Value <= Byte_Count'Last / Report_Unit then
                     Result := (Available => True,
                                Bytes     => Value * Report_Unit);
                  end if;
               end;

               exit;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
      return Result;
   exception
      when others =>
         begin
            if Ada.Text_IO.Is_Open (File) then
               Ada.Text_IO.Close (File);
            end if;
         exception
            when others =>
               null;
         end;
         return No_Bytes;
   end Read_Memory_Total;

   ----------
   -- Read --
   ----------

   procedure Read
     (Node_Root   : String;
      CPU_Root    : String;
      Status_Path : String;
      Facts       : out Machine_Facts;
      Success     : out Boolean)
   is
      Allowed_Marker : constant String := "Mems_allowed_list:";

      Found          : Boolean;
      Highest        : Integer := -1;
      Seen           : Processor_Set;
      Unread         : Machine_Facts;
   begin
      --  Start from a description that says nothing, so that a caller
      --  reusing one object across two reads cannot carry the first result
      --  into the second.
      Facts := Unread;
      Success := False;
      Facts.Source := Host_Report;

      --  The set of online nodes is the description.  Without it there is
      --  nothing here to read.
      Facts.Online := Read_Node_Set
        (Node_Root & "/online", Facts.Complete, Found);

      if not Found or else Bits.Is_Empty (Facts.Online) then
         return;
      end if;

      --  Nodes that carry memory.  Newer hosts name this directly; older
      --  ones name only the ordinary memory they carry.
      Facts.With_Memory := Read_Node_Set
        (Node_Root & "/has_memory", Facts.Complete, Found);

      if not Found then
         Facts.With_Memory := Read_Node_Set
           (Node_Root & "/has_normal_memory", Facts.Complete, Found);
      end if;

      if not Found then
         Facts.With_Memory := Facts.Online;
      end if;

      --  Per-node processors, memory, and distances.
      for Node in Node_Id loop
         if Bits.Contains (Facts.Online, Node) then
            declare
               Directory : constant String :=
                 Node_Directory (Node_Root, Node);
               Ranges    : Range_Array;
               Count     : Natural;
               Valid     : Boolean;
               Whole     : Boolean;
            begin
               Scan_Range_List
                 (Read_First_Line (Directory & "/cpulist"),
                  Ranges, Count, Valid, Whole);

               --  A list this package cannot read leaves the node's
               --  processors unknown.  Saying so keeps it distinct from a
               --  node that genuinely has no processor attached.
               Facts.Complete := Facts.Complete and then Valid and then Whole;

               if Valid then
                  for Index in 1 .. Count loop
                     if Ranges (Index).High > Max_Processor then
                        Facts.Complete := False;
                     end if;

                     for Value in Ranges (Index).Low
                                  .. Natural'Min (Ranges (Index).High,
                                                  Max_Processor)
                     loop
                        Bits.Include (Facts.Nodes (Node).Processors,
                                 Processor_Id (Value));
                        Bits.Include (Seen, Processor_Id (Value));
                        Facts.Owner (Processor_Id (Value)) :=
                          (Available => True, Node => Node);
                        Highest := Integer'Max (Highest, Value);
                     end loop;
                  end loop;
               end if;

               Facts.Nodes (Node).Memory :=
                 Read_Memory_Total (Directory & "/meminfo");

               --  A distance row names one value per online node, in
               --  increasing node order, so the values are matched against
               --  the online set rather than against node numbers.
               declare
                  Row     : constant String :=
                    Trimmed (Read_First_Line (Directory & "/distance"));
                  Start   : Integer := Row'First;
                  Stop    : Integer;
                  Value   : Natural;
                  Ok      : Boolean;
                  Column  : Node_Cursor := Bits.First (Facts.Online);
               begin
                  while Start <= Row'Last
                    and then Bits.Has_Element (Facts.Online, Column)
                  loop
                     Stop := Start;
                     while Stop <= Row'Last
                       and then not Is_Space (Row (Stop))
                     loop
                        Stop := Stop + 1;
                     end loop;

                     Parse_Natural (Row (Start .. Stop - 1), Value, Ok);

                     if Ok and then Value <= Natural (Distance'Last) then
                        Facts.Nodes (Node).Distances
                          (Bits.Element (Facts.Online, Column)) :=
                            (Available => True, Value => Distance (Value));
                     end if;

                     Column := Bits.Next (Facts.Online, Column);

                     Start := Stop;
                     while Start <= Row'Last
                       and then Is_Space (Row (Start))
                     loop
                        Start := Start + 1;
                     end loop;
                  end loop;
               end;
            end;
         end if;
      end loop;

      --  Every machine has a processor.  A description that attaches none to
      --  any node was not read, however many nodes it named, so the caller
      --  describes the host some other way rather than reporting a machine
      --  that cannot run anything.
      if Bits.Is_Empty (Seen) then
         return;
      end if;

      --  A node's processor package is read from one of its processors.  Two
      --  nodes reporting one package number are two memory domains of one
      --  package.
      for Node in Node_Id loop
         if Bits.Contains (Facts.Online, Node)
           and then not Bits.Is_Empty (Facts.Nodes (Node).Processors)
         then
            declare
               Lead  : constant Processor_Id :=
                 Bits.Element (Facts.Nodes (Node).Processors,
                          Bits.First (Facts.Nodes (Node).Processors));
               Value : Natural;
               Ok    : Boolean;
            begin
               Parse_Natural
                 (Trimmed (Read_First_Line
                    (CPU_Root & "/cpu" & Image (Natural (Lead))
                     & "/topology/physical_package_id")),
                  Value, Ok);

               if Ok then
                  Facts.Nodes (Node).Packaging :=
                    (Available => True, Value => Value);
               end if;
            end;
         end if;
      end loop;

      --  The nodes this process may use.  A container is shown the whole
      --  host description while a control group restricts what it may
      --  allocate on, so the description alone does not establish this.
      declare
         File    : Ada.Text_IO.File_Type;
         Allowed : Node_Set;
         Known   : Boolean := False;
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Status_Path);

         while not Ada.Text_IO.End_Of_File (File) loop
            declare
               Line : constant String := Ada.Text_IO.Get_Line (File);
               Mark : constant Natural :=
                 Ada.Strings.Fixed.Index (Line, Allowed_Marker);
               Ranges : Range_Array;
               Count  : Natural;
               Valid  : Boolean;
               Whole  : Boolean;
            begin
               if Mark > 0 then
                  Scan_Range_List
                    (Line (Mark + Allowed_Marker'Length .. Line'Last),
                     Ranges, Count, Valid, Whole);

                  if Valid then
                     for Index in 1 .. Count loop
                        for Value in Ranges (Index).Low
                                     .. Natural'Min (Ranges (Index).High,
                                                     Max_Node)
                        loop
                           Bits.Include (Allowed, Node_Id (Value));
                        end loop;
                     end loop;

                     Facts.Complete := Facts.Complete and then Whole;
                     Known := not Bits.Is_Empty (Allowed);
                  end if;

                  --  The host named the permitted nodes and this package did
                  --  not understand the answer.  Reporting every node as
                  --  permitted would invite a caller to allocate where it
                  --  may not, so the shortfall is recorded instead.
                  if not Known then
                     Facts.Complete := False;
                  end if;

                  exit;
               end if;
            end;
         end loop;

         Ada.Text_IO.Close (File);

         if Known then
            Facts.Allowed := Allowed;
            Bits.Restrict_To (Facts.Allowed, Facts.Online);

            --  The host permitted only nodes it does not have online.  That
            --  answer cannot be acted on, so it is not reported as one.
            if Bits.Is_Empty (Facts.Allowed) then
               Facts.Complete := False;
            end if;
         end if;
      exception
         when others =>
            begin
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
            exception
               when others =>
                  null;
            end;
      end;

      --  A host that does not say which nodes this process may use is taken
      --  at its word that all of them are usable.
      if Bits.Is_Empty (Facts.Allowed) then
         Facts.Allowed := Facts.Online;
      end if;

      Facts.Restricted := not Bits.Within (Facts.Online, Facts.Allowed);

      --  Ada numbers processors from one and expects them to be consecutive.
      --  Record whether this host's numbering can carry that mapping.
      Facts.Consecutive_Processors :=
        Highest >= 0 and then Bits.Count (Seen) = Highest + 1;

      Success := True;
   end Read;

end Flyology_NUMA.Sysfs;
