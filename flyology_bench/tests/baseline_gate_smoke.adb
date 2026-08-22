--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology_Bench;
with Flyology_Bench.Baselines;
with Flyology_Bench.Baselines.Testing;
with Flyology_Bench.Reporters;
with Interfaces;

procedure Baseline_Gate_Smoke is
   package Baselines renames Flyology_Bench.Baselines;
   package Baseline_Testing renames Flyology_Bench.Baselines.Testing;
   package Unbounded renames Ada.Strings.Unbounded;
   use type Baselines.Gate_Status;
   use type Baselines.Compatibility_Issue;
   use type Ada.Directories.File_Kind;
   use type Flyology_Bench.Comparison_Verdict;
   use type Interfaces.Unsigned_64;

   Root : constant String := ".flyology_bench_gate_test";
   Baseline_Path : constant String := Root & ".baseline";
   Legacy_Path : constant String := Root & ".v1.baseline";
   Slow_Path : constant String := Root & ".slow.baseline";
   Synthetic_Path : constant String := Root & ".synthetic.baseline";
   Clock_Path : constant String := Root & ".clock.baseline";
   Extreme_Path : constant String := Root & ".extreme.baseline";
   Output_Path : constant String := Root & ".output";
   Missing_Path : constant String := Root & ".missing";
   Failed_Target : constant String := Root & ".target";

   Value : Interfaces.Unsigned_64 := 1 with Volatile;

   procedure Fast_Work is
   begin
      Value := Value * 6_364_136_223_846_793_005
        + 1_442_695_040_888_963_407;
   end Fast_Work;

   procedure Slow_Work is
   begin
      Fast_Work;
      delay 0.001;
   end Slow_Work;

   procedure Measure_Fast is new Flyology_Bench.Measure (Fast_Work);
   procedure Measure_Slow is new Flyology_Bench.Measure (Slow_Work);

   Config : constant Flyology_Bench.Configuration :=
     (Flyology_Bench.Default_Configuration with delta
        Warmup_Time             => 0.005,
        Measurement_Time        => 0.030,
        Maximum_Sampling_Time   => 0.100,
        Samples                 => 20,
        Minimum_Sample_Time     => 0.000_100,
        Metrics                 => Flyology_Bench.Time_Metrics,
        Random_Seed             => 73);
   Fast : Flyology_Bench.Measurement;
   Slow : Flyology_Bench.Measurement;
   Synthetic : constant Flyology_Bench.Measurement :=
     Baseline_Testing.Measurement_From
       ([100.0, 101.0, 99.0, 102.0, 98.0,
         100.5, 99.5, 101.5, 98.5, 100.0,
         102.0, 98.0, 101.0, 99.0, 100.0,
         100.5, 99.5, 101.5, 98.5, 100.0]);

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Delete_If_Present (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         if Ada.Directories.Kind (Path) = Ada.Directories.Directory then
            Ada.Directories.Delete_Directory (Path);
         else
            Ada.Directories.Delete_File (Path);
         end if;
      end if;
   end Delete_If_Present;

   function Read_All (Path : String) return String is
      File : Ada.Text_IO.File_Type;
      Result : Unbounded.Unbounded_String;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Unbounded.Append (Result, Ada.Text_IO.Get_Line (File) & ASCII.LF);
      end loop;
      Ada.Text_IO.Close (File);
      return Unbounded.To_String (Result);
   end Read_All;

   procedure Write_Text (Path, Text : String) is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put (File, Text);
      Ada.Text_IO.Close (File);
   end Write_Text;

   procedure Write_Legacy_Baseline
     (Path        : String;
      Name        : String;
      Result      : Flyology_Bench.Measurement;
      Fingerprint : String)
   is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put_Line (File, "flyology_bench baseline v1");
      Ada.Text_IO.Put_Line (File, Name);
      Ada.Text_IO.Put_Line (File, Fingerprint);
      Ada.Text_IO.Put_Line (File, Flyology_Bench.Clock_Backend (Result));
      Ada.Text_IO.Put_Line
        (File,
         Flyology_Bench.Sample_Count'Image (Flyology_Bench.Samples (Result)));
      for Index in Flyology_Bench.Sample_Index range
        1 .. Flyology_Bench.Sample_Index (Flyology_Bench.Samples (Result))
      loop
         Ada.Text_IO.Put_Line
           (File, Long_Float'Image
              (Flyology_Bench.Sample_Nanoseconds (Result, Index)));
      end loop;
      Ada.Text_IO.Close (File);
   end Write_Legacy_Baseline;

   FNV_Offset : constant Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   FNV_Prime  : constant Interfaces.Unsigned_64 := 16#0000_0100_0000_01B3#;

   procedure Hash_Line
     (State : in out Interfaces.Unsigned_64;
      Line  : String) is
   begin
      for Item of Line loop
         State :=
           (State xor Interfaces.Unsigned_64
              (Standard.Character'Pos (Item))) * FNV_Prime;
      end loop;
      State := (State xor Interfaces.Unsigned_64 (10)) * FNV_Prime;
   end Hash_Line;

   function Hex_Image (Value : Interfaces.Unsigned_64) return String is
      Hex : constant String := "0123456789abcdef";
      Work : Interfaces.Unsigned_64 := Value;
      Result : String (1 .. 16);
   begin
      for Position in reverse Result'Range loop
         Result (Position) := Hex (Natural (Work and 16#F#) + Hex'First);
         Work := Interfaces.Shift_Right (Work, 4);
      end loop;
      return Result;
   end Hex_Image;

   procedure Rewrite_Clock (Source, Destination, Backend : String) is
      Input : Ada.Text_IO.File_Type;
      Output : Unbounded.Unbounded_String;
      Hash : Interfaces.Unsigned_64 := FNV_Offset;
   begin
      Ada.Text_IO.Open (Input, Ada.Text_IO.In_File, Source);
      loop
         declare
            Original : constant String := Ada.Text_IO.Get_Line (Input);
         begin
            exit when Ada.Strings.Fixed.Index (Original, "checksum=") = 1;
            declare
               Line : constant String :=
                 (if Ada.Strings.Fixed.Index (Original, "clock_backend=") = 1
                  then "clock_backend=" & Backend
                  else Original);
            begin
               Unbounded.Append (Output, Line & ASCII.LF);
               Hash_Line (Hash, Line);
            end;
         end;
      end loop;
      Ada.Text_IO.Close (Input);
      Unbounded.Append (Output, "checksum=" & Hex_Image (Hash) & ASCII.LF);
      Unbounded.Append
        (Output, "end=flyology_bench baseline v2" & ASCII.LF);
      Write_Text (Destination, Unbounded.To_String (Output));
   end Rewrite_Clock;

   procedure Rewrite_Samples
     (Source, Destination, Sample_Image : String)
   is
      Input : Ada.Text_IO.File_Type;
      Output : Unbounded.Unbounded_String;
      Hash : Interfaces.Unsigned_64 := FNV_Offset;
   begin
      Ada.Text_IO.Open (Input, Ada.Text_IO.In_File, Source);
      loop
         declare
            Original : constant String := Ada.Text_IO.Get_Line (Input);
         begin
            exit when Ada.Strings.Fixed.Index (Original, "checksum=") = 1;
            declare
               Separator : constant Natural :=
                 Ada.Strings.Fixed.Index (Original, "=");
               Line : constant String :=
                 (if Ada.Strings.Fixed.Index (Original, "sample.") = 1
                    and then Separator > 0
                  then Original (Original'First .. Separator) & Sample_Image
                  else Original);
            begin
               Unbounded.Append (Output, Line & ASCII.LF);
               Hash_Line (Hash, Line);
            end;
         end;
      end loop;
      Ada.Text_IO.Close (Input);
      Unbounded.Append (Output, "checksum=" & Hex_Image (Hash) & ASCII.LF);
      Unbounded.Append
        (Output, "end=flyology_bench baseline v2" & ASCII.LF);
      Write_Text (Destination, Unbounded.To_String (Output));
   end Rewrite_Samples;

   procedure Expect_Format_Error
     (Path     : String;
      Contents : String;
      Fragment : String)
   is
      Raised : Boolean := False;
   begin
      Write_Text (Path, Contents);
      begin
         declare
            Ignored : constant Baselines.Baseline := Baselines.Load (Path);
         begin
            null;
         end;
      exception
         when Error : Baselines.Baseline_Format_Error =>
            Raised := True;
            Check
              (Ada.Strings.Fixed.Index
                 (Ada.Exceptions.Exception_Message (Error), Fragment) > 0,
               "format diagnostic did not contain '" & Fragment & "'");
      end;
      Check (Raised, "malformed baseline was accepted: " & Fragment);
      Ada.Directories.Delete_File (Path);
   end Expect_Format_Error;

begin
   Delete_If_Present (Baseline_Path);
   Delete_If_Present (Legacy_Path);
   Delete_If_Present (Slow_Path);
   Delete_If_Present (Synthetic_Path);
   Delete_If_Present (Clock_Path);
   Delete_If_Present (Extreme_Path);
   Delete_If_Present (Output_Path);
   Delete_If_Present (Missing_Path);
   Delete_If_Present (Failed_Target);

   Measure_Fast (Config, Fast);
   Measure_Slow (Config, Slow);

   Baselines.Save
     (Baseline_Path, "gate,""case", Fast, "host=exact;switches=-O2");
   declare
      Saved : constant Baselines.Baseline := Baselines.Load (Baseline_Path);
   begin
      Check
        (Baselines.Name (Saved) = "gate,""case",
         "baseline identity did not round trip exactly");
      Check
        (Baselines.Fingerprint (Saved) = "host=exact;switches=-O2",
         "baseline fingerprint did not round trip exactly");
      Check
        (Baselines.Clock_Backend (Saved) = Flyology_Bench.Clock_Backend (Fast),
         "baseline clock backend did not round trip exactly");
   end;

   Write_Legacy_Baseline
     (Legacy_Path, "gate,""case", Fast, "host=exact;switches=-O2");
   declare
      Before : constant String := Read_All (Legacy_Path);
      Saved : constant Baselines.Baseline := Baselines.Load (Legacy_Path);
      Regression : constant Baselines.Regression :=
        Baselines.Compare
          (Saved, Fast,
           Fingerprint => "host=exact;switches=-O2",
           Random_Seed => 99);
      Gate : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Legacy_Path, "gate,""case", Fast,
           Fingerprint => "host=exact;switches=-O2",
           Policy =>
             (Baselines.Permissive_Gate_Policy with delta
                Practical_Threshold_Percent => 20.0),
           Random_Seed => 99);
   begin
      Check
        (Baselines.Name (Saved) = "gate,""case"
         and then Baselines.Fingerprint (Saved) = "host=exact;switches=-O2"
         and then Baselines.Clock_Backend (Saved)
           = Flyology_Bench.Clock_Backend (Fast),
         "legacy baseline identity did not round trip exactly");
      Check
        (Baselines.Compatible (Regression)
         and then abs (Baselines.Speedup (Regression) - 1.0) < 1.0E-12,
         "legacy baseline raw samples did not remain comparable");
      Check
        (Baselines.Compatible (Gate)
         and then Baselines.Has_Statistics (Gate)
         and then not Baselines.Rejected (Gate),
         "legacy baseline did not pass through the gate workflow");
      Check
        (Read_All (Legacy_Path) = Before,
         "checking a legacy baseline upgraded it implicitly");
   end;

   declare
      Configured : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Baseline_Path, "gate,""case", Fast,
           Fingerprint => "host=exact;switches=-O2",
           Policy =>
             (Baselines.Permissive_Gate_Policy with delta
                Practical_Threshold_Percent => 20.0),
           Random_Seed => 100,
           Confidence_Level_Percent => 80.0,
           Bootstrap_Resamples => 100);
   begin
      Check
        (Baselines.Confidence_Level_Percent (Configured) = 80.0
         and then Baselines.Bootstrap_Resamples (Configured) = 100,
         "gate did not retain its configured statistical policy");
   end;

   declare
      Before : constant String := Read_All (Baseline_Path);
      Regressed : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Baseline_Path, "gate,""case", Slow,
           Fingerprint => "host=exact;switches=-O2",
           Policy =>
             (Baselines.Fail_Closed_Gate_Policy with delta
                Practical_Threshold_Percent => 5.0),
           Random_Seed => 101);
   begin
      Check
        (Baselines.Status (Regressed) = Baselines.Regressed
         and then Baselines.Rejected (Regressed),
         "established regression did not reject");
      begin
         Baselines.Require (Regressed);
         raise Program_Error with "Require accepted a rejected result";
      exception
         when Baselines.Regression_Gate_Failure =>
            null;
      end;
      Check
        (Read_All (Baseline_Path) = Before,
         "check mode modified a rejected baseline");
   end;

   Baselines.Save
     (Slow_Path, "gate,""case", Slow, "host=exact;switches=-O2");
   Baselines.Save
     (Synthetic_Path, "gate,""case", Synthetic,
      "host=exact;switches=-O2");
   declare
      Improved : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Slow_Path, "gate,""case", Fast,
           Fingerprint => "host=exact;switches=-O2",
           Policy => Baselines.Fail_Closed_Gate_Policy,
           Random_Seed => 102);
      Equivalent : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Synthetic_Path, "gate,""case", Synthetic,
           Fingerprint => "host=exact;switches=-O2",
           Policy => Baselines.Fail_Closed_Gate_Policy,
           Random_Seed => 103);
   begin
      Check
        (Baselines.Status (Improved) = Baselines.Improvement
         and then not Baselines.Rejected (Improved),
         "established improvement did not pass");
      Check
        (Baselines.Status (Equivalent) = Baselines.Practical_Equivalence
         and then not Baselines.Rejected (Equivalent),
         "practical equivalence did not pass");
   end;

   declare
      Saved : constant Baselines.Baseline := Baselines.Load (Synthetic_Path);
      Zero : constant Baselines.Regression :=
        Baselines.Compare
          (Saved, Synthetic,
           Fingerprint => "host=exact;switches=-O2",
           Practical_Threshold_Percent => 0.0,
           Random_Seed => 105);
      Change_Low : constant Long_Float :=
        Baselines.Time_Change_Confidence_Low (Zero);
      Change_High : constant Long_Float :=
        Baselines.Time_Change_Confidence_High (Zero);
      Boundary : constant Long_Float :=
        Long_Float'Max (abs Change_Low, abs Change_High);
      At_Boundary : constant Baselines.Regression :=
        Baselines.Compare
          (Saved, Synthetic,
           Fingerprint => "host=exact;switches=-O2",
           Practical_Threshold_Percent => Boundary,
           Random_Seed => 105);
      Below_Boundary : constant Baselines.Regression :=
        Baselines.Compare
          (Saved, Synthetic,
           Fingerprint => "host=exact;switches=-O2",
           Practical_Threshold_Percent => Boundary * 0.999,
           Random_Seed => 105);
   begin
      Check
        (Boundary > 0.0
         and then Baselines.Verdict (At_Boundary)
           = Flyology_Bench.Practically_Equivalent,
         "threshold boundary did not include the full confidence interval: "
         & Long_Float'Image (Change_Low) & " .."
         & Long_Float'Image (Change_High) & " threshold"
         & Long_Float'Image (Boundary) & " verdict "
         & Flyology_Bench.Comparison_Verdict'Image
             (Baselines.Verdict (At_Boundary)));
      Check
        (Baselines.Verdict (Below_Boundary) = Flyology_Bench.Inconclusive,
         "threshold below the full confidence interval was not inconclusive");
   end;

   declare
      Permissive : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Missing_Path, "missing", Fast,
           Policy => Baselines.Permissive_Gate_Policy);
      Closed : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Missing_Path, "missing", Fast,
           Policy => Baselines.Fail_Closed_Gate_Policy);
      Inconclusive : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Synthetic_Path, "gate,""case", Synthetic,
           Fingerprint => "host=exact;switches=-O2",
           Policy =>
             (Baselines.Fail_Closed_Gate_Policy with delta
                Practical_Threshold_Percent => 0.0),
           Random_Seed => 105);
   begin
      Check
        (Baselines.Status (Permissive) = Baselines.Missing_Baseline
         and then not Baselines.Rejected (Permissive),
         "permissive missing-baseline policy rejected");
      Check
        (Baselines.Status (Closed) = Baselines.Missing_Baseline
         and then Baselines.Rejected (Closed),
         "fail-closed missing-baseline policy passed");
      Check
        (Baselines.Status (Inconclusive) = Baselines.Inconclusive
         and then Baselines.Rejected (Inconclusive),
         "inconclusive result was not distinct or did not follow policy");
   end;

   declare
      Fingerprint_Mismatch : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Baseline_Path, "gate,""case", Fast,
           Fingerprint => "other-host",
           Policy => Baselines.Fail_Closed_Gate_Policy);
      Identity_Mismatch : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Baseline_Path, "Gate,""case", Fast,
           Fingerprint => "host=exact;switches=-O2",
           Policy => Baselines.Fail_Closed_Gate_Policy);
   begin
      Check
        (Baselines.Status (Fingerprint_Mismatch)
           = Baselines.Incompatible_Baseline
         and then Baselines.Compatibility (Fingerprint_Mismatch)
           = Baselines.Environment_Fingerprint_Mismatch
         and then Baselines.Rejected (Fingerprint_Mismatch),
         "fingerprint mismatch was not rejected distinctly");
      Check
        (Baselines.Status (Identity_Mismatch)
           = Baselines.Incompatible_Baseline
         and then Baselines.Compatibility (Identity_Mismatch)
           = Baselines.Benchmark_Identity_Mismatch,
         "benchmark identity matching was not exact");
   end;

   Rewrite_Clock (Baseline_Path, Clock_Path, "other_clock");
   declare
      Clock_Mismatch : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Clock_Path, "gate,""case", Fast,
           Fingerprint => "host=exact;switches=-O2",
           Policy => Baselines.Fail_Closed_Gate_Policy);
   begin
      Check
        (Baselines.Status (Clock_Mismatch) = Baselines.Incompatible_Baseline
         and then Baselines.Compatibility (Clock_Mismatch)
           = Baselines.Clock_Backend_Mismatch,
         "clock backend mismatch was not rejected distinctly");
   end;

   Expect_Format_Error
     (Output_Path,
      "flyology_bench baseline v1" & ASCII.LF
      & "legacy-name" & ASCII.LF,
      "legacy fingerprint");
   Expect_Format_Error
     (Output_Path,
      "flyology_bench baseline" & ASCII.LF
      & "schema_version=2" & ASCII.LF,
      "truncated");
   Expect_Format_Error
     (Output_Path,
      "flyology_bench baseline" & ASCII.LF
      & "schema_version=99" & ASCII.LF,
      "schema version 99");
   Expect_Format_Error
     (Output_Path,
      "flyology_bench baseline" & ASCII.LF
      & "schema_version=2" & ASCII.LF
      & "schema_version=2" & ASCII.LF,
      "duplicate schema_version");
   Expect_Format_Error
     (Output_Path,
      "flyology_bench baseline" & ASCII.LF
      & "sample_count=1001" & ASCII.LF,
      "out of range");

   Rewrite_Samples
     (Baseline_Path, Extreme_Path, Long_Float'Image (Long_Float'Last));
   Expect_Format_Error
     (Output_Path,
      Read_All (Extreme_Path),
      "supported nanosecond range");

   declare
      Invalid_Current : Flyology_Bench.Measurement;
   begin
      Rewrite_Clock
        (Baseline_Path,
         Clock_Path,
         Flyology_Bench.Clock_Backend (Invalid_Current));
      declare
         Saved : constant Baselines.Baseline := Baselines.Load (Clock_Path);
         Raised : Boolean := False;
      begin
         begin
            declare
               Ignored : constant Baselines.Regression :=
                 Baselines.Compare
                   (Saved,
                    Invalid_Current,
                    Fingerprint => "host=exact;switches=-O2");
            begin
               null;
            end;
         exception
            when Baselines.Baseline_Comparison_Error =>
               Raised := True;
         end;
         Check
           (Raised,
            "invalid current samples did not raise the named comparison error");
      end;
      declare
         Gate : constant Baselines.Gate_Result :=
           Baselines.Evaluate_Gate
             (Clock_Path,
              "gate,""case",
              Invalid_Current,
              Fingerprint => "host=exact;switches=-O2",
              Policy => Baselines.Fail_Closed_Gate_Policy);
      begin
         Check
           (Baselines.Status (Gate) = Baselines.Baseline_Error
            and then Baselines.Compatible (Gate)
            and then not Baselines.Has_Statistics (Gate)
            and then Baselines.Rejected (Gate)
            and then Ada.Strings.Fixed.Index
              (Baselines.Reason (Gate), "current measurement") > 0,
            "invalid current samples did not produce an actionable gate error");
      end;
   end;

   declare
      Corrupt : String := Read_All (Baseline_Path);
      Position : constant Natural := Ada.Strings.Fixed.Index
        (Corrupt, "benchmark_name=gate,""case");
   begin
      Corrupt (Position + 15) := 'x';
      Write_Text (Output_Path, Corrupt);
      declare
         Permissive : constant Baselines.Gate_Result :=
           Baselines.Evaluate_Gate
             (Output_Path, "gate,""case", Fast,
              Fingerprint => "host=exact;switches=-O2",
              Policy => Baselines.Permissive_Gate_Policy);
         Closed : constant Baselines.Gate_Result :=
           Baselines.Evaluate_Gate
             (Output_Path, "gate,""case", Fast,
              Fingerprint => "host=exact;switches=-O2",
              Policy => Baselines.Fail_Closed_Gate_Policy);
      begin
         Check
           (Baselines.Status (Permissive) = Baselines.Invalid_Baseline
            and then not Baselines.Rejected (Permissive),
            "permissive corrupt-baseline policy rejected");
         Check
           (Baselines.Status (Closed) = Baselines.Invalid_Baseline
            and then Baselines.Rejected (Closed),
            "fail-closed corrupt-baseline policy passed");
      end;
      Expect_Format_Error (Output_Path, Corrupt, "checksum mismatch");
   end;

   Ada.Directories.Create_Directory (Failed_Target);
   begin
      Baselines.Save
        (Failed_Target, "cannot_publish", Fast, "host=exact");
      raise Program_Error with "publication over a directory unexpectedly passed";
   exception
      when Baselines.Baseline_IO_Error =>
         null;
   end;
   Check
     (Ada.Directories.Exists (Failed_Target)
      and then Ada.Directories.Kind (Failed_Target) = Ada.Directories.Directory,
      "failed publication replaced its existing target");

   declare
      Escaped : constant Baselines.Gate_Result :=
        Baselines.Evaluate_Gate
          (Synthetic_Path, "gate,""case", Synthetic,
           Fingerprint => "host=exact;switches=-O2",
           Policy => Baselines.Permissive_Gate_Policy,
           Random_Seed => 103);
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Output_Path);
      Flyology_Bench.Reporters.Put_Gate_Console
        (Escaped, File, Style => Flyology_Bench.Reporters.Plain);
      Flyology_Bench.Reporters.Put_Gate_CSV_Header (File);
      Flyology_Bench.Reporters.Put_Gate_CSV (Escaped, File);
      Flyology_Bench.Reporters.Put_Gate_JSON (Escaped, File);
      Ada.Text_IO.Close (File);
      declare
         Text : constant String := Read_All (Output_Path);
      begin
         Check
           (Ada.Strings.Fixed.Index
              (Text, "status     | practical_equivalence (accepted)") > 0
            and then Ada.Strings.Fixed.Index (Text, "baseline_gate,2,") > 0
            and then Ada.Strings.Fixed.Index
              (Text, """status"":""practical_equivalence""") > 0
            and then Ada.Strings.Fixed.Index
              (Text, """bootstrap_method"":""circular_block_mean_ratio""") > 0
            and then Ada.Strings.Fixed.Index
              (Text, """confidence_level_percent"":95.000000000") > 0
            and then Ada.Strings.Fixed.Index
              (Text, """bootstrap_resamples"":2000") > 0
            and then Ada.Strings.Fixed.Index
              (Text, """random_seed"":103") > 0
            and then Ada.Strings.Fixed.Index
              (Text, """time_change_ci_low"":") > 0
            and then Ada.Strings.Fixed.Index
              (Text, """time_change_ci_high"":") > 0
            and then Ada.Strings.Fixed.Index (Text, """gate,""""case""") > 0,
            "gate CSV/JSON schemas or escaping are incorrect");
      end;
      Ada.Text_IO.Put_Line ("-- baseline gate machine output begin --");
      Flyology_Bench.Reporters.Put_Gate_CSV_Header;
      Flyology_Bench.Reporters.Put_Gate_CSV (Escaped);
      Flyology_Bench.Reporters.Put_Gate_JSON (Escaped);
      Ada.Text_IO.Put_Line ("-- baseline gate machine output end --");
   end;

   Delete_If_Present (Baseline_Path);
   Delete_If_Present (Legacy_Path);
   Delete_If_Present (Slow_Path);
   Delete_If_Present (Synthetic_Path);
   Delete_If_Present (Clock_Path);
   Delete_If_Present (Extreme_Path);
   Delete_If_Present (Output_Path);
   Delete_If_Present (Failed_Target);
   Ada.Text_IO.Put_Line ("flyology_bench baseline gate smoke: PASS");
exception
   when others =>
      Delete_If_Present (Baseline_Path);
      Delete_If_Present (Legacy_Path);
      Delete_If_Present (Slow_Path);
      Delete_If_Present (Synthetic_Path);
      Delete_If_Present (Clock_Path);
      Delete_If_Present (Extreme_Path);
      Delete_If_Present (Output_Path);
      Delete_If_Present (Failed_Target);
      raise;
end Baseline_Gate_Smoke;
