with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces.C;

package body Flyology_Cachelines.Linux is

   use type Interfaces.C.long;

   --  These are glibc's stable _SC_LEVEL1_DCACHE_* ABI numbers.  Libcs with
   --  different numbering fail this query and fall through to Linux sysfs.
   SC_Level_1_DCache_Size      : constant Interfaces.C.int := 188;
   SC_Level_1_DCache_Line_Size : constant Interfaces.C.int := 190;

   function Sysconf (Name : Interfaces.C.int) return Interfaces.C.long
     with Import,
          Convention    => C,
          External_Name => "sysconf";

   function Detect_From_Sysconf return Cache_Parameters is
      Line_Size  : constant Interfaces.C.long :=
        Sysconf (SC_Level_1_DCache_Line_Size);
      Total_Size : constant Interfaces.C.long :=
        Sysconf (SC_Level_1_DCache_Size);
   begin
      if Line_Size <= 0
        or else Total_Size <= 0
        or else Line_Size > Interfaces.C.long (Positive'Last)
        or else Total_Size > Interfaces.C.long (Positive'Last)
      then
         return No_Cache_Parameters;
      end if;

      return
        (Available  => True,
         Line_Size  => Positive (Line_Size),
         Total_Size => Positive (Total_Size));
   exception
      when others =>
         return No_Cache_Parameters;
   end Detect_From_Sysconf;

   function Read_Trimmed
     (Path : String) return Ada.Strings.Unbounded.Unbounded_String
   is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      declare
         Line : constant String := Ada.Text_IO.Get_Line (File);
      begin
         Ada.Text_IO.Close (File);
         return
           Ada.Strings.Unbounded.To_Unbounded_String
             (Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both));
      end;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return Ada.Strings.Unbounded.Null_Unbounded_String;
   end Read_Trimmed;

   function Parse_Size (Text : String) return Positive is
      Last       : Positive := Text'Last;
      Multiplier : Positive := 1;
   begin
      if Text (Last) = 'K' or else Text (Last) = 'k' then
         Multiplier := 1_024;
         Last := Last - 1;
      elsif Text (Last) = 'M' or else Text (Last) = 'm' then
         Multiplier := 1_024 * 1_024;
         Last := Last - 1;
      end if;

      return Positive'Value (Text (Text'First .. Last)) * Multiplier;
   end Parse_Size;

   --  Leading integer of a cpu list such as "0,24" or "3-7", or -1 when the
   --  text holds none.  A cache's shared_cpu_list is ascending, so its
   --  leading index names the first CPU sharing that cache.
   function Leading_Index (Text : String) return Integer is
      Last : Natural := Text'First;
   begin
      if Text'Length = 0 or else Text (Text'First) not in '0' .. '9' then
         return -1;
      end if;

      while Last < Text'Last and then Text (Last + 1) in '0' .. '9' loop
         Last := Last + 1;
      end loop;

      return Integer'Value (Text (Text'First .. Last));
   exception
      when others =>
         return -1;
   end Leading_Index;

   --  What one CPU reports about itself.  Capacity is zero when the host
   --  publishes none.  Leads_Cache is true when this CPU is the first of
   --  those sharing its L1 data cache, which makes it the representative of
   --  one physical core: SMT siblings share that cache.
   type CPU_Description (Available : Boolean := False) is record
      case Available is
         when True =>
            Line_Size   : Positive;
            Total_Size  : Positive;
            Capacity    : Natural;
            Leads_Cache : Boolean;
         when False =>
            null;
      end case;
   end record;

   No_CPU_Description : constant CPU_Description := (Available => False);

   function Describe_CPU
     (Root : String;
      CPU  : Natural) return CPU_Description
   is
      use Ada.Strings.Unbounded;

      CPU_Image : constant String :=
        Ada.Strings.Fixed.Trim (CPU'Image, Ada.Strings.Both);
      CPU_Path  : constant String := Root & "cpu" & CPU_Image & "/";
      Base      : constant String := CPU_Path & "cache/index";

      --  A host that publishes no capacity leaves every class at zero, which
      --  orders nothing and selects the geometry rung.
      Capacity_Text : constant String :=
        To_String (Read_Trimmed (CPU_Path & "cpu_capacity"));
      Capacity      : constant Natural :=
        (if Capacity_Text'Length = 0 then 0
         else Natural'Max (Leading_Index (Capacity_Text), 0));
   begin
      for Index in 0 .. 7 loop
         declare
            Index_Image : constant String :=
              Ada.Strings.Fixed.Trim (Index'Image, Ada.Strings.Both);
            Path        : constant String := Base & Index_Image & "/";
            Level       : constant String :=
              To_String (Read_Trimmed (Path & "level"));
            Kind        : constant String :=
              To_String (Read_Trimmed (Path & "type"));
         begin
            if Level = "1" and then (Kind = "Data" or else Kind = "Unified")
            then
               declare
                  Line_Size : constant Positive :=
                    Parse_Size
                      (To_String
                         (Read_Trimmed (Path & "coherency_line_size")));
                  Total_Size : constant Positive :=
                    Parse_Size (To_String (Read_Trimmed (Path & "size")));
                  Shared     : constant String :=
                    To_String (Read_Trimmed (Path & "shared_cpu_list"));
                  Leader     : constant Integer := Leading_Index (Shared);
               begin
                  return
                    (Available   => True,
                     Line_Size   => Line_Size,
                     Total_Size  => Total_Size,
                     Capacity    => Capacity,
                     --  An unreadable sharing list makes every CPU its own
                     --  core, which is right whenever SMT is absent.
                     Leads_Cache => Leader = CPU or else Leader < 0);
               end;
            end if;
         end;
      end loop;

      return No_CPU_Description;
   exception
      when others =>
         return No_CPU_Description;
   end Describe_CPU;

   function Detect_From_Sysfs return Cache_Parameters is
      Found : constant CPU_Description := Describe_CPU (Default_CPU_Root, 0);
   begin
      return
        (if Found.Available
         then (Available  => True,
               Line_Size  => Found.Line_Size,
               Total_Size => Found.Total_Size)
         else No_Cache_Parameters);
   end Detect_From_Sysfs;

   --  A host that lists thousands of CPUs is bounded rather than walked.
   Max_Enumerated_CPU : constant := 4_095;

   --  Highest CPU index the host lists as present.  A cpu list ends with its
   --  largest index whether it is written "0-15" or "0-3,8-11", so the
   --  trailing run of digits is the value wanted.  A missing or malformed
   --  list leaves only CPU 0 to enumerate.
   function Highest_Present_CPU (Root : String) return Natural is
      Text  : constant String :=
        Ada.Strings.Unbounded.To_String (Read_Trimmed (Root & "present"));
      Last  : Natural := Text'Last;
      First : Natural;
   begin
      while Last >= Text'First and then Text (Last) not in '0' .. '9' loop
         Last := Last - 1;
      end loop;

      if Last < Text'First then
         return 0;
      end if;

      First := Last;
      while First > Text'First and then Text (First - 1) in '0' .. '9' loop
         First := First - 1;
      end loop;

      return Natural'Min (Natural'Value (Text (First .. Last)),
                          Max_Enumerated_CPU);
   exception
      when others =>
         return 0;
   end Highest_Present_CPU;

   --  An ordering key means something only when it does not give every
   --  class the same value.  A host publishing no capacity leaves them all
   --  at zero, which is exactly the case that must fall through.
   function Separated_By_Capacity (Classes : Core_Classes) return Boolean is
   begin
      for Index in 2 .. Classes.Count loop
         if Classes.Classes (Index).Capacity /= Classes.Classes (1).Capacity
         then
            return True;
         end if;
      end loop;
      return False;
   end Separated_By_Capacity;

   function Separated_By_Geometry (Classes : Core_Classes) return Boolean is
   begin
      for Index in 2 .. Classes.Count loop
         if Classes.Classes (Index).Total_Size /=
              Classes.Classes (1).Total_Size
         then
            return True;
         end if;
      end loop;
      return False;
   end Separated_By_Geometry;

   --  Insertion sort into descending order of the selected key.
   procedure Order_Classes
     (Classes     : in out Core_Classes;
      By_Capacity : Boolean)
   is
      function Key (Class : Core_Class_Parameters) return Natural is
        (if By_Capacity then Class.Capacity else Class.Total_Size);
   begin
      for Index in 2 .. Classes.Count loop
         declare
            Moving : constant Core_Class_Parameters :=
              Classes.Classes (Index);
            Place  : Natural := Index - 1;
         begin
            while Place >= 1
              and then Key (Classes.Classes (Place)) < Key (Moving)
            loop
               Classes.Classes (Place + 1) := Classes.Classes (Place);
               Place := Place - 1;
            end loop;
            Classes.Classes (Place + 1) := Moving;
         end;
      end loop;
   end Order_Classes;

   function Detect_Core_Classes
     (Root : String := Default_CPU_Root) return Core_Classes
   is
      Highest : constant Natural := Highest_Present_CPU (Root);
      Result  : Core_Classes := No_Core_Classes;
   begin
      for CPU in 0 .. Highest loop
         declare
            Found   : constant CPU_Description := Describe_CPU (Root, CPU);
            Matched : Boolean := False;
         begin
            if Found.Available then
               --  Capacity joins the grouping key so two core types that
               --  share a geometry stay separate when the host rates them
               --  differently.
               for Index in 1 .. Result.Count loop
                  if Result.Classes (Index).Line_Size = Found.Line_Size
                    and then Result.Classes (Index).Total_Size =
                               Found.Total_Size
                    and then Result.Classes (Index).Capacity = Found.Capacity
                  then
                     Result.Classes (Index).CPUs :=
                       Result.Classes (Index).CPUs + 1;
                     if Found.Leads_Cache then
                        Result.Classes (Index).Cores :=
                          Result.Classes (Index).Cores + 1;
                     end if;
                     Matched := True;
                     exit;
                  end if;
               end loop;

               if not Matched then
                  --  More classes than the table holds.  Report none rather
                  --  than a table that silently omits a class.
                  if Result.Count = Max_Core_Classes then
                     return No_Core_Classes;
                  end if;

                  Result.Count := Result.Count + 1;
                  Result.Classes (Result.Count) :=
                    (Available  => True,
                     Line_Size  => Found.Line_Size,
                     Total_Size => Found.Total_Size,
                     --  A class always holds at least one core.  When a
                     --  non-leading CPU opens one, its leader was skipped
                     --  as unreadable and this count is a floor.
                     Cores      => 1,
                     CPUs       => 1,
                     Capacity   => Found.Capacity);
               end if;
            end if;
         end;
      end loop;

      --  Prefer the kernel's own capacity values, and fall back to the
      --  geometry inference only when no capacity separates the classes.
      --  The specification records what each ordering is worth.
      Result.Ordering :=
        (if Result.Count < 2 then Unordered
         elsif Separated_By_Capacity (Result) then Host_Reported
         elsif Separated_By_Geometry (Result) then Inferred
         else Unordered);

      case Result.Ordering is
         when Host_Reported =>
            Order_Classes (Result, By_Capacity => True);
         when Inferred =>
            Order_Classes (Result, By_Capacity => False);
         when Unordered =>
            null;
      end case;

      return Result;
   exception
      when others =>
         return No_Core_Classes;
   end Detect_Core_Classes;

end Flyology_Cachelines.Linux;
