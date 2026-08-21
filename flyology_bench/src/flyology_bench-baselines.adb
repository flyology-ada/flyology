--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Numerics.Long_Elementary_Functions;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology_Bench.Metadata;
with Interfaces;
with Interfaces.C;
with System;

package body Flyology_Bench.Baselines is
   package Math renames Ada.Numerics.Long_Elementary_Functions;
   package Unbounded renames Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_64;
   use type Interfaces.C.int;
   use type Interfaces.C.ptrdiff_t;

   Magic : constant String := "flyology_bench baseline";
   Footer : constant String := "flyology_bench baseline v2";
   Legacy_Magic : constant String := "flyology_bench baseline v1";
   Bootstrap_Method_Text : constant String := "circular_block_mean_ratio";
   Default_Confidence_Level_Percent : constant Long_Float := 95.0;
   Default_Bootstrap_Resamples : constant Positive := 2_000;
   FNV_Offset : constant Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   FNV_Prime  : constant Interfaces.Unsigned_64 := 16#0000_0100_0000_01B3#;

   type Float_Array is array (Positive range <>) of Long_Float;
   type Seen_Array is array (Sample_Index'Range) of Boolean;

   function C_Mkstemp (Template : System.Address) return Interfaces.C.int;
   pragma Import (C, C_Mkstemp, "mkstemp");

   function C_Write
     (Descriptor : Interfaces.C.int;
      Buffer     : System.Address;
      Count      : Interfaces.C.size_t) return Interfaces.C.ptrdiff_t;
   pragma Import (C, C_Write, "write");

   function C_Fsync (Descriptor : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Fsync, "fsync");

   function C_Close (Descriptor : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Close, "close");

   function C_Rename
     (Old_Path : System.Address;
      New_Path : System.Address) return Interfaces.C.int;
   pragma Import (C, C_Rename, "rename");

   function C_Unlink (Path : System.Address) return Interfaces.C.int;
   pragma Import (C, C_Unlink, "unlink");

   procedure Validate_Text
     (Value       : String;
      Field       : String;
      Allow_Empty : Boolean := True) is
   begin
      if not Allow_Empty and then Value'Length = 0 then
         raise Constraint_Error with Field & " must not be empty";
      end if;
      for Character of Value loop
         if Character = ASCII.LF or else Character = ASCII.CR then
            raise Constraint_Error with Field & " must not contain newlines";
         elsif Character = ASCII.NUL then
            raise Constraint_Error with Field & " must not contain NUL bytes";
         end if;
      end loop;
   end Validate_Text;

   procedure Hash_Text
     (State : in out Interfaces.Unsigned_64;
      Value : String) is
   begin
      for Character of Value loop
         State :=
           (State xor Interfaces.Unsigned_64
              (Standard.Character'Pos (Character)))
           * FNV_Prime;
      end loop;
   end Hash_Text;

   procedure Hash_Line
     (State : in out Interfaces.Unsigned_64;
      Value : String) is
   begin
      Hash_Text (State, Value);
      State :=
        (State xor Interfaces.Unsigned_64
           (Standard.Character'Pos (ASCII.LF)))
        * FNV_Prime;
   end Hash_Line;

   function Hex_Image (Value : Interfaces.Unsigned_64) return String is
      Hex_Digits : constant String := "0123456789abcdef";
      Result : String (1 .. 16);
      Work   : Interfaces.Unsigned_64 := Value;
   begin
      for Position in reverse Result'Range loop
         Result (Position) :=
           Hex_Digits
             (Natural (Work and 16#F#) + Hex_Digits'First);
         Work := Interfaces.Shift_Right (Work, 4);
      end loop;
      return Result;
   end Hex_Image;

   function Hex_Value (Value : String) return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64 := 0;
      Digit  : Interfaces.Unsigned_64;
   begin
      if Value'Length /= 16 then
         raise Baseline_Format_Error with
           "baseline checksum must contain exactly 16 hexadecimal digits";
      end if;
      for Character of Value loop
         if Character in '0' .. '9' then
            Digit := Interfaces.Unsigned_64
              (Standard.Character'Pos (Character)
               - Standard.Character'Pos ('0'));
         elsif Character in 'a' .. 'f' then
            Digit := Interfaces.Unsigned_64
              (10 + Standard.Character'Pos (Character)
               - Standard.Character'Pos ('a'));
         elsif Character in 'A' .. 'F' then
            Digit := Interfaces.Unsigned_64
              (10 + Standard.Character'Pos (Character)
               - Standard.Character'Pos ('A'));
         else
            raise Baseline_Format_Error with
              "baseline checksum contains a non-hexadecimal digit";
         end if;
         Result := Interfaces.Shift_Left (Result, 4) or Digit;
      end loop;
      return Result;
   end Hex_Value;

   procedure Sort (Values : in out Float_Array) is
   begin
      for Index in Values'First + 1 .. Values'Last loop
         declare
            Value : constant Long_Float := Values (Index);
            Position : Positive := Index;
         begin
            while Position > Values'First
              and then Values (Position - 1) > Value
            loop
               Values (Position) := Values (Position - 1);
               Position := Position - 1;
            end loop;
            Values (Position) := Value;
         end;
      end loop;
   end Sort;

   function Percentile
     (Ordered : Float_Array;
      Fraction : Long_Float) return Long_Float
   is
      Position : constant Long_Float :=
        Long_Float (Ordered'First)
        + Fraction * Long_Float (Ordered'Length - 1);
      Lower : constant Positive := Positive (Long_Float'Floor (Position));
      Upper : constant Positive := Positive (Long_Float'Ceiling (Position));
      Weight : constant Long_Float := Position - Long_Float (Lower);
   begin
      return Ordered (Lower) * (1.0 - Weight) + Ordered (Upper) * Weight;
   end Percentile;

   function Next_Random
     (State : in out Interfaces.Unsigned_64) return Interfaces.Unsigned_64 is
   begin
      State := State xor Interfaces.Shift_Left (State, 13);
      State := State xor Interfaces.Shift_Right (State, 7);
      State := State xor Interfaces.Shift_Left (State, 17);
      return State;
   end Next_Random;

   procedure Publish_Atomically
     (Path    : String;
      Content : String)
   is
      Template : aliased Interfaces.C.char_array :=
        Interfaces.C.To_C (Path & ".tmp.XXXXXX");
      Target : aliased Interfaces.C.char_array := Interfaces.C.To_C (Path);
      Descriptor : Interfaces.C.int := -1;
      Written : Natural := 0;
      Published : Boolean := False;
   begin
      Descriptor := C_Mkstemp (Template'Address);
      if Descriptor < 0 then
         raise Baseline_IO_Error with
           "cannot create temporary baseline beside " & Path;
      end if;
      while Written < Content'Length loop
         declare
            Amount : constant Interfaces.C.ptrdiff_t :=
              C_Write
                (Descriptor,
                 Content (Content'First + Written)'Address,
                 Interfaces.C.size_t (Content'Length - Written));
         begin
            if Amount <= 0 then
               raise Baseline_IO_Error with
                 "cannot write temporary baseline beside " & Path;
            end if;
            Written := Written + Natural (Amount);
         end;
      end loop;
      if C_Fsync (Descriptor) /= 0 then
         raise Baseline_IO_Error with
           "cannot flush temporary baseline beside " & Path;
      end if;
      if C_Close (Descriptor) /= 0 then
         Descriptor := -1;
         raise Baseline_IO_Error with
           "cannot close temporary baseline beside " & Path;
      end if;
      Descriptor := -1;
      if C_Rename (Template'Address, Target'Address) /= 0 then
         raise Baseline_IO_Error with
           "cannot atomically publish baseline at " & Path;
      end if;
      Published := True;
   exception
      when others =>
         if Descriptor >= 0 then
            declare
               Ignored : constant Interfaces.C.int := C_Close (Descriptor);
            begin
               null;
            end;
         end if;
         if not Published then
            declare
               Ignored : constant Interfaces.C.int := C_Unlink (Template'Address);
            begin
               null;
            end;
         end if;
         raise;
   end Publish_Atomically;

   procedure Save
     (Path        : String;
      Name        : String;
      Result      : Measurement;
      Fingerprint : String := "")
   is
      Effective_Fingerprint : constant String :=
        (if Fingerprint'Length = 0
         then Flyology_Bench.Metadata.Fingerprint
         else Fingerprint);
      Artifact : Unbounded.Unbounded_String;
      Hash : Interfaces.Unsigned_64 := FNV_Offset;

      procedure Append_Field (Key, Value : String) is
         Line : constant String := Key & "=" & Value;
      begin
         Unbounded.Append (Artifact, Line & ASCII.LF);
         Hash_Line (Hash, Line);
      end Append_Field;
   begin
      Validate_Text (Path, "baseline path", Allow_Empty => False);
      Validate_Text (Name, "baseline name", Allow_Empty => False);
      Validate_Text
        (Effective_Fingerprint, "baseline fingerprint", Allow_Empty => False);
      Validate_Text
        (Clock_Backend (Result), "clock backend", Allow_Empty => False);
      if Name'Length > 256 then
         raise Constraint_Error with "baseline name is too long";
      elsif Effective_Fingerprint'Length > 1_024 then
         raise Constraint_Error with "baseline fingerprint is too long";
      elsif Clock_Backend (Result)'Length > 64 then
         raise Constraint_Error with "clock backend is too long";
      end if;

      Unbounded.Append (Artifact, Magic & ASCII.LF);
      Hash_Line (Hash, Magic);
      Append_Field ("schema_version", "2");
      Append_Field ("benchmark_name", Name);
      Append_Field ("fingerprint", Effective_Fingerprint);
      Append_Field ("clock_backend", Clock_Backend (Result));
      Append_Field ("sample_unit", "nanoseconds_per_operation");
      Append_Field ("comparison_design", "independent_runs");
      Append_Field ("bootstrap_method", Bootstrap_Method_Text);
      Append_Field ("sample_count", Sample_Count'Image (Samples (Result)));
      for Index in Sample_Index range 1 .. Sample_Index (Samples (Result)) loop
         declare
            Value : constant Long_Float := Sample_Nanoseconds (Result, Index);
         begin
            if not (Value > 0.0) or else Value > Long_Float'Last then
               raise Constraint_Error with
                 "baseline samples must contain positive finite times";
            end if;
            Append_Field
              ("sample." & Ada.Strings.Fixed.Trim
                 (Sample_Index'Image (Index), Ada.Strings.Both),
               Long_Float'Image (Value));
         end;
      end loop;
      Unbounded.Append (Artifact, "checksum=" & Hex_Image (Hash) & ASCII.LF);
      Unbounded.Append (Artifact, "end=" & Footer & ASCII.LF);
      Publish_Atomically (Path, Unbounded.To_String (Artifact));
   end Save;

   function Load (Path : String) return Baseline is
      File : Ada.Text_IO.File_Type;
      Result : Baseline;
      Hash : Interfaces.Unsigned_64 := FNV_Offset;
      Samples_Seen : Seen_Array := [others => False];
      Stored_Hash : Interfaces.Unsigned_64 := 0;
      Seen_Schema, Seen_Name, Seen_Fingerprint, Seen_Backend : Boolean := False;
      Seen_Unit, Seen_Design, Seen_Method, Seen_Count : Boolean := False;

      procedure Store
        (Value  : String;
         Buffer : out String;
         Length : out Natural;
         Field  : String;
         Allow_Empty : Boolean := False) is
      begin
         Validate_Text (Value, Field, Allow_Empty => Allow_Empty);
         if not Allow_Empty and then Value'Length = 0 then
            raise Baseline_Format_Error with Field & " must not be empty";
         elsif Value'Length > Buffer'Length then
            raise Baseline_Format_Error with Field & " is too long";
         end if;
         Length := Value'Length;
         Buffer := [others => ' '];
         if Length > 0 then
            Buffer (Buffer'First .. Buffer'First + Length - 1) := Value;
         end if;
      end Store;

      procedure Duplicate (Field : String; Seen : in out Boolean) is
      begin
         if Seen then
            raise Baseline_Format_Error with
              "baseline contains duplicate " & Field & " field";
         end if;
         Seen := True;
      end Duplicate;

      function Required_Line (Description : String) return String is
      begin
         if Ada.Text_IO.End_Of_File (File) then
            raise Baseline_Format_Error with
              "baseline is truncated before " & Description;
         end if;
         return Ada.Text_IO.Get_Line (File);
      end Required_Line;

      function Parse_Count (Value : String) return Sample_Count is
      begin
         return Sample_Count'Value (Value);
      exception
         when Constraint_Error =>
            raise Baseline_Format_Error with
              "baseline sample_count is malformed or out of range";
      end Parse_Count;

      function Parse_Index (Value : String) return Sample_Index is
      begin
         return Sample_Index'Value (Value);
      exception
         when Constraint_Error =>
            raise Baseline_Format_Error with
              "baseline sample index is malformed or out of range";
      end Parse_Index;

      function Parse_Sample (Value : String; Index : Sample_Index)
        return Long_Float is
         Parsed : Long_Float;
      begin
         Parsed := Long_Float'Value (Value);
         if not (Parsed > 0.0) or else Parsed > Long_Float'Last then
            raise Constraint_Error;
         end if;
         return Parsed;
      exception
         when Constraint_Error =>
            raise Baseline_Format_Error with
              "baseline sample" & Sample_Index'Image (Index)
              & " is malformed, nonpositive, or out of range";
      end Parse_Sample;

      procedure Parse_Legacy is
      begin
         Store
           (Required_Line ("legacy benchmark name"),
            Result.Name_Data, Result.Name_Length,
            "legacy baseline benchmark_name", Allow_Empty => True);
         Store
           (Required_Line ("legacy fingerprint"),
            Result.Fingerprint_Data, Result.Fingerprint_Length,
            "legacy baseline fingerprint", Allow_Empty => True);
         Store
           (Required_Line ("legacy clock backend"),
            Result.Backend_Id, Result.Backend_Id_Length,
            "legacy baseline clock_backend");
         Result.Sample_Total :=
           Parse_Count (Required_Line ("legacy sample_count"));
         for Index in Sample_Index range
           1 .. Sample_Index (Result.Sample_Total)
         loop
            Result.Values (Index) :=
              Parse_Sample
                (Required_Line
                   ("legacy sample" & Sample_Index'Image (Index)),
                 Index);
         end loop;
         if not Ada.Text_IO.End_Of_File (File) then
            raise Baseline_Format_Error with
              "legacy baseline contains unexpected trailing data";
         end if;
      end Parse_Legacy;
   begin
      Validate_Text (Path, "baseline path", Allow_Empty => False);
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      declare
         First : constant String := Required_Line ("format header");
      begin
         if First = Legacy_Magic then
            Parse_Legacy;
            Ada.Text_IO.Close (File);
            return Result;
         elsif First /= Magic then
            raise Baseline_Format_Error with
              "unsupported benchmark baseline format";
         end if;
         Hash_Line (Hash, First);
      end;

      loop
         declare
            Line : constant String := Required_Line ("checksum");
            Equal : constant Natural := Ada.Strings.Fixed.Index (Line, "=");
         begin
            if Equal = 0 then
               raise Baseline_Format_Error with
                 "baseline field has no '=' separator";
            end if;
            declare
               Key   : constant String := Line (Line'First .. Equal - 1);
               Value : constant String := Line (Equal + 1 .. Line'Last);
            begin
               if Key = "checksum" then
                  Stored_Hash := Hex_Value (Value);
                  exit;
               end if;
               Hash_Line (Hash, Line);
               if Key = "schema_version" then
                  Duplicate ("schema_version", Seen_Schema);
                  if Value /= "2" then
                     raise Baseline_Format_Error with
                       "unsupported benchmark baseline schema version " & Value;
                  end if;
               elsif Key = "benchmark_name" then
                  Duplicate ("benchmark_name", Seen_Name);
                  Store
                    (Value, Result.Name_Data, Result.Name_Length,
                     "baseline benchmark_name");
               elsif Key = "fingerprint" then
                  Duplicate ("fingerprint", Seen_Fingerprint);
                  Store
                    (Value, Result.Fingerprint_Data, Result.Fingerprint_Length,
                     "baseline fingerprint");
               elsif Key = "clock_backend" then
                  Duplicate ("clock_backend", Seen_Backend);
                  Store
                    (Value, Result.Backend_Id, Result.Backend_Id_Length,
                     "baseline clock_backend");
               elsif Key = "sample_unit" then
                  Duplicate ("sample_unit", Seen_Unit);
                  if Value /= "nanoseconds_per_operation" then
                     raise Baseline_Format_Error with
                       "unsupported baseline sample_unit " & Value;
                  end if;
               elsif Key = "comparison_design" then
                  Duplicate ("comparison_design", Seen_Design);
                  if Value /= "independent_runs" then
                     raise Baseline_Format_Error with
                       "unsupported baseline comparison_design " & Value;
                  end if;
               elsif Key = "bootstrap_method" then
                  Duplicate ("bootstrap_method", Seen_Method);
                  if Value /= Bootstrap_Method_Text then
                     raise Baseline_Format_Error with
                       "unsupported baseline bootstrap_method " & Value;
                  end if;
               elsif Key = "sample_count" then
                  Duplicate ("sample_count", Seen_Count);
                  Result.Sample_Total := Parse_Count (Value);
               elsif Key'Length > 7
                 and then Key (Key'First .. Key'First + 6) = "sample."
               then
                  declare
                     Index : constant Sample_Index :=
                       Parse_Index (Key (Key'First + 7 .. Key'Last));
                  begin
                     if Samples_Seen (Index) then
                        raise Baseline_Format_Error with
                          "baseline contains duplicate sample"
                          & Sample_Index'Image (Index);
                     end if;
                     Samples_Seen (Index) := True;
                     Result.Values (Index) := Parse_Sample (Value, Index);
                  end;
               else
                  raise Baseline_Format_Error with
                    "baseline contains unknown field " & Key;
               end if;
            end;
         end;
      end loop;

      if Stored_Hash /= Hash then
         raise Baseline_Format_Error with "baseline checksum mismatch";
      end if;

      declare
         End_Line : constant String := Required_Line ("commit footer");
      begin
         if End_Line /= "end=" & Footer then
            if Ada.Strings.Fixed.Index (End_Line, "checksum=") = 1 then
               raise Baseline_Format_Error with
                 "baseline contains duplicate checksum field";
            end if;
            raise Baseline_Format_Error with
              "baseline commit footer is malformed";
         end if;
      end;
      if not Ada.Text_IO.End_Of_File (File) then
         raise Baseline_Format_Error with
           "baseline contains unexpected trailing data";
      end if;
      if not Seen_Schema then
         raise Baseline_Format_Error with "baseline is missing schema_version";
      elsif not Seen_Name then
         raise Baseline_Format_Error with "baseline is missing benchmark_name";
      elsif not Seen_Fingerprint then
         raise Baseline_Format_Error with "baseline is missing fingerprint";
      elsif not Seen_Backend then
         raise Baseline_Format_Error with "baseline is missing clock_backend";
      elsif not Seen_Unit then
         raise Baseline_Format_Error with "baseline is missing sample_unit";
      elsif not Seen_Design then
         raise Baseline_Format_Error with
           "baseline is missing comparison_design";
      elsif not Seen_Method then
         raise Baseline_Format_Error with "baseline is missing bootstrap_method";
      elsif not Seen_Count then
         raise Baseline_Format_Error with "baseline is missing sample_count";
      end if;
      for Index in Sample_Index loop
         if Index <= Sample_Index (Result.Sample_Total) then
            if not Samples_Seen (Index) then
               raise Baseline_Format_Error with
                 "baseline is missing sample" & Sample_Index'Image (Index);
            end if;
         elsif Samples_Seen (Index) then
            raise Baseline_Format_Error with
              "baseline contains sample beyond sample_count at"
              & Sample_Index'Image (Index);
         end if;
      end loop;
      Ada.Text_IO.Close (File);
      return Result;
   exception
      when Ada.IO_Exceptions.Name_Error =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
      when Baseline_Format_Error =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
      when Error : Constraint_Error =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise Baseline_Format_Error with
           "malformed benchmark baseline: "
           & Ada.Exceptions.Exception_Message (Error);
      when Ada.IO_Exceptions.Use_Error | Ada.IO_Exceptions.Device_Error =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise Baseline_IO_Error with "cannot read baseline at " & Path;
   end Load;

   function Compare
     (Saved      : Baseline;
      Current    : Measurement;
      Fingerprint : String := "";
      Practical_Threshold_Percent : Long_Float := 1.0;
      Random_Seed : Long_Long_Integer := 1) return Regression
   is
      Result : Regression;
      Current_Count : constant Positive := Positive (Samples (Current));
      Saved_Count : constant Positive := Positive (Saved.Sample_Total);
      Saved_Sum : Long_Float := 0.0;
      Current_Sum : Long_Float := 0.0;
      Bootstrap : Float_Array (1 .. Default_Bootstrap_Resamples);
      State : Interfaces.Unsigned_64 :=
        16#94D0_49BB_1331_11EB# xor Interfaces.Unsigned_64 (Random_Seed);
      Effective_Fingerprint : constant String :=
        (if Fingerprint'Length = 0
         then Flyology_Bench.Metadata.Fingerprint
         else Fingerprint);
      Saved_Block_Length : constant Positive :=
        Positive'Max
          (2, Positive (Long_Float'Ceiling
             (Math.Sqrt (Long_Float (Saved_Count)))));
      Current_Block_Length : constant Positive :=
        Positive'Max
          (2, Positive (Long_Float'Ceiling
             (Math.Sqrt (Long_Float (Current_Count)))));
   begin
      if Practical_Threshold_Percent < 0.0
        or else Practical_Threshold_Percent >= 100.0
      then
         raise Constraint_Error with
           "practical threshold must be in the range 0 .. 100 percent";
      end if;
      Result.Is_Compatible :=
        Clock_Backend (Current)
          = Saved.Backend_Id (1 .. Saved.Backend_Id_Length)
        and then Effective_Fingerprint
          = Saved.Fingerprint_Data (1 .. Saved.Fingerprint_Length);
      if not Result.Is_Compatible then
         return Result;
      end if;
      for Index in 1 .. Saved_Count loop
         Saved_Sum := Saved_Sum + Saved.Values (Sample_Index (Index));
      end loop;
      for Index in 1 .. Current_Count loop
         Current_Sum :=
           Current_Sum + Sample_Nanoseconds (Current, Sample_Index (Index));
      end loop;
      if Saved_Sum <= 0.0 or else Current_Sum <= 0.0 then
         raise Program_Error with "baseline comparison contains nonpositive time";
      end if;
      Result.Speedup_Value :=
        (Saved_Sum / Long_Float (Saved_Count))
        / (Current_Sum / Long_Float (Current_Count));

      for Resample in Bootstrap'Range loop
         Saved_Sum := 0.0;
         Current_Sum := 0.0;
         declare
            Drawn : Natural := 0;
         begin
            while Drawn < Saved_Count loop
               declare
                  Start : constant Positive :=
                    Natural
                      (Next_Random (State)
                       mod Interfaces.Unsigned_64 (Saved_Count)) + 1;
               begin
                  for Offset in 0 .. Saved_Block_Length - 1 loop
                     exit when Drawn = Saved_Count;
                     Saved_Sum := Saved_Sum
                       + Saved.Values
                           (Sample_Index
                              (((Start - 1 + Offset) mod Saved_Count) + 1));
                     Drawn := Drawn + 1;
                  end loop;
               end;
            end loop;
         end;
         declare
            Drawn : Natural := 0;
         begin
            while Drawn < Current_Count loop
               declare
                  Start : constant Positive :=
                    Natural
                      (Next_Random (State)
                       mod Interfaces.Unsigned_64 (Current_Count)) + 1;
               begin
                  for Offset in 0 .. Current_Block_Length - 1 loop
                     exit when Drawn = Current_Count;
                     Current_Sum := Current_Sum
                       + Sample_Nanoseconds
                           (Current,
                            Sample_Index
                              (((Start - 1 + Offset) mod Current_Count) + 1));
                     Drawn := Drawn + 1;
                  end loop;
               end;
            end loop;
         end;
         Bootstrap (Resample) :=
           (Saved_Sum / Long_Float (Saved_Count))
           / (Current_Sum / Long_Float (Current_Count));
      end loop;
      Sort (Bootstrap);
      declare
         Tail : constant Long_Float :=
           (100.0 - Default_Confidence_Level_Percent) / 200.0;
      begin
         Result.CI_Low := Percentile (Bootstrap, Tail);
         Result.CI_High := Percentile (Bootstrap, 1.0 - Tail);
      end;
      declare
         Change_Low : constant Long_Float :=
           100.0 * (1.0 / Result.CI_High - 1.0);
         Change_High : constant Long_Float :=
           100.0 * (1.0 / Result.CI_Low - 1.0);
      begin
         if Change_High < -Practical_Threshold_Percent then
            Result.Verdict_Value := Contender_Faster;
         elsif Change_Low > Practical_Threshold_Percent then
            Result.Verdict_Value := Reference_Faster;
         elsif Change_Low >= -Practical_Threshold_Percent
           and then Change_High <= Practical_Threshold_Percent
         then
            Result.Verdict_Value := Practically_Equivalent;
         end if;
      end;
      return Result;
   end Compare;

   function Name (Saved : Baseline) return String is
     (Saved.Name_Data (1 .. Saved.Name_Length));

   function Fingerprint (Saved : Baseline) return String is
     (Saved.Fingerprint_Data (1 .. Saved.Fingerprint_Length));

   function Clock_Backend (Saved : Baseline) return String is
     (Saved.Backend_Id (1 .. Saved.Backend_Id_Length));

   function Compatible (Result : Regression) return Boolean is
     (Result.Is_Compatible);

   function Speedup (Result : Regression) return Long_Float is
     (Result.Speedup_Value);

   function Speedup_Confidence_Low (Result : Regression) return Long_Float is
     (Result.CI_Low);

   function Speedup_Confidence_High (Result : Regression) return Long_Float is
     (Result.CI_High);

   function Time_Change_Percent (Result : Regression) return Long_Float is
     (100.0 * (1.0 / Result.Speedup_Value - 1.0));

   function Time_Change_Confidence_Low
     (Result : Regression) return Long_Float is
     (100.0 * (1.0 / Result.CI_High - 1.0));

   function Time_Change_Confidence_High
     (Result : Regression) return Long_Float is
     (100.0 * (1.0 / Result.CI_Low - 1.0));

   function Verdict (Result : Regression) return Comparison_Verdict is
     (Result.Verdict_Value);

   function Evaluate_Gate
     (Path         : String;
      Current_Name : String;
      Current      : Measurement;
      Fingerprint  : String := "";
      Policy       : Gate_Policy := Permissive_Gate_Policy;
      Random_Seed  : Long_Long_Integer := 1) return Gate_Result
   is
      Result : Gate_Result;
      Effective_Fingerprint : constant String :=
        (if Fingerprint'Length = 0
         then Flyology_Bench.Metadata.Fingerprint
         else Fingerprint);

      procedure Set_Result
        (Value    : Gate_Status;
         Rejects  : Boolean;
         Message  : String) is
      begin
         Result.Status_Value := Value;
         Result.Rejected_Value := Rejects;
         Result.Reason_Data := Unbounded.To_Unbounded_String (Message);
      end Set_Result;

      procedure Set_Incompatible
        (Issue   : Compatibility_Issue;
         Message : String) is
      begin
         Result.Issue_Value := Issue;
         Set_Result
           (Incompatible_Baseline,
            Policy.On_Incompatible = Reject,
            Message);
      end Set_Incompatible;
   begin
      Validate_Text (Path, "baseline path", Allow_Empty => False);
      Validate_Text
        (Current_Name, "current benchmark name", Allow_Empty => False);
      Validate_Text
        (Effective_Fingerprint, "current fingerprint", Allow_Empty => False);
      Result.Path_Data := Unbounded.To_Unbounded_String (Path);
      Result.Current_Name_Data := Unbounded.To_Unbounded_String (Current_Name);
      Result.Threshold_Value := Policy.Practical_Threshold_Percent;
      Result.Bootstrap_Method_Value := Circular_Block_Mean_Ratio;
      Result.Confidence_Level_Value := Default_Confidence_Level_Percent;
      Result.Bootstrap_Resample_Total := Default_Bootstrap_Resamples;
      Result.Random_Seed_Value := Random_Seed;

      if not Ada.Directories.Exists (Path) then
         Set_Result
           (Missing_Baseline,
            Policy.On_Missing = Reject,
            "baseline artifact does not exist at " & Path);
         return Result;
      end if;

      declare
         Saved : Baseline;
      begin
         Saved := Load (Path);
         Result.Baseline_Name_Data :=
           Unbounded.To_Unbounded_String (Name (Saved));
         if Name (Saved) /= Current_Name then
            Set_Incompatible
              (Benchmark_Identity_Mismatch,
               "baseline benchmark identity does not match current identity");
            return Result;
         elsif Flyology_Bench.Baselines.Fingerprint (Saved)
           /= Effective_Fingerprint
         then
            Set_Incompatible
              (Environment_Fingerprint_Mismatch,
               "baseline environment fingerprint does not match current run");
            return Result;
         elsif Clock_Backend (Saved) /= Clock_Backend (Current) then
            Set_Incompatible
              (Clock_Backend_Mismatch,
               "baseline clock backend does not match current run");
            return Result;
         end if;

         Result.Compatible_Value := True;
         Result.Statistics_Ready := True;
         Result.Regression_Data :=
           Compare
             (Saved,
              Current,
              Fingerprint => Effective_Fingerprint,
              Practical_Threshold_Percent =>
                Policy.Practical_Threshold_Percent,
              Random_Seed => Random_Seed);
         case Verdict (Result.Regression_Data) is
            when Contender_Faster =>
               Set_Result
                 (Improvement, False,
                  "confidence interval establishes an improvement beyond the "
                  & "practical threshold");
            when Practically_Equivalent =>
               Set_Result
                 (Practical_Equivalence, False,
                  "confidence interval is within the practical threshold");
            when Inconclusive =>
               Set_Result
                 (Inconclusive,
                  Policy.On_Inconclusive = Reject,
                  "confidence interval establishes neither a practical result "
                  & "nor a regression");
            when Reference_Faster =>
               Set_Result
                 (Regressed, True,
                  "confidence interval establishes a regression beyond the "
                  & "practical threshold");
         end case;
         return Result;
      exception
         when Ada.IO_Exceptions.Name_Error =>
            Set_Result
              (Missing_Baseline,
               Policy.On_Missing = Reject,
               "baseline artifact disappeared before it could be loaded at "
               & Path);
            return Result;
         when Error : Baseline_Format_Error =>
            Set_Result
              (Invalid_Baseline,
               Policy.On_Invalid = Reject,
               Ada.Exceptions.Exception_Message (Error));
            return Result;
         when Error : Baseline_IO_Error =>
            Set_Result
              (Baseline_Error,
               Policy.On_Invalid = Reject,
               Ada.Exceptions.Exception_Message (Error));
            return Result;
      end;
   end Evaluate_Gate;

   procedure Require (Result : Gate_Result) is
   begin
      if Rejected (Result) then
         raise Regression_Gate_Failure with Reason (Result);
      end if;
   end Require;

   function Status (Result : Gate_Result) return Gate_Status is
     (Result.Status_Value);

   function Status_Name (Result : Gate_Result) return String is
   begin
      case Result.Status_Value is
         when Improvement            => return "improvement";
         when Practical_Equivalence  => return "practical_equivalence";
         when Inconclusive           => return "inconclusive";
         when Regressed              => return "regression";
         when Missing_Baseline       => return "missing_baseline";
         when Incompatible_Baseline  => return "incompatible_baseline";
         when Invalid_Baseline       => return "invalid_baseline";
         when Baseline_Error         => return "baseline_error";
      end case;
   end Status_Name;

   function Rejected (Result : Gate_Result) return Boolean is
     (Result.Rejected_Value);

   function Compatible (Result : Gate_Result) return Boolean is
     (Result.Compatible_Value);

   function Compatibility (Result : Gate_Result) return Compatibility_Issue is
     (Result.Issue_Value);

   function Has_Statistics (Result : Gate_Result) return Boolean is
     (Result.Statistics_Ready);

   function Baseline_Name (Result : Gate_Result) return String is
     (Unbounded.To_String (Result.Baseline_Name_Data));

   function Current_Name (Result : Gate_Result) return String is
     (Unbounded.To_String (Result.Current_Name_Data));

   function Baseline_Path (Result : Gate_Result) return String is
     (Unbounded.To_String (Result.Path_Data));

   function Reason (Result : Gate_Result) return String is
     (Unbounded.To_String (Result.Reason_Data));

   function Practical_Threshold_Percent
     (Result : Gate_Result) return Long_Float is
     (Result.Threshold_Value);

   function Bootstrap_Method (Result : Gate_Result) return String is
   begin
      case Result.Bootstrap_Method_Value is
         when Circular_Block_Mean_Ratio =>
            return Bootstrap_Method_Text;
      end case;
   end Bootstrap_Method;

   function Confidence_Level_Percent
     (Result : Gate_Result) return Long_Float is
     (Result.Confidence_Level_Value);

   function Bootstrap_Resamples (Result : Gate_Result) return Positive is
     (Result.Bootstrap_Resample_Total);

   function Random_Seed (Result : Gate_Result) return Long_Long_Integer is
     (Result.Random_Seed_Value);

   procedure Require_Statistics (Result : Gate_Result) is
   begin
      if not Result.Statistics_Ready then
         raise Program_Error with "baseline gate has no comparison statistics";
      end if;
   end Require_Statistics;

   function Speedup (Result : Gate_Result) return Long_Float is
   begin
      Require_Statistics (Result);
      return Speedup (Result.Regression_Data);
   end Speedup;

   function Speedup_Confidence_Low (Result : Gate_Result) return Long_Float is
   begin
      Require_Statistics (Result);
      return Speedup_Confidence_Low (Result.Regression_Data);
   end Speedup_Confidence_Low;

   function Speedup_Confidence_High (Result : Gate_Result) return Long_Float is
   begin
      Require_Statistics (Result);
      return Speedup_Confidence_High (Result.Regression_Data);
   end Speedup_Confidence_High;

   function Time_Change_Percent (Result : Gate_Result) return Long_Float is
   begin
      Require_Statistics (Result);
      return Time_Change_Percent (Result.Regression_Data);
   end Time_Change_Percent;

   function Time_Change_Confidence_Low
     (Result : Gate_Result) return Long_Float is
   begin
      Require_Statistics (Result);
      return Time_Change_Confidence_Low (Result.Regression_Data);
   end Time_Change_Confidence_Low;

   function Time_Change_Confidence_High
     (Result : Gate_Result) return Long_Float is
   begin
      Require_Statistics (Result);
      return Time_Change_Confidence_High (Result.Regression_Data);
   end Time_Change_Confidence_High;
end Flyology_Bench.Baselines;
