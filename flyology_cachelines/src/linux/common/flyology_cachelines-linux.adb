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

   function Detect_From_Sysfs return Cache_Parameters is
      use Ada.Strings.Unbounded;

      Base : constant String := "/sys/devices/system/cpu/cpu0/cache/index";
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
                    Parse_Size
                      (To_String (Read_Trimmed (Path & "size")));
               begin
                  return
                    (Available  => True,
                     Line_Size  => Line_Size,
                     Total_Size => Total_Size);
               end;
            end if;
         end;
      end loop;

      return No_Cache_Parameters;
   exception
      when others =>
         return No_Cache_Parameters;
   end Detect_From_Sysfs;

end Flyology_Cachelines.Linux;
