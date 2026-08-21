--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Interfaces;
with Interfaces.C;

--  Runs one registered benchmark case per fresh process.  The package does
--  not discover cases, aggregate statistics, report a suite, or set process
--  status.  A suite supplies one exact stable identity and retains the
--  returned worker hierarchy.
--
--  The parent uses posix_spawn(3), never fork followed by Ada execution.  The
--  same executable enters Worker_Mode, announces readiness, executes one
--  ordinary or paired case, and writes one bounded binary result envelope to
--  a dedicated descriptor.  Standard output and error are separate bounded
--  diagnostics and are never parsed as protocol data.
package Flyology_Bench.Workers is

   --  Current binary envelope schema.
   Protocol_Version : constant := 1;
   --  Largest encoded stable case identity.
   Maximum_Identity_Length : constant := 512;
   --  Largest effective or edited environment entry count.
   Maximum_Environment_Entries : constant := 256;
   --  Largest environment variable name.
   Maximum_Environment_Name_Length : constant := 255;
   --  Largest environment variable value.
   Maximum_Environment_Value_Length : constant := 16_384;
   --  Largest complete environment including terminators.
   Maximum_Environment_Bytes : constant := 65_536;
   --  Largest encoded benchmark configuration carried in internal argv.
   Maximum_Configuration_Bytes : constant := 16_384;
   --  Largest host-lock path carried to a worker.
   Maximum_Host_Lock_Path_Length : constant := 4_096;
   --  Largest progress identity carried to a worker.
   Maximum_Progress_Name_Length : constant := 512;
   --  Largest exception identity carried in a result envelope.
   Maximum_Exception_Name_Length : constant := 4_096;
   --  Largest exception or configuration message carried in an envelope.
   Maximum_Result_Message_Length : constant := 16_384;
   --  Largest retained diagnostic stream.
   Maximum_Diagnostic_Bytes : constant := 1_048_576;
   --  Largest repetition request accepted by one Run call.
   Maximum_Worker_Repetitions : constant := 256;

   --  Raised when parent launch policy or worker request data is invalid.
   Configuration_Error : exception;
   --  Raised when a worker-side request or result envelope fails validation.
   Protocol_Error      : exception;

   --  Result shape retained inside one worker.  Direct comparisons remain
   --  paired in one process.  Later protocol versions may add result kinds;
   --  this version truthfully supports the suite's ordinary and paired set.
   --  @enum Ordinary_Measurement One standalone Measurement.
   --  @enum Paired_Comparison One Comparison retaining both sides and pairing.
   type Result_Kind is (Ordinary_Measurement, Paired_Comparison);

   --  Parent classification for one independent worker process.
   --  @enum Normal_Result A complete validated result and zero process exit.
   --  @enum Benchmark_Exception Worker reported a benchmark exception.
   --  @enum Invalid_Worker_Configuration Worker rejected its configuration.
   --  @enum Startup_Timeout Ready marker missed the startup deadline.
   --  @enum Execution_Timeout Total per-worker deadline expired.
   --  @enum Crashed_By_Signal Worker terminated because of a signal.
   --  @enum Nonzero_Exit Worker exited nonzero without another classification.
   --  @enum Malformed_Protocol Result envelope failed closed validation.
   --  @enum Parent_IO_Failure Parent capture, observation, cleanup, or
   --  exclusive child-reaping ownership failed.
   --  @enum Spawn_Failure posix_spawn rejected the launch.
   type Worker_Outcome is
     (Normal_Result,
      Benchmark_Exception,
      Invalid_Worker_Configuration,
      Startup_Timeout,
      Execution_Timeout,
      Crashed_By_Signal,
      Nonzero_Exit,
      Malformed_Protocol,
      Parent_IO_Failure,
      Spawn_Failure);

   --  Environment construction policy.  Strict_Mode starts from a small
   --  execution allowlist.  Inherit_Mode copies the complete parent
   --  environment and must be selected explicitly.
   --  @enum Strict_Mode Start from the documented minimal allowlist.
   --  @enum Inherit_Mode Copy the complete parent environment explicitly.
   type Environment_Mode is (Strict_Mode, Inherit_Mode);

   --  Locale and timezone are omitted in strict mode unless explicitly
   --  preserved.  In inherited mode they are already part of the selected
   --  complete environment.
   --  @enum Clear_Locale Omit locale variables in strict mode.
   --  @enum Preserve_Locale Retain LANG and LC_* in strict mode.
   type Locale_Policy is (Clear_Locale, Preserve_Locale);
   --  Controls timezone inheritance under strict environment mode.
   --  @enum Clear_Timezone Omit TZ in strict mode.
   --  @enum Preserve_Timezone Retain TZ in strict mode.
   type Timezone_Policy is (Clear_Timezone, Preserve_Timezone);

   --  Validated environment construction policy and explicit edits.
   type Environment is private;

   --  Construct an environment policy with no additions or removals.
   --  @param Mode Strict allowlist or explicit complete inheritance.
   --  @param Locale Locale handling under strict mode.
   --  @param Timezone Timezone handling under strict mode.
   --  @return New environment policy.
   function Create_Environment
     (Mode     : Environment_Mode := Strict_Mode;
      Locale   : Locale_Policy := Clear_Locale;
      Timezone : Timezone_Policy := Clear_Timezone) return Environment;

   --  Add one exact name/value override.  Duplicate additions, a name also
   --  removed, invalid forms, NULs, and bounded-size violations are rejected.
   --  @param Item Policy to update.
   --  @param Name Exact environment variable name.
   --  @param Value Exact environment variable value.
   procedure Add
     (Item : in out Environment;
      Name : String;
      Value : String);

   --  Remove one name after the selected base policy is constructed.
   --  Duplicate removals and a name also added are rejected.
   --  @param Item Policy to update.
   --  @param Name Exact environment variable name.
   procedure Remove (Item : in out Environment; Name : String);

   --  Return the selected base environment mode.
   --  @param Item Environment policy.
   --  @return Strict or inherited mode.
   function Mode (Item : Environment) return Environment_Mode;
   --  Return strict-mode locale handling.
   --  @param Item Environment policy.
   --  @return Locale policy.
   function Locale (Item : Environment) return Locale_Policy;
   --  Return strict-mode timezone handling.
   --  @param Item Environment policy.
   --  @return Timezone policy.
   function Timezone (Item : Environment) return Timezone_Policy;

   --  Working-directory policy is named explicitly.  Use_Directory requires
   --  a nonempty directory value and resolves it before spawning.
   --  @enum Inherit_Directory Keep the parent's current directory.
   --  @enum Use_Directory Resolve and enter Working_Directory before exec.
   type Directory_Mode is (Inherit_Directory, Use_Directory);

   --  Number of independent worker processes requested for one case.
   subtype Repetition_Count is
     Positive range 1 .. Maximum_Worker_Repetitions;
   --  Retained byte capacity for each diagnostic stream.
   subtype Diagnostic_Limit is Natural range 0 .. Maximum_Diagnostic_Bytes;

   --  Each repetition gets its own startup and total monotonic deadline.
   --  Total_Timeout includes spawn and setup.  Spawn duration is also reported
   --  separately and is never included in the worker's operation samples.
   --  @field Repetitions Independent worker process count.
   --  @field Startup_Timeout Spawn-to-ready deadline for each worker.
   --  @field Total_Timeout Complete per-worker deadline starting before spawn.
   --  @field Termination_Grace Delay between graceful and forced termination.
   --  @field Diagnostic_Capacity Retained bytes per stdout or stderr stream.
   --  @field Directory Named working-directory policy.
   --  @field Working_Directory Path required only by Use_Directory.
   type Launch_Configuration is record
      Repetitions         : Repetition_Count := 1;
      Startup_Timeout     : Positive_Duration := 5.0;
      Total_Timeout       : Positive_Duration := 60.0;
      Termination_Grace   : Nonnegative_Duration := 0.250;
      Diagnostic_Capacity : Diagnostic_Limit := 65_536;
      Directory           : Directory_Mode := Inherit_Directory;
      Working_Directory   : Ada.Strings.Unbounded.Unbounded_String;
   end record
     with Dynamic_Predicate =>
       Launch_Configuration.Total_Timeout
         >= Launch_Configuration.Startup_Timeout;

   --  Validated worker-side request recovered from the internal argv protocol.
   type Worker_Request is private;
   --  One parent-side process outcome and optional benchmark result.
   type Worker_Result is private;
   --  Hierarchy of independent process results retained in repetition order.
   type Worker_Result_Array is array (Positive range <>) of Worker_Result;

   --  Derive a stable nonzero seed from one parent seed and a one-based
   --  repetition.  Repetitions are independent resampling units; callers must
   --  not flatten their within-worker samples into one paired stream.
   --  @param Parent_Seed Suite-level deterministic seed.
   --  @param Repetition One-based independent process index.
   --  @return Stable nonzero worker seed.
   function Derive_Seed
     (Parent_Seed : Long_Long_Integer;
      Repetition : Positive) return Long_Long_Integer;

   --  Spawn exactly Results'Length fresh processes.  Results'Length must equal
   --  Launch.Repetitions.  Executable is invoked directly and must contain a
   --  directory component; PATH is never searched.  Host lock, placement,
   --  quiescence, interference observation, and metric sessions therefore run
   --  only inside the measuring worker.
   --  The caller must exclude process-wide SIGCHLD policies or other child
   --  reapers that consume these workers. If ownership is nevertheless lost,
   --  Run stops signaling the unanchored PID and reports Parent_IO_Failure.
   --  @param Executable Direct path to the same benchmark executable.
   --  @param Identity Exact stable registered case identity.
   --  @param Kind Expected ordinary or paired result shape.
   --  @param Config Measurement policy serialized for each worker.
   --  @param Launch Repetition, deadline, diagnostics, and cwd policy.
   --  @param Env Environment construction policy.
   --  @param Results Caller-sized output array retaining worker hierarchy.
   procedure Run
     (Executable : String;
      Identity   : String;
      Kind       : Result_Kind;
      Config     : Configuration;
      Launch     : Launch_Configuration;
      Env        : Environment;
      Results    : out Worker_Result_Array);

   --  Return the classified worker outcome.
   --  @param Result Worker process result.
   --  @return Distinct completion or failure class.
   function Outcome (Result : Worker_Result) return Worker_Outcome;
   --  Return the expected result shape.
   --  @param Result Worker process result.
   --  @return Ordinary or paired kind.
   function Kind (Result : Worker_Result) return Result_Kind;
   --  Return the exact requested stable identity.
   --  @param Result Worker process result.
   --  @return Case identity validated against the envelope.
   function Identity (Result : Worker_Result) return String;
   --  Return the one-based worker repetition.
   --  @param Result Worker process result.
   --  @return Independent process index.
   function Repetition (Result : Worker_Result) return Positive;
   --  Return the derived deterministic worker seed.
   --  @param Result Worker process result.
   --  @return Seed used inside this worker.
   function Seed (Result : Worker_Result) return Long_Long_Integer;
   --  Return the launch-time process identifier for diagnostics only.
   --  @param Result Worker process result.
   --  @return Reaped root PID, which the host may already have reused.
   function Process_Id (Result : Worker_Result) return Interfaces.C.int;
   --  Return direct spawn duration outside timed workload.
   --  @param Result Worker process result.
   --  @return Spawn duration in nanoseconds.
   function Spawn_Nanoseconds (Result : Worker_Result) return Long_Float;
   --  Return post-spawn duration through the ready marker.
   --  @param Result Worker process result.
   --  @return Setup duration in nanoseconds.
   function Setup_Nanoseconds (Result : Worker_Result) return Long_Float;
   --  Return the non-echoing effective environment hash.
   --  @param Result Worker process result.
   --  @return Sixteen lowercase hexadecimal digits.
   function Environment_Fingerprint (Result : Worker_Result) return String;
   --  Return the selected environment construction mode.
   --  @param Result Worker process result.
   --  @return Strict or inherited mode.
   function Environment_Policy (Result : Worker_Result) return Environment_Mode;
   --  Return a nonzero ordinary exit code, or zero when not applicable.
   --  @param Result Worker process result.
   --  @return Portable exit code.
   function Exit_Code (Result : Worker_Result) return Natural;
   --  Return the terminating signal, or zero when not applicable.
   --  @param Result Worker process result.
   --  @return Host signal number.
   function Terminating_Signal (Result : Worker_Result) return Natural;
   --  Report whether timeout escalation required hard termination.
   --  @param Result Worker process result.
   --  @return True after the grace deadline required SIGKILL.
   function Forced_Termination (Result : Worker_Result) return Boolean;
   --  Return bounded classification detail without captured stderr.
   --  @param Result Worker process result.
   --  @return Human diagnostic for the outcome.
   function Reason (Result : Worker_Result) return String;
   --  Return retained standard output bytes.
   --  @param Result Worker process result.
   --  @return Bounded stdout prefix.
   function Standard_Output (Result : Worker_Result) return String;
   --  Return retained standard error bytes.
   --  @param Result Worker process result.
   --  @return Bounded stderr prefix.
   function Standard_Error (Result : Worker_Result) return String;
   --  Return stdout bytes drained but not retained.
   --  @param Result Worker process result.
   --  @return Exact omitted stdout byte count, saturating at Natural'Last.
   function Standard_Output_Omitted (Result : Worker_Result) return Natural;
   --  Return stderr bytes drained but not retained.
   --  @param Result Worker process result.
   --  @return Exact omitted stderr byte count, saturating at Natural'Last.
   function Standard_Error_Omitted (Result : Worker_Result) return Natural;

   --  These queries require Normal_Result and the matching result kind.
   --  @param Result Successful ordinary worker result.
   --  @return Reconstructed measurement including raw samples and metrics.
   function Measurement_Value (Result : Worker_Result) return Measurement;
   --  Return one successful paired result.
   --  @param Result Successful paired worker result.
   --  @return Reconstructed comparison retaining within-worker pairing.
   function Comparison_Value (Result : Worker_Result) return Comparison;

   --  Worker-side entry protocol.  A benchmark executable checks Worker_Mode
   --  before normal parent CLI handling.  Current_Request validates the
   --  complete internal argument set and the independently recomputed
   --  environment fingerprint.  No command string or shell syntax is parsed.
   --  @return True only for the reserved internal argv marker.
   function Worker_Mode return Boolean;
   --  Parse and validate the complete internal worker request.
   --  @return Exact request for one registered case.
   function Current_Request return Worker_Request;
   --  Return the selected case identity.
   --  @param Request Validated worker request.
   --  @return Exact stable identity.
   function Requested_Identity (Request : Worker_Request) return String;
   --  Return the selected result shape.
   --  @param Request Validated worker request.
   --  @return Ordinary or paired kind.
   function Requested_Kind (Request : Worker_Request) return Result_Kind;
   --  Return the selected process repetition.
   --  @param Request Validated worker request.
   --  @return One-based repetition.
   function Requested_Repetition (Request : Worker_Request) return Positive;
   --  Return the worker's derived seed.
   --  @param Request Validated worker request.
   --  @return Deterministic per-process seed.
   function Requested_Seed
     (Request : Worker_Request) return Long_Long_Integer;

   --  Rebuild the serializable measurement policy in the worker.  Process-
   --  local callback values come from Template; no access value crosses exec.
   --  @param Request Validated worker request.
   --  @param Template Worker-local callback sources.
   --  @return Reconstructed measurement configuration.
   function Requested_Configuration
     (Request  : Worker_Request;
      Template : Configuration := Default_Configuration)
      return Configuration;

   --  Write the startup marker after CLI/configuration validation and before
   --  host setup, warmup, calibration, or timed work.
   --  @param Request Validated worker request.
   procedure Announce_Ready (Request : Worker_Request);

   --  Write one complete result envelope.  Each operation may be called at
   --  most once and terminates protocol ownership for this worker.
   --  @param Request Validated worker request.
   --  @param Result Completed ordinary measurement.
   procedure Return_Result
     (Request : Worker_Request;
      Result  : Measurement);
   --  Write one complete paired result envelope.
   --  @param Request Validated worker request.
   --  @param Result Completed paired comparison.
   procedure Return_Result
     (Request : Worker_Request;
      Result  : Comparison);

   --  Return explicit non-success envelopes without mixing diagnostics into
   --  the result stream.
   --  @param Request Validated worker request.
   --  @param Name Exception identity.
   --  @param Message Bounded exception message.
   procedure Return_Benchmark_Exception
     (Request : Worker_Request;
      Name    : String;
      Message : String);
   --  Return an explicit invalid-configuration envelope.
   --  @param Request Validated worker request.
   --  @param Message Configuration diagnostic.
   procedure Return_Invalid_Configuration
     (Request : Worker_Request;
      Message : String);

