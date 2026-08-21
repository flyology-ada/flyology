--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Ada.Numerics.Long_Elementary_Functions;
with Flyology_Bench.Metadata;
with Interfaces;

package body Flyology_Bench.Baselines is
   package Math renames Ada.Numerics.Long_Elementary_Functions;
   use type Interfaces.Unsigned_64;

   Magic : constant String := "flyology_bench baseline v1";
   type Float_Array is array (Positive range <>) of Long_Float;

   function Lower_Tail
     (Confidence : Confidence_Percentage) return Long_Float is
     ((100.0 - Long_Float (Confidence)) / 200.0);

   procedure Reject_Newline (Value : String; Field : String) is
   begin
      for Character of Value loop
         if Character = ASCII.LF or else Character = ASCII.CR then
            raise Constraint_Error with Field & " must not contain newlines";
         end if;
      end loop;
   end Reject_Newline;

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

   procedure Save
     (Path        : String;
      Name        : String;
      Result      : Measurement;
      Fingerprint : String := "")
   is
      File : Ada.Text_IO.File_Type;
      Effective_Fingerprint : constant String :=
        (if Fingerprint'Length = 0
         then Flyology_Bench.Metadata.Fingerprint
         else Fingerprint);
   begin
      Reject_Newline (Name, "baseline name");
      Reject_Newline (Effective_Fingerprint, "baseline fingerprint");
      if Name'Length > 256 then
         raise Constraint_Error with "baseline name is too long";
      elsif Effective_Fingerprint'Length > 1_024 then
         raise Constraint_Error with "baseline fingerprint is too long";
      end if;
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put_Line (File, Magic);
      Ada.Text_IO.Put_Line (File, Name);
      Ada.Text_IO.Put_Line (File, Effective_Fingerprint);
      Ada.Text_IO.Put_Line (File, Clock_Backend (Result));
      Ada.Text_IO.Put_Line (File, Sample_Count'Image (Samples (Result)));
      for Index in Sample_Index range 1 .. Sample_Index (Samples (Result)) loop
         Ada.Text_IO.Put_Line
           (File, Long_Float'Image (Sample_Nanoseconds (Result, Index)));
      end loop;
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Save;

   function Load (Path : String) return Baseline is
      File : Ada.Text_IO.File_Type;
      Result : Baseline;

      procedure Store
        (Value  : String;
         Buffer : out String;
         Length : out Natural;
         Field  : String) is
      begin
         if Value'Length > Buffer'Length then
            raise Constraint_Error with Field & " is too long";
         end if;
         Length := Value'Length;
         Buffer := [others => ' '];
         if Length > 0 then
            Buffer (Buffer'First .. Buffer'First + Length - 1) := Value;
         end if;
      end Store;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      if Ada.Text_IO.Get_Line (File) /= Magic then
         raise Constraint_Error with "unsupported benchmark baseline format";
      end if;
      Store
        (Ada.Text_IO.Get_Line (File), Result.Name_Data, Result.Name_Length,
         "baseline name");
      Store
        (Ada.Text_IO.Get_Line (File), Result.Fingerprint_Data,
         Result.Fingerprint_Length, "baseline fingerprint");
      Store
        (Ada.Text_IO.Get_Line (File), Result.Backend_Id,
         Result.Backend_Id_Length, "clock backend");
      Result.Sample_Total := Sample_Count'Value (Ada.Text_IO.Get_Line (File));
      for Index in Sample_Index range 1 .. Sample_Index (Result.Sample_Total) loop
         Result.Values (Index) := Long_Float'Value (Ada.Text_IO.Get_Line (File));
      end loop;
      if not Ada.Text_IO.End_Of_File (File) then
         raise Constraint_Error with "baseline contains unexpected trailing data";
      end if;
      Ada.Text_IO.Close (File);
      return Result;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Load;

   function Compare
     (Saved      : Baseline;
      Current    : Measurement;
      Fingerprint : String := "";
      Practical_Threshold_Percent : Long_Float := 1.0;
      Random_Seed : Long_Long_Integer := 1;
      Confidence_Level_Percent : Confidence_Percentage := 95.0;
      Bootstrap_Resamples : Bootstrap_Resample_Count := 2_000)
      return Regression
   is
      Result : Regression;
      Current_Count : constant Positive := Positive (Samples (Current));
      Saved_Count : constant Positive := Positive (Saved.Sample_Total);
      Saved_Sum : Long_Float := 0.0;
      Current_Sum : Long_Float := 0.0;
      Bootstrap : Float_Array (1 .. Bootstrap_Resamples);
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
      Result.CI_Low :=
        Percentile (Bootstrap, Lower_Tail (Confidence_Level_Percent));
      Result.CI_High :=
        Percentile
          (Bootstrap, 1.0 - Lower_Tail (Confidence_Level_Percent));
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

   function Verdict (Result : Regression) return Comparison_Verdict is
     (Result.Verdict_Value);
end Flyology_Bench.Baselines;
