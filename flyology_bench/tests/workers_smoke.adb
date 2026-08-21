--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Task_Identification;
with Flyology_Bench;
with Flyology_Bench.Workers;
with GNAT.OS_Lib;
with Interfaces.C;

procedure Workers_Smoke is
   package W renames Flyology_Bench.Workers;
   package US renames Ada.Strings.Unbounded;
   package C renames Interfaces.C;

   use type W.Worker_Outcome;
   use type W.Result_Kind;
   use type W.Locale_Policy;
   use type W.Timezone_Policy;
   use type Flyology_Bench.Host_Lock_Outcome;
   use type Flyology_Bench.Metric_Availability;
   use type Flyology_Bench.Metric_Set;
   use type C.int;
   use type GNAT.OS_Lib.File_Descriptor;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   function PID_Exists (Pid : C.int) return C.int;
   pragma Import
     (C, PID_Exists, "flyology_bench_worker_test_pid_exists");

   function Ignore_SIGCHLD return C.int;
   pragma Import
     (C, Ignore_SIGCHLD, "flyology_bench_worker_test_ignore_sigchld");

   function Restore_SIGCHLD return C.int;
   pragma Import
     (C, Restore_SIGCHLD, "flyology_bench_worker_test_restore_sigchld");

   Fixture : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_BENCH_WORKER_FIXTURE");
   Test_Directory : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_BENCH_TEST_DIR");
   Base : constant Flyology_Bench.Configuration :=
     (Flyology_Bench.Default_Configuration with delta
        Warmup_Time          => 0.0,
        Measurement_Time     => 0.004,
        Maximum_Sampling_Time => 0.020,
        Samples              => Flyology_Bench.Sample_Count'First,
        Minimum_Sample_Time  => 0.000_001,
        Random_Seed          => 41);
   Default_Launch : constant W.Launch_Configuration :=
     (Repetitions          => 1,
      Startup_Timeout      => 1.0,
      Total_Timeout        => 5.0,
      Termination_Grace    => 0.050,
      Diagnostic_Capacity  => 8_192,
      Directory            => W.Inherit_Directory,
      Working_Directory    => US.Null_Unbounded_String);

   procedure Expect_Configuration_Error
     (Label : String;
      Action : not null access procedure) is
   begin
      Action.all;
      raise Program_Error with Label & " was accepted";
   exception
      when W.Configuration_Error => null;
   end Expect_Configuration_Error;