private
   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   type Environment_Entry is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   package Environment_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Environment_Entry);

   type Environment is record
      Selected_Mode     : Environment_Mode := Strict_Mode;
      Selected_Locale   : Locale_Policy := Clear_Locale;
      Selected_Timezone : Timezone_Policy := Clear_Timezone;
      Additions         : Environment_Vectors.Vector;
      Removals          : String_Vectors.Vector;
   end record;

   type Worker_Request is record
      Identity_Value    : Ada.Strings.Unbounded.Unbounded_String;
      Kind_Value        : Result_Kind := Ordinary_Measurement;
      Repetition_Value  : Positive := 1;
      Seed_Value        : Long_Long_Integer := 1;
      Config_Value      : Configuration := Default_Configuration;
      Environment_Hash  : Interfaces.Unsigned_64 := 0;
      Configuration_Hash : Interfaces.Unsigned_64 := 0;
      Policy_Value      : Environment_Mode := Strict_Mode;
   end record;

   type Worker_Result is record
      Outcome_Value     : Worker_Outcome := Spawn_Failure;
      Kind_Value        : Result_Kind := Ordinary_Measurement;
      Identity_Value    : Ada.Strings.Unbounded.Unbounded_String;
      Repetition_Value  : Positive := 1;
      Seed_Value        : Long_Long_Integer := 1;
      Pid_Value         : Interfaces.C.int := Interfaces.C.int (-1);
      Spawn_Time        : Long_Float := 0.0;
      Setup_Time        : Long_Float := 0.0;
      Environment_Hash  : Interfaces.Unsigned_64 := 0;
      Policy_Value      : Environment_Mode := Strict_Mode;
      Exit_Code_Value   : Natural := 0;
      Signal_Value      : Natural := 0;
      Forced_Value      : Boolean := False;
      Reason_Value      : Ada.Strings.Unbounded.Unbounded_String;
      Output_Value      : Ada.Strings.Unbounded.Unbounded_String;
      Error_Value       : Ada.Strings.Unbounded.Unbounded_String;
      Output_Omitted    : Natural := 0;
      Error_Omitted     : Natural := 0;
      Measurement_Data  : Measurement;
      Comparison_Data   : Comparison;
   end record;

end Flyology_Bench.Workers;
