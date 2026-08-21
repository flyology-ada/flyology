--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology_Bench;
with Flyology_Bench.Reporters;
with Flyology_Bench.Suites;

procedure Suite_Smoke is
   use Ada.Strings.Unbounded;
   use type Flyology_Bench.Iteration_Count;
   use type Flyology_Bench.Metric_Set;
   use type Flyology_Bench.Progress_Handler;

   package Runner is new Flyology_Bench.Suites (Maximum_Cases => 8);
   use type Runner.Final_Status;
   use type Runner.Result_Kind;
   use type Runner.Runner_Action;
   use type Runner.Output_Style;

   Counter : Natural := 0 with Volatile;
   Calls   : Natural := 0;
   Last_Config : Flyology_Bench.Configuration :=
     Flyology_Bench.Default_Configuration;
   Reporter_Sink  : Ada.Text_IO.File_Type;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   procedure Operation is
   begin
      Counter := Counter + 1;
   end Operation;

   procedure Contender is
   begin
      Counter := Counter + 1;
      Counter := Counter + 1;
   end Contender;

   procedure Measure_Operation is new Flyology_Bench.Measure (Operation);
   procedure Compare_Operations is new Flyology_Bench.Compare
     (Reference_Operation => Operation,
      Contender_Operation => Contender);

   type Multi_Case is (Reference_Case, Contender_Case);

   procedure Multi_Batch
     (Which      : Multi_Case;
      Iterations : Flyology_Bench.Iteration_Count) is
   begin
      for Iteration in Flyology_Bench.Iteration_Count range 1 .. Iterations loop
         case Which is
            when Reference_Case => Operation;
            when Contender_Case => Contender;
         end case;
      end loop;
   end Multi_Batch;

   procedure Compare_Multi is new Flyology_Bench.Compare_Many
     (Case_Id => Multi_Case, Batch => Multi_Batch);

   procedure Run_Measurement
     (Config : Flyology_Bench.Configuration;
      Result : out Flyology_Bench.Measurement) is
   begin
      Calls := Calls + 1;
      Last_Config := Config;
      Measure_Operation (Config, Result);
   end Run_Measurement;

   procedure Run_Comparison
     (Config : Flyology_Bench.Configuration;
      Result : out Flyology_Bench.Comparison) is
   begin
      Calls := Calls + 1;
      Last_Config := Config;
      Compare_Operations (Config, Result);
   end Run_Comparison;

   procedure Run_Multi
     (Config : Flyology_Bench.Configuration;
      Result : out Flyology_Bench.Multi_Comparison) is
   begin
      Calls := Calls + 1;
      Last_Config := Config;
      Compare_Multi (Config, Result);
   end Run_Multi;

   package Multi_Registration is new Runner.Multi_Way_Registration
     (Case_Id => Multi_Case,
      Run     => Run_Multi);

   procedure Run_And_Close_Output
     (Config : Flyology_Bench.Configuration;
      Result : out Flyology_Bench.Measurement) is
   begin
      Measure_Operation (Config, Result);
      Ada.Text_IO.Close (Reporter_Sink);
   end Run_And_Close_Output;

   procedure Fail
     (Config : Flyology_Bench.Configuration;
      Result : out Flyology_Bench.Measurement)
   is
      pragma Unreferenced (Config, Result);
   begin
      Calls := Calls + 1;
      raise Program_Error with "failure, ""quoted""";
   end Fail;

   function U (Value : String) return Unbounded_String is
     (To_Unbounded_String (Value));

   function Args_1 (One : String) return Runner.Argument_List is
     ([1 => U (One)]);

   function Args_2 (One, Two : String) return Runner.Argument_List is
     ([U (One), U (Two)]);

   function Args_3 (One, Two, Three : String)
      return Runner.Argument_List is
     ([U (One), U (Two), U (Three)]);

   procedure Expect_Option_Error
     (Arguments : Runner.Argument_List;
      Label     : String) is
   begin
      declare
         Options : constant Runner.Runner_Options := Runner.Parse (Arguments);
         pragma Unreferenced (Options);
      begin
         raise Program_Error with Label & " did not reject invalid options";
      end;
   exception
      when Runner.Option_Error =>
         null;
   end Expect_Option_Error;

   function Read_All (Path : String) return String is
      File   : Ada.Text_IO.File_Type;
      Result : Unbounded_String;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Append (Result, Ada.Text_IO.Get_Line (File));
         Append (Result, ASCII.LF);
      end loop;
      Ada.Text_IO.Close (File);
      return To_String (Result);
   end Read_All;

   procedure Remove (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   end Remove;

   Base_Config : constant Flyology_Bench.Configuration :=
     (Flyology_Bench.Default_Configuration with delta
        Warmup_Time => 0.0,
        Measurement_Time => 0.002,
        Maximum_Sampling_Time => 0.050,
        Samples => 10,
        Minimum_Sample_Time => 0.000_001,
        Maximum_Iterations => 1_000,
        Metrics => Flyology_Bench.Time_Metrics,
        Random_Seed => 77);

   Target : Runner.Suite;
begin
   Runner.Register
     (Target, "alpha", Run_Measurement'Access,
      Group => "core", Tags => "fast,smoke");
   Runner.Register
     (Target, "beta", Run_Measurement'Access,
      Group => "io", Tags => "slow,smoke");
   Runner.Register_Paired
     (Target, "compare", "reference", "contender", Run_Comparison'Access,
      Group => "core", Tags => "paired,smoke");
   Runner.Register
     (Target, "failure", Fail'Access,
      Group => "core", Tags => "failure,smoke");

   Check (Runner.Length (Target) = 4, "registration count");
   Check (Runner.Full_Name (Target, 1) = "core/alpha", "first identity");
   Check (Runner.Full_Name (Target, 2) = "io/beta", "second identity");
   Check
     (Runner.Kind (Target, 3) = Runner.Paired_Comparison,
      "paired result kind");

   declare
      Duplicate_Rejected : Boolean := False;
      Invalid_Rejected   : Boolean := False;
   begin
      begin
         Runner.Register
           (Target, "alpha", Run_Measurement'Access, Group => "core");
      exception
         when Runner.Registration_Error => Duplicate_Rejected := True;
      end;
      begin
         Runner.Register
           (Target, "bad/name", Run_Measurement'Access);
      exception
         when Runner.Registration_Error => Invalid_Rejected := True;
      end;
      Check (Duplicate_Rejected, "duplicate identity accepted");
      Check (Invalid_Rejected, "invalid identity accepted");
   end;

   declare
      Exact : constant Runner.Runner_Options :=
        Runner.Parse (Args_2 ("--exact", "core/alpha"), Base_Config);
      Substring : constant Runner.Runner_Options :=
        Runner.Parse (Args_2 ("--filter", "core/"), Base_Config);
      Glob : constant Runner.Runner_Options :=
        Runner.Parse (Args_2 ("--filter", "*/b?ta"), Base_Config);
      Group_Tag : constant Runner.Runner_Options :=
        Runner.Parse
          (Args_3 ("--group=core", "--tag=smoke", "--skip=*failure"),
           Base_Config);
   begin
      Check (Runner.Is_Selected (Target, Exact, 1), "exact omitted match");
      Check (not Runner.Is_Selected (Target, Exact, 2), "exact overselected");
      Check (Runner.Is_Selected (Target, Substring, 1), "substring missed");
      Check (Runner.Is_Selected (Target, Substring, 3), "substring group missed");
      Check (Runner.Is_Selected (Target, Glob, 2), "glob missed");
      Check (Runner.Is_Selected (Target, Group_Tag, 1), "group/tag missed");
      Check (Runner.Is_Selected (Target, Group_Tag, 3), "second tag case missed");
      Check (not Runner.Is_Selected (Target, Group_Tag, 4), "skip missed");
   end;

   declare
      Options : constant Runner.Runner_Options :=
        Runner.Parse
          ([U ("--warmup=2ms"), U ("--measurement-time=4ms"),
            U ("--maximum-sampling-time=9ms"), U ("--samples=12"),
            U ("--minimum-sample-time=3us"),
            U ("--practical-threshold=2.5"), U ("--random-seed=-9"),
            U ("--output-style=json")],
           Base_Config);
      Config : constant Flyology_Bench.Configuration :=
        Runner.Effective_Configuration (Options);
   begin
      Check (Config.Warmup_Time = 0.002, "warmup override");
      Check (Config.Measurement_Time = 0.004, "measurement override");
      Check (Config.Maximum_Sampling_Time = 0.009, "sampling cap override");
      Check (Config.Samples = 12, "sample override");
      Check (Config.Minimum_Sample_Time = 0.000_003, "sample floor override");
      Check (Config.Practical_Threshold_Percent = 2.5, "threshold override");
      Check (Config.Random_Seed = -9, "seed override");
      Check (Config.Maximum_Iterations = 1_000, "unrelated field changed");
      Check (Config.Metrics = Base_Config.Metrics, "metrics changed");
      Check (Runner.Format (Options) = Runner.JSON, "output style parse");
   end;

   Expect_Option_Error (Args_1 ("--samples=9"), "sample lower bound");
   Expect_Option_Error (Args_1 ("--warmup=-1s"), "signed duration");
   Expect_Option_Error (Args_1 ("--measurement-time=0s"), "zero duration");
   Expect_Option_Error
     (Args_1 ("--measurement-time=0.1ns"), "sub-nanosecond duration");
   Expect_Option_Error (Args_1 ("--practical-threshold=100"), "threshold");
   Expect_Option_Error (Args_2 ("--output", ""), "empty output path");
   Expect_Option_Error (Args_1 ("--unknown"), "unknown option");
   Expect_Option_Error
     (Args_1 ("--record-baseline=baseline.dat"),
      "uncoordinated baseline mode");
   Expect_Option_Error
     (Args_2 ("--exact=core/alpha", "--filter=alpha"), "exact conflict");
   Expect_Option_Error
     (Args_2 ("--fail-fast", "--continue-on-error"), "error policy conflict");
   Expect_Option_Error (Args_2 ("--help", "--list"), "help conflict");

   declare
      Help : constant Runner.Runner_Options := Runner.Parse (Args_1 ("--help"));
   begin
      Check (Runner.Action (Help) = Runner.Show_Help, "help action");
   end;

   declare
      Path : constant String := "suite-list.txt";
      File : Ada.Text_IO.File_Type;
      Summary : Runner.Run_Summary;
      Options : constant Runner.Runner_Options :=
        Runner.Parse (Args_2 ("--list", "--order=name"), Base_Config);
   begin
      Remove (Path);
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Runner.List (Target, Options, Summary, File);
      Ada.Text_IO.Close (File);
      declare
         Listed : constant String := Read_All (Path);
         Alpha  : constant Natural := Ada.Strings.Fixed.Index (Listed, "core/alpha");
         Compare : constant Natural := Ada.Strings.Fixed.Index (Listed, "core/compare");
         Failure : constant Natural := Ada.Strings.Fixed.Index (Listed, "core/failure");
         Beta    : constant Natural := Ada.Strings.Fixed.Index (Listed, "io/beta");
      begin
         Check
           (Alpha > 0 and then Alpha < Compare and then Compare < Failure
            and then Failure < Beta,
            "name-ordered listing is unstable");
      end;
      Remove (Path);
   end;

   declare
      Result : Runner.Registered_Result;
   begin
      Runner.Execute_One (Target, "core/alpha", Base_Config, Result);
      Check
        (Runner.Kind (Result) = Runner.Ordinary_Measurement,
         "execute-one ordinary kind");
      Check
        (Flyology_Bench.Samples (Runner.Measurement_Value (Result)) = 10,
         "execute-one ordinary result");
      Runner.Execute_One (Target, "core/compare", Base_Config, Result);
      Check
        (Runner.Kind (Result) = Runner.Paired_Comparison,
         "execute-one paired kind");
      Check
        (Flyology_Bench.Samples
           (Flyology_Bench.Reference_Measurement
              (Runner.Comparison_Value (Result))) = 10,
         "execute-one paired result");
   end;

   declare
      Multi_Target : Runner.Suite;
      Result       : Flyology_Bench.Multi_Comparison;
      Path         : constant String := "suite-multi.jsonl";
      Progress_Path : constant String := "suite-multi.progress";
      Progress     : Ada.Text_IO.File_Type;
      Summary      : Runner.Run_Summary;
      Options      : constant Runner.Runner_Options :=
        Runner.Parse
          ([U ("--output-style=json"), U ("--output=" & Path)], Base_Config);
   begin
      Multi_Registration.Register
        (Multi_Target, "shootout", Group => "core", Tags => "multi,smoke");
      Check
        (Runner.Kind (Multi_Target, 1) = Runner.Multi_Way_Comparison,
         "multi-way registration kind");
      Runner.Execute_One_Multi
        (Multi_Target, "core/shootout", Base_Config, Result);
      Check
        (Flyology_Bench.Cases (Result) = 2,
         "execute-one multi-way result");
      Remove (Path);
      Remove (Progress_Path);
      Ada.Text_IO.Create (Progress, Ada.Text_IO.Out_File, Progress_Path);
      Runner.Execute
        (Multi_Target, "multi_suite", Options, Summary, Progress => Progress);
      Ada.Text_IO.Close (Progress);
      Check (Runner.Successful (Summary), "multi-way suite did not succeed");
      declare
         Output_Text : constant String := Read_All (Path);
      begin
         Check
           (Ada.Strings.Fixed.Index
              (Output_Text, """result_kind"":""multi_way_comparison""") /= 0
            and then Ada.Strings.Fixed.Index
              (Output_Text, """type"":""multi_comparison""") /= 0
            and then Ada.Strings.Fixed.Index
              (Output_Text, """contenders""") /= 0,
            "multi-way full JSON reporting");
      end;
      Remove (Path);
      Remove (Progress_Path);
   end;

   declare
      Path : constant String := "suite-config.csv";
      File : Ada.Text_IO.File_Type;
      Summary : Runner.Run_Summary;
      Options : constant Runner.Runner_Options :=
        Runner.Parse
          ([U ("--exact=core/alpha"), U ("--samples=12"),
            U ("--output-style=csv")], Base_Config);
   begin
      Remove (Path);
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Runner.Execute
        (Target, "config_suite", Options, Summary,
         Output => File, Progress => File);
      Ada.Text_IO.Close (File);
      Check (Runner.Successful (Summary), "ordinary suite did not succeed");
      Check (Last_Config.Samples = 12, "callback did not receive CLI sample count");
      Check
        (Last_Config.Maximum_Iterations = 1_000,
         "callback configuration changed unrelated field");
      declare
         Output_Text : constant String := Read_All (Path);
      begin
         Check
           (Ada.Strings.Fixed.Index (Output_Text, "row_kind") /= 0
            and then Ada.Strings.Fixed.Index
              (Output_Text,
               "config_suite,core/alpha,ordinary_measurement,completed,false,"
               & "measurement") /= 0
            and then Ada.Strings.Fixed.Index
              (Output_Text, "clock_backend") /= 0
            and then Ada.Strings.Fixed.Index
              (Output_Text, ",metric,") /= 0,
            "suite CSV did not preserve full reporter schemas");
      end;
      Remove (Path);
   end;

   declare
      Path : constant String := "suite-unavailable.csv";
      File : Ada.Text_IO.File_Type;
      Summary : Runner.Run_Summary;
      Metric_Config : constant Flyology_Bench.Configuration :=
        (Base_Config with delta
           Metrics => Flyology_Bench.Time_Metrics
             or Flyology_Bench.Flyology_Scheduler_Metrics,
           Scheduler_Probe => null);
      Options : constant Runner.Runner_Options :=
        Runner.Parse
          ([U ("--exact=core/alpha"), U ("--require-metrics"),
            U ("--output-style=csv")], Metric_Config);
   begin
      Remove (Path);
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Runner.Execute
        (Target, "metric_suite", Options, Summary,
         Output => File, Progress => File);
      Ada.Text_IO.Close (File);
      Check
        (Summary.Unavailable = 1
         and then Summary.Status = Runner.Requested_Metric_Unavailable,
         "unavailable requested metric status");
      Remove (Path);
   end;

   declare
      Path : constant String := "suite-human.out";
      Progress_Path : constant String := "suite-human.progress";
      Progress : Ada.Text_IO.File_Type;
      Summary : Runner.Run_Summary;
      Options : constant Runner.Runner_Options :=
        Runner.Parse
          ([U ("--exact=core/alpha"), U ("--output-style=human"),
            U ("--output=" & Path)], Base_Config);
   begin
      Remove (Path);
      Remove (Progress_Path);
      Ada.Text_IO.Create (Progress, Ada.Text_IO.Out_File, Progress_Path);
      Runner.Execute
        (Target, "human_suite", Options, Summary, Progress => Progress);
      Ada.Text_IO.Close (Progress);
      declare
         Human : constant String := Read_All (Path);
      begin
         Check
           (Ada.Strings.Fixed.Index (Human, "suite human_suite: selected 1") /= 0,
            "human suite start absent");
         Check
           (Ada.Strings.Fixed.Index (Human, "case core/alpha: completed") /= 0,
            "human case outcome absent");
         Check
           (Ada.Strings.Fixed.Index (Human, "latency") /= 0,
            "existing human reporter was not used");
         Check
           (Ada.Strings.Fixed.Index (Human, "status=succeeded") /= 0,
            "human suite summary absent");
         Check
           (Ada.Strings.Fixed.Index (Human, ASCII.ESC & "[") = 0,
            "human output file contains ANSI");
      end;
      Remove (Path);
      Remove (Progress_Path);
   end;

   declare
      No_Match : constant Runner.Runner_Options :=
        Runner.Parse (Args_2 ("--filter", "absent"), Base_Config);
      Allowed : constant Runner.Runner_Options :=
        Runner.Parse
          (Args_3 ("--filter", "absent", "--allow-empty"), Base_Config);
      Summary : Runner.Run_Summary;
      Output_Path   : constant String := "suite-empty-list.out";
      Progress_Path : constant String := "suite-empty-list.progress";
      Output_File   : Ada.Text_IO.File_Type;
      Progress_File : Ada.Text_IO.File_Type;
      List_Options  : constant Runner.Runner_Options :=
        Runner.Parse
          ([U ("--list"), U ("--filter=absent")], Base_Config);
   begin
      Runner.List (Target, No_Match, Summary);
      Check
        (Summary.Status = Runner.No_Matching_Cases,
         "no-match status was successful");
      Runner.List (Target, Allowed, Summary);
      Check (Runner.Successful (Summary), "allow-empty did not pass");
      Remove (Output_Path);
      Remove (Progress_Path);
      Ada.Text_IO.Create (Output_File, Ada.Text_IO.Out_File, Output_Path);
      Ada.Text_IO.Create (Progress_File, Ada.Text_IO.Out_File, Progress_Path);
      Runner.Execute
        (Target, "empty_suite", List_Options, Summary,
         Output => Output_File, Progress => Progress_File);
      Ada.Text_IO.Close (Output_File);
      Ada.Text_IO.Close (Progress_File);
      Check
        (Ada.Strings.Fixed.Index
           (Read_All (Progress_Path),
            "no benchmark cases matched the selection") /= 0,
         "empty list omitted diagnostic");
      Remove (Output_Path);
      Remove (Progress_Path);
   end;

   declare
      JSON_Path     : constant String := "suite-smoke.jsonl";
      Progress_Path : constant String := "suite-smoke.progress";
      Progress      : Ada.Text_IO.File_Type;
      Dry_Base      : constant Flyology_Bench.Configuration :=
        (Flyology_Bench.Reporters.Terminal_Mode (Base_Config, "must-not-run")
         with delta
           Metrics => Flyology_Bench.All_Builtin_Metrics,
           CPU_Quiescence =>
             (Enabled => True,
              Maximum_Average_CPU_Percent => 0.0,
              Maximum_Core_CPU_Percent => 0.0,
              Stable_Time => 1.0,
              Poll_Interval => 0.100,
              Timeout => 15.0));
      Options : constant Runner.Runner_Options :=
        Runner.Parse
          ([U ("--dry-run"), U ("--continue-on-error"),
            U ("--output-style=json"), U ("--output=" & JSON_Path)],
           Dry_Base);
      Summary : Runner.Run_Summary;
   begin
      Remove (JSON_Path);
      Remove (Progress_Path);
      Ada.Text_IO.Create (Progress, Ada.Text_IO.Out_File, Progress_Path);
      Runner.Execute
        (Target, "smoke_suite", Options, Summary, Progress => Progress);
      Ada.Text_IO.Close (Progress);
      Check (Summary.Selected = 4, "dry selected count");
      Check (Summary.Completed = 3, "dry completed count");
      Check (Summary.Failed = 1, "dry failed count");
      Check (Summary.Dry_Run, "dry summary marker");
      Check (Summary.Status = Runner.Benchmark_Failed, "dry failure status");
      Check
        (Last_Config.Maximum_Iterations = 1_000
         and then Last_Config.Maximum_Sampling_Time > 0.0
         and then Last_Config.Metrics = Flyology_Bench.Time_Metrics
         and then not Last_Config.CPU_Quiescence.Enabled
         and then not Last_Config.Interference.Enabled
         and then not Last_Config.Placement.Enabled
         and then not Last_Config.Host_Lock.Enabled
         and then Last_Config.Progress = null,
         "dry run retained non-validation collection policy");
      declare
         Output_Text   : constant String := Read_All (JSON_Path);
         Progress_Text : constant String := Read_All (Progress_Path);
      begin
         Check
           (Ada.Strings.Fixed.Index (Output_Text, """dry_run"":true") /= 0,
            "dry JSON marker absent");
         Check
           (Ada.Strings.Fixed.Index (Output_Text, """median_ns"":null") /= 0,
            "dry JSON exposed performance number");
         Check
           (Ada.Strings.Fixed.Index (Output_Text, "core/failure") /= 0,
            "exception identity absent");
         Check
           (Ada.Strings.Fixed.Index (Output_Text, "running ") = 0,
            "progress leaked into output file");
         Check
           (Ada.Strings.Fixed.Index (Output_Text, ASCII.ESC & "[") = 0,
            "ANSI leaked into output file");
         Check
           (Ada.Strings.Fixed.Index (Progress_Text, "running core/alpha") /= 0,
            "progress stream absent");
      end;
      Remove (JSON_Path);
      Remove (Progress_Path);
   end;

   declare
      Path          : constant String := "suite-machine-progress.jsonl";
      Progress_Path : constant String := "suite-machine-progress.log";
      Progress      : Ada.Text_IO.File_Type;
      Summary       : Runner.Run_Summary;
      Terminal_Base : constant Flyology_Bench.Configuration :=
        Flyology_Bench.Reporters.Terminal_Mode
          (Base_Config, "must-not-run");
      Options : constant Runner.Runner_Options :=
        Runner.Parse
          ([U ("--exact=core/alpha"), U ("--output-style=json"),
            U ("--output=" & Path)], Terminal_Base);
   begin
      Remove (Path);
      Remove (Progress_Path);
      Ada.Text_IO.Create (Progress, Ada.Text_IO.Out_File, Progress_Path);
      Runner.Execute
        (Target, "machine_suite", Options, Summary, Progress => Progress);
      Ada.Text_IO.Close (Progress);
      Check (Runner.Successful (Summary), "machine suite did not succeed");
      Check
        (Last_Config.Progress = null,
         "machine output retained configured terminal progress");
      Check
        (Ada.Strings.Fixed.Index
           (Read_All (Path), """clock"":{""backend""") /= 0,
         "machine JSON omitted full reporter payload");
      Remove (Path);
      Remove (Progress_Path);
   end;

   declare
      Fast_Target : Runner.Suite;
      Summary : Runner.Run_Summary;
      Continue_Options : constant Runner.Runner_Options :=
        Runner.Parse
          ([U ("--dry-run"), U ("--continue-on-error"),
            U ("--output-style=csv")], Base_Config);
      Fail_Fast_Options : constant Runner.Runner_Options :=
        Runner.Parse
          ([U ("--dry-run"), U ("--fail-fast"),
            U ("--output-style=csv")], Base_Config);
      Sink : Ada.Text_IO.File_Type;
      Sink_Path : constant String := "suite-smoke.csv";
   begin
      Runner.Register (Fast_Target, "first", Run_Measurement'Access);
      Runner.Register (Fast_Target, "fails", Fail'Access);
      Runner.Register (Fast_Target, "last", Run_Measurement'Access);
      Remove (Sink_Path);
      Ada.Text_IO.Create (Sink, Ada.Text_IO.Out_File, Sink_Path);
      Runner.Execute
        (Fast_Target, "policy_suite", Continue_Options, Summary,
         Output => Sink, Progress => Sink);
      Ada.Text_IO.Close (Sink);
      Check (Summary.Completed = 2 and then Summary.Failed = 1,
             "continue-on-error counts");
      Ada.Text_IO.Create (Sink, Ada.Text_IO.Out_File, Sink_Path);
      Runner.Execute
        (Fast_Target, "policy_suite", Fail_Fast_Options, Summary,
         Output => Sink, Progress => Sink);
      Ada.Text_IO.Close (Sink);
      Check
        (Summary.Completed = 1 and then Summary.Failed = 1
         and then Summary.Skipped = 1,
         "fail-fast counts");
      Check
        (Ada.Strings.Fixed.Index (Read_All (Sink_Path), """quoted""") /= 0,
         "CSV exception escaping absent");
      Remove (Sink_Path);
   end;

   declare
      Reporting_Target : Runner.Suite;
      Summary          : Runner.Run_Summary;
      Options          : constant Runner.Runner_Options :=
        Runner.Parse
          ([U ("--output-style=csv"), U ("--fail-fast")], Base_Config);
      Progress         : Ada.Text_IO.File_Type;
      Output_Path      : constant String := "suite-reporting-error.csv";
      Progress_Path    : constant String := "suite-reporting-error.progress";
      Raised           : Boolean := False;
   begin
      Runner.Register
        (Reporting_Target, "close-output", Run_And_Close_Output'Access);
      Remove (Output_Path);
      Remove (Progress_Path);
      Ada.Text_IO.Create (Reporter_Sink, Ada.Text_IO.Out_File, Output_Path);
      Ada.Text_IO.Create (Progress, Ada.Text_IO.Out_File, Progress_Path);
      begin
         Runner.Execute
           (Reporting_Target, "reporting_suite", Options, Summary,
            Output => Reporter_Sink, Progress => Progress);
      exception
         when Ada.Text_IO.Status_Error | Ada.Text_IO.Device_Error =>
            Raised := True;
      end;
      Ada.Text_IO.Close (Progress);
      Check (Raised, "reporting failure did not propagate");
      Check
        (Summary.Completed = 1 and then Summary.Failed = 0,
         "reporting failure was counted as callback failure");
      Remove (Output_Path);
      Remove (Progress_Path);
   end;

   Check (Calls > 0 and then Counter > 0, "callbacks did not execute");
   Check (Last_Config.Samples = 10, "shared configuration not propagated");
   Ada.Text_IO.Put_Line ("flyology_bench suite smoke: ok");
end Suite_Smoke;