begin
   declare
      Results : W.Worker_Result_Array (1 .. 3);
      Launch : constant W.Launch_Configuration :=
        (Default_Launch with delta Repetitions => 3);
      Env : constant W.Environment := W.Create_Environment;
   begin
      W.Run
        (Fixture, "ordinary", W.Ordinary_Measurement, Base, Launch, Env,
         Results);
      for Index in Results'Range loop
         Check (W.Outcome (Results (Index)) = W.Normal_Result,
                "ordinary worker failed: " & W.Reason (Results (Index))
                & "; stderr=" & W.Standard_Error (Results (Index)));
         Check (W.Repetition (Results (Index)) = Index,
                "worker repetition identity changed");
         Check (W.Seed (Results (Index)) = W.Derive_Seed (41, Index),
                "worker seed derivation changed");
         Check
           (Flyology_Bench.Samples (W.Measurement_Value (Results (Index)))
              = Flyology_Bench.Sample_Count'First,
            "ordinary result lost raw samples");
         Check (W.Spawn_Nanoseconds (Results (Index)) >= 0.0,
                "spawn duration is invalid");
         Check (W.Setup_Nanoseconds (Results (Index)) >= 0.0,
                "setup duration is invalid");
         Check (W.Environment_Fingerprint (Results (Index))'Length = 16,
                "environment fingerprint has the wrong shape");
      end loop;
      Check (W.Seed (Results (1)) /= W.Seed (Results (2)),
             "fresh workers reused one seed");
   end;

   declare
      Results : W.Worker_Result_Array (1 .. 1);
      Env : constant W.Environment := W.Create_Environment;
      Config : constant Flyology_Bench.Configuration :=
        (Base with delta
           Metrics => Flyology_Bench.Time_Metrics
             or Flyology_Bench.Flyology_Scheduler_Metrics);
   begin
      W.Run
        (Fixture, "ordinary", W.Ordinary_Measurement, Config,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Normal_Result,
             "valid unavailable worker metrics were rejected: "
             & W.Reason (Results (1)));
      declare
         Value : constant Flyology_Bench.Measurement :=
           W.Measurement_Value (Results (1));
      begin
         for Axis in Flyology_Bench.Flyology_Dispatches
           .. Flyology_Bench.Flyology_Migrations
         loop
            Check (Flyology_Bench.Metric_Requested (Value, Axis),
                   "worker lost a requested unavailable metric");
            Check
              (not Flyology_Bench.Metric_Available (Value, Axis)
               and then Flyology_Bench.Metric_Status (Value, Axis)
                 = Flyology_Bench.Probe_Failed,
               "worker changed an unavailable metric status");
         end loop;
      end;
   end;

   declare
      Results : W.Worker_Result_Array (1 .. 1);
      Env : constant W.Environment := W.Create_Environment;
   begin
      W.Run
        (Fixture, "paired", W.Paired_Comparison, Base, Default_Launch, Env,
         Results);
      Check (W.Outcome (Results (1)) = W.Normal_Result,
             "paired worker failed: " & W.Reason (Results (1)));
      Check
        (Flyology_Bench.Samples
           (Flyology_Bench.Reference_Measurement
              (W.Comparison_Value (Results (1))))
           = Flyology_Bench.Sample_Count'First,
         "paired worker split or lost its paired samples");
   end;

   declare
      Results : W.Worker_Result_Array (1 .. 1);
      Env : constant W.Environment := W.Create_Environment;
      Exact_Samples : constant Flyology_Bench.Configuration :=
        (Base with delta
           Maximum_Sampling_Time => 0.0,
           Samples => Flyology_Bench.Sample_Count'Succ
             (Flyology_Bench.Sample_Count'First));
      One_Iteration : constant Flyology_Bench.Configuration :=
        (Base with delta Maximum_Iterations => 1);
      procedure Expect_Malformed
        (Name            : String;
         Reason_Fragment : String := "") is
      begin
         W.Run
           (Fixture, Name, W.Ordinary_Measurement, Base,
            Default_Launch, Env, Results);
         Check (W.Outcome (Results (1)) = W.Malformed_Protocol,
                Name & " worker protocol was accepted");
         Check
           (Reason_Fragment'Length = 0
            or else Ada.Strings.Fixed.Index
              (W.Reason (Results (1)), Reason_Fragment) /= 0,
            Name & " did not exercise its intended protocol check");
      end Expect_Malformed;
   begin
      W.Run
        (Fixture, "exception", W.Ordinary_Measurement, Base,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Benchmark_Exception,
             "benchmark exception was not classified");
      Check (Ada.Strings.Fixed.Index (W.Reason (Results (1)),
                                     "fixture benchmark exception") > 0,
             "benchmark exception diagnostic was lost");

      W.Run
        (Fixture, "invalid", W.Ordinary_Measurement, Base,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Invalid_Worker_Configuration,
             "invalid worker configuration was not classified");

      W.Run
        (Fixture, "long-exception", W.Ordinary_Measurement, Base,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Benchmark_Exception,
             "bounded benchmark exception was not classified");
      Check
        (W.Reason (Results (1))'Length
           = 7 + 2 + W.Maximum_Result_Message_Length,
         "benchmark exception was not truncated to its envelope bound");

      W.Run
        (Fixture, "nonzero", W.Ordinary_Measurement, Base,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Nonzero_Exit,
             "nonzero worker exit was not classified");

      W.Run
        (Fixture, "abort", W.Ordinary_Measurement, Base,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Crashed_By_Signal,
             "worker signal crash was not classified");
      Check (W.Terminating_Signal (Results (1)) > 0,
             "worker signal number was not retained");

      Expect_Malformed ("malformed");
      Expect_Malformed ("truncated");
      Expect_Malformed ("oversized", "oversized");
      Expect_Malformed ("wrong-version", "version");
      Expect_Malformed ("wrong-identity", "identity");
      Expect_Malformed ("trailing");

      W.Run
        (Fixture, "wrong-result-seed", W.Ordinary_Measurement, Base,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Malformed_Protocol,
             "mismatched measurement seed was accepted");
      W.Run
        (Fixture, "wrong-metrics", W.Ordinary_Measurement, Base,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Malformed_Protocol,
             "measurement metric set mismatch was accepted");
      W.Run
        (Fixture, "wrong-statistics", W.Ordinary_Measurement, Base,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Malformed_Protocol,
             "measurement statistics mismatch was accepted");
      W.Run
        (Fixture, "wrong-environment-report", W.Ordinary_Measurement, Base,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Malformed_Protocol,
             "inconsistent environment report was accepted");
      W.Run
        (Fixture, "wrong-sample-count", W.Ordinary_Measurement,
         Exact_Samples, Default_Launch, Env, Results);
      Check
        (W.Outcome (Results (1)) = W.Malformed_Protocol
         and then Ada.Strings.Fixed.Index
           (W.Reason (Results (1)), "sample count") /= 0,
         "measurement sample-count mismatch was accepted");
      W.Run
        (Fixture, "wrong-iteration-count", W.Ordinary_Measurement,
         One_Iteration, Default_Launch, Env, Results);
      Check
        (W.Outcome (Results (1)) = W.Malformed_Protocol
         and then Ada.Strings.Fixed.Index
           (W.Reason (Results (1)), "iteration count") /= 0,
         "measurement iteration-count mismatch was accepted");
      W.Run
        (Fixture, "wrong-counts", W.Paired_Comparison, Base,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Malformed_Protocol,
             "inconsistent comparison counts were accepted");
      W.Run
        (Fixture, "wrong-comparison-statistics", W.Paired_Comparison, Base,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Malformed_Protocol,
             "comparison statistics mismatch was accepted");
   end;

   declare
      Results : W.Worker_Result_Array (1 .. 1);
      Env : constant W.Environment := W.Create_Environment;
      Timeout_Launch : W.Launch_Configuration :=
        (Default_Launch with delta
           Startup_Timeout   => 0.100,
           Total_Timeout     => 0.150,
           Termination_Grace => 0.020);
   begin
      W.Run
        (Fixture, "timeout", W.Ordinary_Measurement, Base,
         Timeout_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Execution_Timeout,
             "execution timeout was not classified");
      Check (W.Forced_Termination (Results (1)),
             "SIGTERM-resistant worker was not force-killed");
      Check (PID_Exists (W.Process_Id (Results (1))) = 0,
             "timed-out worker was not reaped");

      Timeout_Launch :=
        (Default_Launch with delta
           Startup_Timeout   => 0.050,
           Total_Timeout     => 0.500,
           Termination_Grace => 0.020);
      W.Run
        (Fixture, "startup-timeout", W.Ordinary_Measurement, Base,
         Timeout_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Startup_Timeout,
             "startup timeout was not classified");

      W.Run
        (Fixture, "diagnostics-timeout", W.Ordinary_Measurement, Base,
         Timeout_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Execution_Timeout,
             "continuous diagnostics postponed the worker deadline");
   end;

   declare
      Results : W.Worker_Result_Array (1 .. 1);
      Pid_File : constant String := Test_Directory & "/descendant.pid";
      Env : W.Environment := W.Create_Environment;
      Launch : constant W.Launch_Configuration :=
        (Default_Launch with delta
           Total_Timeout     => 0.200,
           Termination_Grace => 0.020);
      Descendant : C.int := -1;
   begin
      if Ada.Directories.Exists (Pid_File) then
         Ada.Directories.Delete_File (Pid_File);
      end if;
      W.Add (Env, "DESCENDANT_PID_FILE", Pid_File);
      W.Run
        (Fixture, "descendant-timeout", W.Ordinary_Measurement, Base,
         Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Execution_Timeout,
             "descendant containment fixture did not time out");
      Check (Ada.Directories.Exists (Pid_File),
             "descendant fixture did not publish its PID");
      declare
         File : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Pid_File);
         Descendant := C.int'Value (Ada.Text_IO.Get_Line (File));
         Ada.Text_IO.Close (File);
      end;
      for Attempt in 1 .. 200 loop
         exit when PID_Exists (Descendant) = 0;
         delay 0.010;
      end loop;
      Check (PID_Exists (Descendant) = 0,
             "worker process-group descendant survived containment");
   end;

   declare
      Results : W.Worker_Result_Array (1 .. 1);
      Pid_File : constant String := Test_Directory & "/parent-abort.pid";
      function Prepare_Pid_File return Boolean is
      begin
         if Ada.Directories.Exists (Pid_File) then
            Ada.Directories.Delete_File (Pid_File);
         end if;
         return True;
      end Prepare_Pid_File;
      Pid_File_Prepared : constant Boolean := Prepare_Pid_File;
      pragma Unreferenced (Pid_File_Prepared);
      function Parent_Abort_Environment return W.Environment is
         Result : W.Environment := W.Create_Environment;
      begin
         W.Add (Result, "WORKER_PID_FILE", Pid_File);
         return Result;
      end Parent_Abort_Environment;
      Env : constant W.Environment := Parent_Abort_Environment;
      Launch : constant W.Launch_Configuration :=
        (Default_Launch with delta Total_Timeout => 10.0);

      task Runner;
      task body Runner is
      begin
         W.Run
           (Fixture, "parent-abort", W.Ordinary_Measurement, Base,
            Launch, Env, Results);
      end Runner;

      Child_Pid : C.int := -1;
   begin
      for Attempt in 1 .. 200 loop
         exit when Ada.Directories.Exists (Pid_File);
         delay 0.010;
      end loop;
      Check (Ada.Directories.Exists (Pid_File),
             "parent-interruption fixture did not publish its PID");
      declare
         File : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Pid_File);
         Child_Pid := C.int'Value (Ada.Text_IO.Get_Line (File));
         Ada.Text_IO.Close (File);
      end;
      Ada.Task_Identification.Abort_Task (Runner'Identity);
      for Attempt in 1 .. 200 loop
         exit when Runner'Terminated;
         delay 0.010;
      end loop;
      Check (Runner'Terminated,
             "aborted worker parent did not finish cleanup");
      Check (PID_Exists (Child_Pid) = 0,
             "parent interruption left its worker alive or unreaped");
   end;

   declare
      Results : W.Worker_Result_Array (1 .. 1);
      Env : constant W.Environment := W.Create_Environment;
      Restored : C.int;
   begin
      Check (Ignore_SIGCHLD = 0,
             "cannot install the external-reaper fixture");
      begin
         W.Run
           (Fixture, "ordinary", W.Ordinary_Measurement, Base,
            Default_Launch, Env, Results);
      exception
         when others =>
            Restored := Restore_SIGCHLD;
            Check (Restored = 0,
                   "cannot restore SIGCHLD after worker exception");
            raise;
      end;
      Check (Restore_SIGCHLD = 0,
             "cannot restore SIGCHLD after the external-reaper fixture");
      Check (W.Outcome (Results (1)) = W.Parent_IO_Failure,
             "externally reaped worker was not classified as parent I/O");
      Check
        (Ada.Strings.Fixed.Index (W.Reason (Results (1)), "external reaper")
           /= 0,
         "externally reaped worker did not report lost ownership");
   end;

   declare
      Results : W.Worker_Result_Array (1 .. 1);
      Env : constant W.Environment := W.Create_Environment;
      Launch : constant W.Launch_Configuration :=
        (Default_Launch with delta Diagnostic_Capacity => 1_024);
   begin
      W.Run
        (Fixture, "diagnostics", W.Ordinary_Measurement, Base, Launch, Env,
         Results);
      Check (W.Outcome (Results (1)) = W.Normal_Result,
             "large diagnostics deadlocked or failed");
      Check (W.Standard_Output (Results (1))'Length = 1_024,
             "diagnostic capture bound changed");
      Check (W.Standard_Output_Omitted (Results (1)) = 98_977,
             "diagnostic truncation count is wrong:"
             & Natural'Image (W.Standard_Output_Omitted (Results (1))));
   end;

   declare
      Results : W.Worker_Result_Array (1 .. 1);
      Strict_Env : W.Environment := W.Create_Environment;
      Alternate_Env : W.Environment := W.Create_Environment;
      Inherited_Env : constant W.Environment :=
        W.Create_Environment (W.Inherit_Mode);
      Removed_Env : W.Environment := W.Create_Environment (W.Inherit_Mode);
      Preserved_Env : constant W.Environment :=
        W.Create_Environment
          (Locale => W.Preserve_Locale,
           Timezone => W.Preserve_Timezone);
      Launch : constant W.Launch_Configuration :=
        (Default_Launch with delta
           Directory => W.Use_Directory,
           Working_Directory => US.To_Unbounded_String (Test_Directory));
      Had_Secret : constant Boolean :=
        Ada.Environment_Variables.Exists ("WORKER_SECRET");
      Old_Secret : constant String :=
        Ada.Environment_Variables.Value ("WORKER_SECRET", "");
      First_Fingerprint : US.Unbounded_String;
   begin
      Ada.Environment_Variables.Set ("WORKER_SECRET", "do-not-report");
      W.Add (Strict_Env, "KEEP", "strict-value");
      W.Run
        (Fixture, "environment", W.Ordinary_Measurement, Base, Launch,
         Strict_Env, Results);
      Check (Ada.Strings.Fixed.Index
               (W.Standard_Output (Results (1)), "KEEP=strict-value") > 0,
             "strict environment addition was lost");
      Check (Ada.Strings.Fixed.Index
               (W.Standard_Output (Results (1)), "SECRET=<missing>") > 0,
             "strict environment leaked a parent secret");
      Check (Ada.Strings.Fixed.Index
               (W.Standard_Output (Results (1)), "CWD=" & Test_Directory) > 0,
             "explicit worker directory was not applied");
      Check (Ada.Strings.Fixed.Index
               (W.Environment_Fingerprint (Results (1)), "do-not-report") = 0,
             "environment fingerprint echoed a secret");
      First_Fingerprint := US.To_Unbounded_String
        (W.Environment_Fingerprint (Results (1)));

      W.Add (Alternate_Env, "KEEP", "different-secret-value");
      W.Run
        (Fixture, "environment", W.Ordinary_Measurement, Base, Launch,
         Alternate_Env, Results);
      Check (W.Outcome (Results (1)) = W.Normal_Result,
             "alternate-value environment worker failed");
      Check
        (W.Environment_Fingerprint (Results (1))
           = US.To_String (First_Fingerprint),
         "reported environment fingerprint depends on variable values");

      W.Run
        (Fixture, "environment", W.Ordinary_Measurement, Base, Launch,
         Preserved_Env, Results);
      Check
        (W.Outcome (Results (1)) = W.Normal_Result
         and then W.Environment_Locale_Policy (Results (1))
           = W.Preserve_Locale
         and then W.Environment_Timezone_Policy (Results (1))
           = W.Preserve_Timezone,
         "effective locale or timezone policy was not retained");

      W.Run
        (Fixture, "environment", W.Ordinary_Measurement, Base,
         Default_Launch, Inherited_Env, Results);
      Check (Ada.Strings.Fixed.Index
               (W.Standard_Output (Results (1)), "SECRET=do-not-report") > 0,
             "explicit inherited environment was not inherited");

      W.Remove (Removed_Env, "WORKER_SECRET");
      W.Run
        (Fixture, "environment", W.Ordinary_Measurement, Base,
         Default_Launch, Removed_Env, Results);
      Check (Ada.Strings.Fixed.Index
               (W.Standard_Output (Results (1)), "SECRET=<missing>") > 0,
             "explicit environment removal was ignored");
      if Had_Secret then
         Ada.Environment_Variables.Set ("WORKER_SECRET", Old_Secret);
      else
         Ada.Environment_Variables.Clear ("WORKER_SECRET");
      end if;
   end;

   declare
      Reserved_FD : constant GNAT.OS_Lib.File_Descriptor :=
        GNAT.OS_Lib.Open_Read ("/dev/null", GNAT.OS_Lib.Binary);
      FD : constant GNAT.OS_Lib.File_Descriptor :=
        GNAT.OS_Lib.Open_Read ("/dev/null", GNAT.OS_Lib.Binary);
      Results : W.Worker_Result_Array (1 .. 1);
      Env : W.Environment := W.Create_Environment;
   begin
      Check
        (Reserved_FD /= GNAT.OS_Lib.Invalid_FD
         and then FD /= GNAT.OS_Lib.Invalid_FD
         and then FD > 3,
         "cannot open descriptor fixture");
      W.Add
        (Env, "TEST_FD", Ada.Strings.Fixed.Trim
           (GNAT.OS_Lib.File_Descriptor'Image (FD), Ada.Strings.Both));
      W.Run
        (Fixture, "descriptor", W.Ordinary_Measurement, Base,
         Default_Launch, Env, Results);
      GNAT.OS_Lib.Close (Reserved_FD);
      GNAT.OS_Lib.Close (FD);
      Check (W.Outcome (Results (1)) = W.Normal_Result,
             "unintended descriptor survived exec");
   end;

   declare
      Results : W.Worker_Result_Array (1 .. 1);
      Env : constant W.Environment := W.Create_Environment;
      Config : constant Flyology_Bench.Configuration :=
        (Base with delta
           Host_Lock =>
             (Enabled               => True,
              Path                  => US.To_Unbounded_String
                (Test_Directory & "/worker-host.lock"),
              Timeout               => 0.100,
              Poll_Interval         => 0.010,
              Require_Machine_Scope => False));
   begin
      W.Run
        (Fixture, "ordinary", W.Ordinary_Measurement, Config,
         Default_Launch, Env, Results);
      Check (W.Outcome (Results (1)) = W.Normal_Result,
             "worker-owned host lock failed or self-deadlocked");
      Check
        (Flyology_Bench.Environment
           (W.Measurement_Value (Results (1))).Host_Lock
           in Flyology_Bench.Lock_Held
            | Flyology_Bench.Lock_Namespace_Scoped,
         "host lock was not acquired inside the measuring worker");
   end;

   declare
      Item : W.Environment := W.Create_Environment;
      procedure Duplicate is
      begin
         W.Add (Item, "A", "1");
         W.Add (Item, "A", "2");
      end Duplicate;
      procedure Invalid_Name is
      begin
         W.Add (Item, "A=B", "1");
      end Invalid_Name;
      procedure NUL_Value is
      begin
         W.Add (Item, "B", "x" & Character'Val (0));
      end NUL_Value;
      procedure Oversized is
      begin
         W.Add
           (Item, "C", String'(1 .. W.Maximum_Environment_Value_Length + 1
                               => 'x'));
      end Oversized;
      procedure Duplicate_Removal is
      begin
         W.Remove (Item, "D");
         W.Remove (Item, "D");
      end Duplicate_Removal;
      procedure Add_Remove_Conflict is
      begin
         W.Add (Item, "E", "1");
         W.Remove (Item, "E");
      end Add_Remove_Conflict;
      procedure Total_Overflow is
         Large : W.Environment := W.Create_Environment;
         Results : W.Worker_Result_Array (1 .. 1);
      begin
         W.Add (Large, "L1", String'(1 .. 16_000 => 'x'));
         W.Add (Large, "L2", String'(1 .. 16_000 => 'x'));
         W.Add (Large, "L3", String'(1 .. 16_000 => 'x'));
         W.Add (Large, "L4", String'(1 .. 16_000 => 'x'));
         W.Add (Large, "L5", String'(1 .. 16_000 => 'x'));
         W.Run
           (Fixture, "ordinary", W.Ordinary_Measurement, Base,
            Default_Launch, Large, Results);
      end Total_Overflow;
      procedure Long_Host_Lock_Path is
         Results : W.Worker_Result_Array (1 .. 1);
         Env : constant W.Environment := W.Create_Environment;
         Config : constant Flyology_Bench.Configuration :=
           (Base with delta
              Host_Lock =>
                (Enabled => True,
                 Path => US.To_Unbounded_String
                   (String'(1 .. W.Maximum_Host_Lock_Path_Length + 1 => 'p')),
                 Timeout => 0.0,
                 Poll_Interval => 0.010,
                 Require_Machine_Scope => False));
      begin
         W.Run
           (Fixture, "ordinary", W.Ordinary_Measurement, Config,
            Default_Launch, Env, Results);
      end Long_Host_Lock_Path;
      procedure Long_Progress_Name is
         Results : W.Worker_Result_Array (1 .. 1);
         Env : constant W.Environment := W.Create_Environment;
         Config : constant Flyology_Bench.Configuration :=
           (Base with delta
              Progress_Name => US.To_Unbounded_String
                (String'(1 .. W.Maximum_Progress_Name_Length + 1 => 'n')));
      begin
         W.Run
           (Fixture, "ordinary", W.Ordinary_Measurement, Config,
            Default_Launch, Env, Results);
      end Long_Progress_Name;
   begin
      Expect_Configuration_Error ("duplicate environment", Duplicate'Access);
      Expect_Configuration_Error ("invalid environment name", Invalid_Name'Access);
      Expect_Configuration_Error ("NUL environment value", NUL_Value'Access);
      Expect_Configuration_Error ("oversized environment value", Oversized'Access);
      Expect_Configuration_Error
        ("duplicate environment removal", Duplicate_Removal'Access);
      Expect_Configuration_Error
        ("environment add/remove conflict", Add_Remove_Conflict'Access);
      Expect_Configuration_Error
        ("total environment overflow", Total_Overflow'Access);
      Expect_Configuration_Error
        ("overlong host-lock path", Long_Host_Lock_Path'Access);
      Expect_Configuration_Error
        ("overlong progress name", Long_Progress_Name'Access);
   end;

   Ada.Text_IO.Put_Line ("flyology_bench fresh workers: PASS");
end Workers_Smoke;
