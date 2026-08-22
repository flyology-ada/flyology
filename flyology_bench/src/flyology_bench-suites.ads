--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology_Bench.Baselines;
with Flyology_Bench.Reporters;

--  Builds and runs an explicitly registered benchmark suite.
--
--  Registration is bounded and deterministic. A callback invokes an existing
--  generic Measure or Compare instantiation, so indirect dispatch surrounds
--  the measurement and never replaces the statically bound timed operation.
--  @formal Maximum_Cases Maximum registrations and selection predicates.
generic
   Maximum_Cases : Positive;
package Flyology_Bench.Suites is
   --  Registration or identity contract violation.
   Registration_Error : exception;

   --  Invalid or conflicting command-line option.
   Option_Error : exception;

   --  One-based registered case index.
   subtype Case_Index is Positive range 1 .. Maximum_Cases;

   --  Kind of result produced by a registered callback.
   --  @enum Ordinary_Measurement One Measurement result.
   --  @enum Paired_Comparison One order-balanced Comparison result.
   --  @enum Multi_Way_Comparison One comparison of two to sixteen cases.
   type Result_Kind is
     (Ordinary_Measurement, Paired_Comparison, Multi_Way_Comparison);

   --  Requested top-level runner action.
   --  @enum Run_Selected Execute the selected callbacks.
   --  @enum List_Selected List identities without executing callbacks.
   --  @enum Show_Help Print command-line help.
   type Runner_Action is (Run_Selected, List_Selected, Show_Help);

   --  Output written by the suite runner.
   --  @enum Human Plain result cards and suite summary.
   --  @enum CSV Typed table sections using the existing reporter schemas.
   --  @enum JSON Newline-delimited JSON suite objects.
   type Output_Style is (Human, CSV, JSON);

   --  Ordering of selected cases.
   --  @enum Registration_Order Preserve explicit registration order.
   --  @enum Name_Order Sort by complete case-sensitive identity.
   type Execution_Order is (Registration_Order, Name_Order);

   --  Response to a callback exception.
   --  @enum Continue_After_Error Report the error and invoke later cases.
   --  @enum Fail_Fast Stop before the next selected case.
   type Error_Policy is (Continue_After_Error, Fail_Fast);

   --  Final runner classification. Inconclusive paired or multi-way results do
   --  not fail a run. A gated ordinary measurement fails only when its explicit
   --  baseline policy rejects the result.
   --  @enum Succeeded Every applicable success condition passed.
   --  @enum No_Matching_Cases Selection was empty without --allow-empty.
   --  @enum Benchmark_Failed At least one callback raised an exception.
   --  @enum Requested_Metric_Unavailable A required built-in axis was absent.
   --  @enum Regression_Rejected A baseline gate rejected at least one result.
   type Final_Status is
     (Succeeded,
      No_Matching_Cases,
      Benchmark_Failed,
      Requested_Metric_Unavailable,
      Regression_Rejected);

   --  Programmatically inspectable bounded aggregate. Completed counts
   --  callbacks that returned normally, including dry runs and inconclusive
   --  comparisons. Skipped counts unselected registrations and selected cases
   --  not reached after fail-fast.
   --  @field Discovered Total explicit registrations.
   --  @field Selected Registrations selected before execution.
   --  @field Completed Callbacks that returned normally.
   --  @field Skipped Unselected or fail-fast-unreached registrations.
   --  @field Failed Callbacks that raised an exception.
   --  @field Inconclusive Completed paired results without a verdict.
   --  @field Unavailable Completed cases missing a required built-in axis.
   --  @field Rejected Results rejected by an installed baseline gate.
   --  @field Dry_Run Whether validation-only collection was used.
   --  @field Status Final process-oriented classification.
   type Run_Summary is record
      Discovered   : Natural := 0;
      Selected     : Natural := 0;
      Completed    : Natural := 0;
      Skipped      : Natural := 0;
      Failed       : Natural := 0;
      Inconclusive : Natural := 0;
      Unavailable  : Natural := 0;
      Rejected     : Natural := 0;
      Dry_Run      : Boolean := False;
      Status       : Final_Status := Succeeded;
   end record;

   --  Return whether the final status is successful.
   --  @param Summary Completed aggregate.
   --  @return True only for Succeeded.
   function Successful (Summary : Run_Summary) return Boolean;

   --  Callback around an already-instantiated Measure procedure.
   --  @param Config Effective shared collection policy.
   --  @param Result Completed ordinary measurement.
   type Measurement_Callback is access procedure
     (Config : Configuration;
      Result : out Measurement);

   --  Callback around an already-instantiated Compare procedure.
   --  @param Config Effective shared collection policy.
   --  @param Result Completed paired comparison.
   type Comparison_Callback is access procedure
     (Config : Configuration;
      Result : out Comparison);

   --  Explicit bounded suite registry.
   type Suite is tagged limited private;

   --  Register one ordinary measurement. Name and Group are case-sensitive
   --  portable identity segments: ASCII letters or digits followed by ASCII
   --  letters, digits, '.', '_', or '-'. Full identity is Group & "/" & Name,
   --  or Name when Group is empty. Tags is a comma-separated list using the
   --  same segment grammar. Empty tags and surrounding whitespace are not
   --  accepted.
   --  @param Target Registry to extend.
   --  @param Name Case identity segment.
   --  @param Run Already-instantiated measurement wrapper.
   --  @param Group Optional identity parent segment.
   --  @param Tags Optional comma-separated selection tags.
   procedure Register
     (Target : in out Suite;
      Name   : String;
      Run    : not null Measurement_Callback;
      Group  : String := "";
      Tags   : String := "");

   --  Register one ordinary measurement with a read-only saved-baseline gate.
   --  The gate runs after successful collection, uses the effective suite
   --  confidence, resample, and random-seed policy, and never creates or
   --  updates Baseline_Path. An empty Fingerprint selects benchmark metadata.
   --  @param Target Registry to extend.
   --  @param Name Case identity segment and baseline benchmark identity.
   --  @param Run Already-instantiated measurement wrapper.
   --  @param Baseline_Path Existing or policy-handled baseline artifact path.
   --  @param Policy Regression threshold and exceptional-state actions.
   --  @param Fingerprint Exact environment identity, or empty for metadata.
   --  @param Group Optional identity parent segment.
   --  @param Tags Optional comma-separated selection tags.
   procedure Register_Gated
     (Target        : in out Suite;
      Name          : String;
      Run           : not null Measurement_Callback;
      Baseline_Path : String;
      Policy        : Flyology_Bench.Baselines.Gate_Policy :=
        Flyology_Bench.Baselines.Fail_Closed_Gate_Policy;
      Fingerprint   : String := "";
      Group         : String := "";
      Tags          : String := "");

   --  Register one paired comparison. Reference_Name and Contender_Name are
   --  reporter labels and follow the identity-segment grammar.
   --  @param Target Registry to extend.
   --  @param Name Case identity segment.
   --  @param Reference_Name Stable reference reporter label.
   --  @param Contender_Name Stable contender reporter label.
   --  @param Run Already-instantiated comparison wrapper.
   --  @param Group Optional identity parent segment.
   --  @param Tags Optional comma-separated selection tags.
   procedure Register_Paired
     (Target         : in out Suite;
      Name           : String;
      Reference_Name : String;
      Contender_Name : String;
      Run            : not null Comparison_Callback;
      Group          : String := "";
      Tags           : String := "");

   --  Bind one Compare_Many instantiation and its enumeration-specific
   --  existing reporters to a suite registration. The helper's indirect
   --  callbacks remain outside every timed operation.
   generic
      --  Same enumeration used by Compare_Many.
      type Case_Id is (<>);
      --  Wrapper around the existing Compare_Many instance.
      with procedure Run
        (Config : Configuration;
         Result : out Multi_Comparison);
   package Multi_Way_Registration is
      --  Register the bound multi-way callback and reporters. Target is the
      --  registry to extend; Name and optional Group form its identity; Tags
      --  is the optional comma-separated selection set.
      procedure Register
        (Target : in out Suite;
         Name   : String;
         Group  : String := "";
         Tags   : String := "");
   end Multi_Way_Registration;

   --  Return the number of registrations.
   --  @param Target Registry to inspect.
   --  @return Registered case count.
   function Length (Target : Suite) return Natural;

   --  Return one full identity in registration order.
   --  @param Target Registry to inspect.
   --  @param Index One-based registration index.
   --  @return Stable full identity.
   function Full_Name (Target : Suite; Index : Case_Index) return String;

   --  Return one registered result kind.
   --  @param Target Registry to inspect.
   --  @param Index One-based registration index.
   --  @return Ordinary, paired, or multi-way result kind.
   function Kind (Target : Suite; Index : Case_Index) return Result_Kind;

   --  Result of one exact, non-reporting callback execution. This is the
   --  backend seam for process-isolation adapters; the suite retains registry,
   --  policy, reporting, and aggregation ownership.
   type Registered_Result is private;

   --  Invoke exactly one registration by full identity. This operation does
   --  not catch callback exceptions and performs no reporting or aggregation.
   --  @param Target Registry containing the callback.
   --  @param Full_Name Exact stable identity.
   --  @param Config Collection policy passed without modification.
   --  @param Result Exact callback result.
   --  @exception Constraint_Error If Full_Name is absent or multi-way.
   procedure Execute_One
     (Target    : Suite;
      Full_Name : String;
      Config    : Configuration;
      Result    : out Registered_Result);

   --  Invoke exactly one multi-way registration without inflating every
   --  ordinary/paired Registered_Result to Multi_Comparison's storage size.
   --  @param Target Registry containing the callback.
   --  @param Full_Name Exact stable identity.
   --  @param Config Collection policy passed without modification.
   --  @param Result Exact multi-way result.
   --  @exception Constraint_Error If Full_Name is absent or not multi-way.
   procedure Execute_One_Multi
     (Target    : Suite;
      Full_Name : String;
      Config    : Configuration;
      Result    : out Multi_Comparison);

   --  Return the kind stored in one exact execution result.
   --  @param Result Exact execution result.
   --  @return Ordinary or paired result kind.
   function Kind (Result : Registered_Result) return Result_Kind;

   --  Return an ordinary result.
   --  @param Result Exact execution result.
   --  @return Stored Measurement.
   --  @exception Constraint_Error If Kind is not Ordinary_Measurement.
   function Measurement_Value
     (Result : Registered_Result) return Measurement;

   --  Return a paired result.
   --  @param Result Exact execution result.
   --  @return Stored Comparison.
   --  @exception Constraint_Error If Kind is not Paired_Comparison.
   function Comparison_Value
     (Result : Registered_Result) return Comparison;

   --  String array used by the testable parser. A null array represents no
   --  arguments.
   type Argument_List is
     array (Positive range <>) of Ada.Strings.Unbounded.Unbounded_String;

   --  Parsed selection, configuration overrides, and output policy.
   type Runner_Options is private;

   --  Parse explicit arguments against Base_Config. Options accept either
   --  --name=value or --name value where a value is required. Duration values
   --  use a nonnegative decimal followed by ns, us, ms, or s. Parsing is
   --  strict: signs and exponents are rejected for durations and percentages.
   --  @param Arguments Explicit argument values without a program name.
   --  @param Base_Config Configuration retained where no override is present.
   --  @return Parsed selection, execution, configuration, and output policy.
   --  @exception Option_Error On an unknown, malformed, out-of-range, or
   --  conflicting option.
   function Parse
     (Arguments   : Argument_List;
      Base_Config : Configuration := Default_Configuration)
      return Runner_Options;

   --  Parse Ada.Command_Line arguments. This wrapper does no execution.
   --  @param Base_Config Configuration retained where no override is present.
   --  @return Parsed selection, execution, configuration, and output policy.
   function Parse_Command_Line
     (Base_Config : Configuration := Default_Configuration)
      return Runner_Options;

   --  Return the selected top-level action.
   --  @param Options Parsed runner policy.
   --  @return Run, list, or help action.
   function Action (Options : Runner_Options) return Runner_Action;

   --  Return the effective shared benchmark configuration.
   --  @param Options Parsed runner policy.
   --  @return Base configuration with explicit CLI overrides.
   function Effective_Configuration
     (Options : Runner_Options) return Configuration;

   --  Return the requested output format.
   --  @param Options Parsed runner policy.
   --  @return Human, CSV, or JSON style.
   function Format (Options : Runner_Options) return Output_Style;

   --  Return the explicit output path, or an empty string for Output.
   --  @param Options Parsed runner policy.
   --  @return Explicit output path or an empty string.
   function Output_Path (Options : Runner_Options) return String;

   --  Return whether the fast validation policy is active.
   --  @param Options Parsed runner policy.
   --  @return True for validation-only execution.
   function Is_Dry_Run (Options : Runner_Options) return Boolean;

   --  Return whether one registration is selected by exact, filter, group,
   --  tag, and skip predicates. A --filter without '*' or '?' is a substring
   --  match. Otherwise '*' matches zero or more characters and '?' matches one
   --  character. Matching is case-sensitive and applies to full identity.
   --  @param Target Registry containing the case.
   --  @param Options Parsed selection policy.
   --  @param Index One-based registration index.
   --  @return Whether every inclusion and exclusion predicate accepts it.
   function Is_Selected
     (Target  : Suite;
      Options : Runner_Options;
      Index   : Case_Index) return Boolean;

   --  List selected full identities without invoking callbacks. Registration
   --  order is retained unless --order=name was selected.
   --  @param Target Registry to inspect.
   --  @param Options Parsed selection and ordering policy.
   --  @param Summary Discovery aggregate with no completed callbacks.
   --  @param Output Destination for one identity per line.
   procedure List
     (Target  : Suite;
      Options : Runner_Options;
      Summary : out Run_Summary;
      Output  : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Execute selected callbacks serially and stream their results. Human
   --  output delegates detailed measurements to Flyology_Bench.Reporters.
   --  CSV prefixes the existing typed result/metric schemas with suite context;
   --  newline-delimited JSON extends each complete existing result object.
   --  Progress and exception diagnostics go to Progress, never to an explicit
   --  --output file. An explicit file is plain and contains no ANSI escapes.
   --  @param Target Registry to execute.
   --  @param Suite_Name Stable suite identity segment.
   --  @param Options Parsed selection, configuration, and reporting policy.
   --  @param Summary Final bounded aggregate.
   --  @param Output Default result stream when no path is explicit.
   --  @param Progress Diagnostic stream excluded from an explicit result file.
   procedure Execute
     (Target     : Suite;
      Suite_Name : String;
      Options    : Runner_Options;
      Summary    : out Run_Summary;
      Output     : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Progress   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Error);

   --  Print stable command-line help without parsing global state.
   --  @param Output Destination help stream.
   procedure Put_Help
     (Output : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

private
   use Ada.Strings.Unbounded;

   type Descriptor (Result : Result_Kind := Ordinary_Measurement) is record
      Name       : Unbounded_String;
      Group      : Unbounded_String;
      Tags       : Unbounded_String;
      Full       : Unbounded_String;
      case Result is
         when Ordinary_Measurement =>
            Measurement_Run : Measurement_Callback;
            Gate_Enabled    : Boolean := False;
            Gate_Path       : Unbounded_String;
            Gate_Fingerprint : Unbounded_String;
            Gate_Policy     : Flyology_Bench.Baselines.Gate_Policy :=
              Flyology_Bench.Baselines.Fail_Closed_Gate_Policy;
         when Paired_Comparison =>
            Reference_Name : Unbounded_String;
            Contender_Name : Unbounded_String;
            Comparison_Run : Comparison_Callback;
         when Multi_Way_Comparison =>
            Multi_Run : access procedure
              (Config : Configuration;
               Result : out Multi_Comparison);
            Multi_Console : access procedure
              (Result : Multi_Comparison;
               File   : Ada.Text_IO.File_Type);
            Multi_CSV : access procedure
              (Result  : Multi_Comparison;
               File    : Ada.Text_IO.File_Type;
               Context : Flyology_Bench.Reporters.Machine_Context);
            Multi_JSON : access procedure
              (Result  : Multi_Comparison;
               File    : Ada.Text_IO.File_Type;
               Context : Flyology_Bench.Reporters.Machine_Context);
      end case;
   end record;

   type Descriptor_Array is array (Case_Index) of Descriptor;

   type Suite is tagged limited record
      Count : Natural range 0 .. Maximum_Cases := 0;
      Cases : Descriptor_Array;
   end record;

   type String_Array is array (Case_Index) of Unbounded_String;

   type Registered_Result (Result : Result_Kind := Ordinary_Measurement) is
   record
      case Result is
         when Ordinary_Measurement =>
            Measured : Measurement;
         when Paired_Comparison =>
            Compared : Comparison;
         when Multi_Way_Comparison =>
            null;
      end case;
   end record;

   type Runner_Options is record
      Requested_Action : Runner_Action := Run_Selected;
      Output_Format    : Output_Style := Human;
      Order            : Execution_Order := Registration_Order;
      Errors           : Error_Policy := Continue_After_Error;
      Config           : Configuration := Default_Configuration;
      Path             : Unbounded_String;
      Exact            : Unbounded_String;
      Group            : Unbounded_String;
      Filters          : String_Array;
      Filter_Count     : Natural range 0 .. Maximum_Cases := 0;
      Skips            : String_Array;
      Skip_Count       : Natural range 0 .. Maximum_Cases := 0;
      Tags             : String_Array;
      Tag_Count        : Natural range 0 .. Maximum_Cases := 0;
      Dry              : Boolean := False;
      Allow_Empty      : Boolean := False;
      Require_Metrics  : Boolean := False;
   end record;
end Flyology_Bench.Suites;
