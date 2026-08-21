--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;

package body Flyology_Bench.Suites is

   type Case_Outcome is
     (Completed_Outcome,
      Dry_Run_Outcome,
      Inconclusive_Outcome,
      Unavailable_Outcome,
      Failed_Outcome);

   type Index_Array is array (Case_Index) of Case_Index;

   function Lower (Value : String) return String is
     (Ada.Characters.Handling.To_Lower (Value));

   function Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Valid_Segment (Value : String) return Boolean is
      function Initial (Item : Character) return Boolean is
        ((Item in 'a' .. 'z')
         or else (Item in 'A' .. 'Z')
         or else (Item in '0' .. '9'));

      function Rest (Item : Character) return Boolean is
        (Initial (Item)
         or else Item = '.'
         or else Item = '_'
         or else Item = '-');
   begin
      if Value'Length = 0 or else not Initial (Value (Value'First)) then
         return False;
      end if;
      for Index in Value'First + 1 .. Value'Last loop
         if not Rest (Value (Index)) then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Segment;

   procedure Validate_Tags (Tags : String) is
      First : Positive := Tags'First;
   begin
      if Tags'Length = 0 then
         return;
      end if;
      for Index in Tags'Range loop
         if Tags (Index) = ',' then
            if Index = First or else not Valid_Segment (Tags (First .. Index - 1))
            then
               raise Registration_Error with
                 "tags must be comma-separated identity segments";
            end if;
            First := Index + 1;
         end if;
      end loop;
      if First > Tags'Last or else not Valid_Segment (Tags (First .. Tags'Last))
      then
         raise Registration_Error with
           "tags must be comma-separated identity segments";
      end if;
   end Validate_Tags;

   function Join_Name (Group, Name : String) return String is
     (if Group'Length = 0 then Name else Group & "/" & Name);

   procedure Check_Registration
     (Target : Suite;
      Name   : String;
      Group  : String;
      Tags   : String)
   is
      Full : constant String := Join_Name (Group, Name);
   begin
      if not Valid_Segment (Name) then
         raise Registration_Error with "invalid benchmark name: " & Name;
      end if;
      if Group'Length > 0 and then not Valid_Segment (Group) then
         raise Registration_Error with "invalid benchmark group: " & Group;
      end if;
      Validate_Tags (Tags);
      if Target.Count = Maximum_Cases then
         raise Registration_Error with "benchmark suite capacity exceeded";
      end if;
      for Index in 1 .. Target.Count loop
         if To_String (Target.Cases (Index).Full) = Full then
            raise Registration_Error with
              "duplicate benchmark identity: " & Full;
         end if;
      end loop;
   end Check_Registration;

   procedure Register
     (Target : in out Suite;
      Name   : String;
      Run    : not null Measurement_Callback;
      Group  : String := "";
      Tags   : String := "") is
   begin
      Check_Registration (Target, Name, Group, Tags);
      Target.Count := Target.Count + 1;
      Target.Cases (Target.Count) :=
        (Result          => Ordinary_Measurement,
         Name            => To_Unbounded_String (Name),
         Group           => To_Unbounded_String (Group),
         Tags            => To_Unbounded_String (Tags),
         Full            => To_Unbounded_String (Join_Name (Group, Name)),
         Measurement_Run => Run);
   end Register;

   procedure Register_Paired
     (Target         : in out Suite;
      Name           : String;
      Reference_Name : String;
      Contender_Name : String;
      Run            : not null Comparison_Callback;
      Group          : String := "";
      Tags           : String := "") is
   begin
      Check_Registration (Target, Name, Group, Tags);
      if not Valid_Segment (Reference_Name)
        or else not Valid_Segment (Contender_Name)
      then
         raise Registration_Error with
           "paired reporter labels must be identity segments";
      end if;
      Target.Count := Target.Count + 1;
      Target.Cases (Target.Count) :=
        (Result         => Paired_Comparison,
         Name           => To_Unbounded_String (Name),
         Group          => To_Unbounded_String (Group),
         Tags           => To_Unbounded_String (Tags),
         Full           => To_Unbounded_String (Join_Name (Group, Name)),
         Reference_Name => To_Unbounded_String (Reference_Name),
         Contender_Name => To_Unbounded_String (Contender_Name),
         Comparison_Run => Run);
   end Register_Paired;

   package body Multi_Way_Registration is
      procedure Put_Console is new
        Flyology_Bench.Reporters.Put_Multi_Comparison_Console (Case_Id);
      procedure Put_CSV is new
        Flyology_Bench.Reporters.Put_Multi_Comparison_CSV (Case_Id);
      procedure Put_Metrics_CSV is new
        Flyology_Bench.Reporters.Put_Multi_Comparison_Metrics_CSV (Case_Id);
      procedure Put_JSON is new
        Flyology_Bench.Reporters.Put_Multi_Comparison_JSON (Case_Id);

      procedure Invoke
        (Config : Configuration;
         Result : out Multi_Comparison) is
      begin
         Run (Config, Result);
      end Invoke;

      procedure Report_Console
        (Result : Multi_Comparison;
         File   : Ada.Text_IO.File_Type) is
      begin
         Put_Console (Result, File, Flyology_Bench.Reporters.Plain);
      end Report_Console;

      procedure Report_CSV
        (Result  : Multi_Comparison;
         File    : Ada.Text_IO.File_Type;
         Context : Flyology_Bench.Reporters.Machine_Context) is
      begin
         Put_CSV (Result, File, Context);
         Flyology_Bench.Reporters.Put_Comparison_Metrics_CSV_Header
           (File, Context);
         Put_Metrics_CSV (Result, File, Context);
      end Report_CSV;

      procedure Report_JSON
        (Result  : Multi_Comparison;
         File    : Ada.Text_IO.File_Type;
         Context : Flyology_Bench.Reporters.Machine_Context) is
      begin
         Put_JSON (Result, File, Context);
      end Report_JSON;

      procedure Register
        (Target : in out Suite;
         Name   : String;
         Group  : String := "";
         Tags   : String := "") is
      begin
         Check_Registration (Target, Name, Group, Tags);
         Target.Count := Target.Count + 1;
         Target.Cases (Target.Count) :=
           (Result        => Multi_Way_Comparison,
            Name          => To_Unbounded_String (Name),
            Group         => To_Unbounded_String (Group),
            Tags          => To_Unbounded_String (Tags),
            Full          => To_Unbounded_String (Join_Name (Group, Name)),
            Multi_Run     => Invoke'Access,
            Multi_Console => Report_Console'Access,
            Multi_CSV     => Report_CSV'Access,
            Multi_JSON    => Report_JSON'Access);
      end Register;
   end Multi_Way_Registration;

   function Length (Target : Suite) return Natural is (Target.Count);

   procedure Check_Index (Target : Suite; Index : Case_Index) is
   begin
      if Index > Target.Count then
         raise Constraint_Error with "benchmark case index is not registered";
      end if;
   end Check_Index;

   function Full_Name (Target : Suite; Index : Case_Index) return String is
   begin
      Check_Index (Target, Index);
      return To_String (Target.Cases (Index).Full);
   end Full_Name;

   function Kind (Target : Suite; Index : Case_Index) return Result_Kind is
   begin
      Check_Index (Target, Index);
      return Target.Cases (Index).Result;
   end Kind;

   procedure Execute_One
     (Target    : Suite;
      Full_Name : String;
      Config    : Configuration;
      Result    : out Registered_Result)
   is
   begin
      for Index in 1 .. Target.Count loop
         if To_String (Target.Cases (Index).Full) = Full_Name then
            case Target.Cases (Index).Result is
               when Ordinary_Measurement =>
                  Result := (Result => Ordinary_Measurement, others => <>);
                  Target.Cases (Index).Measurement_Run
                    (Config, Result.Measured);
               when Paired_Comparison =>
                  Result := (Result => Paired_Comparison, others => <>);
                  Target.Cases (Index).Comparison_Run
                    (Config, Result.Compared);
               when Multi_Way_Comparison =>
                  raise Constraint_Error with
                    "multi-way registration requires Execute_One_Multi";
            end case;
            return;
         end if;
      end loop;
      raise Constraint_Error with
        "benchmark identity is not registered: " & Full_Name;
   end Execute_One;

   procedure Execute_One_Multi
     (Target    : Suite;
      Full_Name : String;
      Config    : Configuration;
      Result    : out Multi_Comparison) is
   begin
      for Index in 1 .. Target.Count loop
         if To_String (Target.Cases (Index).Full) = Full_Name then
            if Target.Cases (Index).Result /= Multi_Way_Comparison then
               raise Constraint_Error with
                 "registered result is not a multi-way comparison";
            end if;
            Target.Cases (Index).Multi_Run (Config, Result);
            return;
         end if;
      end loop;
      raise Constraint_Error with
        "benchmark identity is not registered: " & Full_Name;
   end Execute_One_Multi;

   function Kind (Result : Registered_Result) return Result_Kind is
     (Result.Result);

   function Measurement_Value
     (Result : Registered_Result) return Measurement is
   begin
      if Result.Result /= Ordinary_Measurement then
         raise Constraint_Error with "registered result is not a measurement";
      end if;
      return Result.Measured;
   end Measurement_Value;

   function Comparison_Value
     (Result : Registered_Result) return Comparison is
   begin
      if Result.Result /= Paired_Comparison then
         raise Constraint_Error with "registered result is not a comparison";
      end if;
      return Result.Compared;
   end Comparison_Value;

   function Starts_With (Value, Prefix : String) return Boolean is
     (Value'Length >= Prefix'Length
      and then Value (Value'First .. Value'First + Prefix'Length - 1) = Prefix);

   function Parse_Decimal (Value, Option : String) return Long_Float is
      Saw_Digit : Boolean := False;
      Saw_Dot   : Boolean := False;
   begin
      if Value'Length = 0 then
         raise Option_Error with Option & " requires a number";
      end if;
      for Character of Value loop
         if Character in '0' .. '9' then
            Saw_Digit := True;
         elsif Character = '.' and then not Saw_Dot then
            Saw_Dot := True;
         else
            raise Option_Error with Option & " has an invalid number: " & Value;
         end if;
      end loop;
      if not Saw_Digit then
         raise Option_Error with Option & " requires a number";
      end if;
      return Long_Float'Value (Value);
   exception
      when Option_Error =>
         raise;
      when others =>
         raise Option_Error with Option & " is out of range: " & Value;
   end Parse_Decimal;

   function Parse_Duration
     (Value    : String;
      Option   : String;
      Positive : Boolean) return Duration
   is
      Suffix_Length : Natural;
      Scale         : Long_Float;
   begin
      if Value'Length >= 2
        and then Value (Value'Last - 1 .. Value'Last) = "ns"
      then
         Suffix_Length := 2;
         Scale := 1.0E-9;
      elsif Value'Length >= 2
        and then Value (Value'Last - 1 .. Value'Last) = "us"
      then
         Suffix_Length := 2;
         Scale := 1.0E-6;
      elsif Value'Length >= 2
        and then Value (Value'Last - 1 .. Value'Last) = "ms"
      then
         Suffix_Length := 2;
         Scale := 1.0E-3;
      elsif Value'Length >= 1 and then Value (Value'Last) = 's' then
         Suffix_Length := 1;
         Scale := 1.0;
      else
         raise Option_Error with
           Option & " requires a duration ending in ns, us, ms, or s";
      end if;
      declare
         Last_Number : constant Integer := Value'Last - Suffix_Length;
      begin
         if Last_Number < Value'First then
            raise Option_Error with Option & " requires a numeric duration";
         end if;
         declare
            Parsed : constant Long_Float :=
              Parse_Decimal (Value (Value'First .. Last_Number), Option) * Scale;
            Converted : Duration;
         begin
            if Parsed < 0.0 or else (Positive and then Parsed = 0.0) then
               raise Option_Error with
                 Option & (if Positive then " must be positive"
                           else " must be nonnegative");
            end if;
            Converted := Duration (Parsed);
            if Positive and then Converted = 0.0 then
               raise Option_Error with
                 Option & " is below the minimum positive duration";
            end if;
            return Converted;
         exception
            when Option_Error =>
               raise;
            when others =>
               raise Option_Error with Option & " is out of range: " & Value;
         end;
      end;
   end Parse_Duration;

   function Parse_Count (Value, Option : String) return Sample_Count is
   begin
      if Value'Length = 0 then
         raise Option_Error with Option & " requires an integer";
      end if;
      for Character of Value loop
         if Character not in '0' .. '9' then
            raise Option_Error with Option & " requires an unsigned integer";
         end if;
      end loop;
      return Sample_Count'Value (Value);
   exception
      when Option_Error =>
         raise;
      when others =>
         raise Option_Error with
           Option & " must be in"
           & Sample_Count'Image (Sample_Count'First) & " .."
           & Sample_Count'Image (Sample_Count'Last);
   end Parse_Count;

   function Parse_Threshold (Value, Option : String)
      return Threshold_Percentage
   is
      Parsed : constant Long_Float := Parse_Decimal (Value, Option);
   begin
      if Parsed < 0.0 or else Parsed >= 100.0 then
         raise Option_Error with Option & " must be at least 0 and below 100";
      end if;
      return Threshold_Percentage (Parsed);
   end Parse_Threshold;

   function Parse_Seed (Value, Option : String) return Long_Long_Integer is
      First : Integer := Value'First;
   begin
      if Value'Length = 0 then
         raise Option_Error with Option & " requires an integer";
      end if;
      if Value (First) = '-' then
         First := First + 1;
      end if;
      if First > Value'Last then
         raise Option_Error with Option & " requires an integer";
      end if;
      for Index in First .. Value'Last loop
         if Value (Index) not in '0' .. '9' then
            raise Option_Error with Option & " requires an integer";
         end if;
      end loop;
      return Long_Long_Integer'Value (Value);
   exception
      when Option_Error =>
         raise;
      when others =>
         raise Option_Error with Option & " is out of range: " & Value;
   end Parse_Seed;

   function Parse
     (Arguments   : Argument_List;
      Base_Config : Configuration := Default_Configuration)
      return Runner_Options
   is
      Result : Runner_Options;
      Index  : Integer := Arguments'First;
      Saw_Help : Boolean := False;
      Saw_Fail_Fast : Boolean := False;
      Saw_Continue  : Boolean := False;

      function Take_Value (Option, Argument : String) return String is
         Prefix : constant String := Option & "=";
      begin
         if Starts_With (Argument, Prefix) then
            if Argument'Length = Prefix'Length then
               raise Option_Error with Option & " requires a value";
            end if;
            return Argument
              (Argument'First + Prefix'Length .. Argument'Last);
         end if;
         if Argument = Option then
            Index := Index + 1;
            if Index > Arguments'Last then
               raise Option_Error with Option & " requires a value";
            end if;
            return To_String (Arguments (Index));
         end if;
         raise Program_Error;
      end Take_Value;

      procedure Append
        (Values : in out String_Array;
         Count  : in out Natural;
         Value  : String;
         Option : String) is
      begin
         if Value'Length = 0 then
            raise Option_Error with Option & " requires a nonempty value";
         end if;
         if Count = Maximum_Cases then
            raise Option_Error with Option & " exceeds suite selector capacity";
         end if;
         Count := Count + 1;
         Values (Count) := To_Unbounded_String (Value);
      end Append;
   begin
      Result.Config := Base_Config;
      while Index <= Arguments'Last loop
         declare
            Argument : constant String := To_String (Arguments (Index));
         begin
            if Argument = "--help" or else Argument = "-h" then
               Saw_Help := True;
               Result.Requested_Action := Show_Help;
            elsif Argument = "--list" then
               Result.Requested_Action := List_Selected;
            elsif Starts_With (Argument, "--filter=")
              or else Argument = "--filter"
            then
               Append
                 (Result.Filters, Result.Filter_Count,
                  Take_Value ("--filter", Argument), "--filter");
            elsif Starts_With (Argument, "--skip=")
              or else Argument = "--skip"
            then
               Append
                 (Result.Skips, Result.Skip_Count,
                  Take_Value ("--skip", Argument), "--skip");
            elsif Starts_With (Argument, "--tag=")
              or else Argument = "--tag"
            then
               declare
                  Value : constant String := Take_Value ("--tag", Argument);
               begin
                  if not Valid_Segment (Value) then
                     raise Option_Error with "--tag requires an identity segment";
                  end if;
                  Append (Result.Tags, Result.Tag_Count, Value, "--tag");
               end;
            elsif Starts_With (Argument, "--exact=")
              or else Argument = "--exact"
            then
               if Length (Result.Exact) > 0 then
                  raise Option_Error with "--exact may be specified only once";
               end if;
               declare
                  Value : constant String := Take_Value ("--exact", Argument);
               begin
                  if Value'Length = 0 then
                     raise Option_Error with "--exact requires a value";
                  end if;
                  Result.Exact := To_Unbounded_String (Value);
               end;
            elsif Starts_With (Argument, "--group=")
              or else Argument = "--group"
            then
               if Length (Result.Group) > 0 then
                  raise Option_Error with "--group may be specified only once";
               end if;
               declare
                  Value : constant String := Take_Value ("--group", Argument);
               begin
                  if not Valid_Segment (Value) then
                     raise Option_Error with
                       "--group requires an identity segment";
                  end if;
                  Result.Group := To_Unbounded_String (Value);
               end;
            elsif Starts_With (Argument, "--order=")
              or else Argument = "--order"
            then
               declare
                  Value : constant String := Take_Value ("--order", Argument);
               begin
                  if Value = "registration" then
                     Result.Order := Registration_Order;
                  elsif Value = "name" then
                     Result.Order := Name_Order;
                  else
                     raise Option_Error with
                       "--order must be registration or name";
                  end if;
               end;
            elsif Starts_With (Argument, "--output-style=")
              or else Argument = "--output-style"
            then
               declare
                  Value : constant String :=
                    Take_Value ("--output-style", Argument);
               begin
                  if Value = "human" then
                     Result.Output_Format := Human;
                  elsif Value = "csv" then
                     Result.Output_Format := CSV;
                  elsif Value = "json" then
                     Result.Output_Format := JSON;
                  else
                     raise Option_Error with
                       "--output-style must be human, csv, or json";
                  end if;
               end;
            elsif Starts_With (Argument, "--output=")
              or else Argument = "--output"
            then
               if Length (Result.Path) > 0 then
                  raise Option_Error with "--output may be specified only once";
               end if;
               declare
                  Value : constant String := Take_Value ("--output", Argument);
               begin
                  if Value'Length = 0 then
                     raise Option_Error with "--output requires a nonempty path";
                  end if;
                  Result.Path := To_Unbounded_String (Value);
               end;
            elsif Starts_With (Argument, "--warmup=")
              or else Argument = "--warmup"
            then
               Result.Config.Warmup_Time := Nonnegative_Duration
                 (Parse_Duration
                    (Take_Value ("--warmup", Argument), "--warmup", False));
            elsif Starts_With (Argument, "--measurement-time=")
              or else Argument = "--measurement-time"
            then
               Result.Config.Measurement_Time := Positive_Duration
                 (Parse_Duration
                    (Take_Value ("--measurement-time", Argument),
                     "--measurement-time", True));
            elsif Starts_With (Argument, "--maximum-sampling-time=")
              or else Argument = "--maximum-sampling-time"
            then
               Result.Config.Maximum_Sampling_Time := Nonnegative_Duration
                 (Parse_Duration
                    (Take_Value ("--maximum-sampling-time", Argument),
                     "--maximum-sampling-time", False));
            elsif Starts_With (Argument, "--samples=")
              or else Argument = "--samples"
            then
               Result.Config.Samples :=
                 Parse_Count (Take_Value ("--samples", Argument), "--samples");
            elsif Starts_With (Argument, "--minimum-sample-time=")
              or else Argument = "--minimum-sample-time"
            then
               Result.Config.Minimum_Sample_Time := Positive_Duration
                 (Parse_Duration
                    (Take_Value ("--minimum-sample-time", Argument),
                     "--minimum-sample-time", True));
            elsif Starts_With (Argument, "--practical-threshold=")
              or else Argument = "--practical-threshold"
            then
               Result.Config.Practical_Threshold_Percent :=
                 Parse_Threshold
                   (Take_Value ("--practical-threshold", Argument),
                    "--practical-threshold");
            elsif Starts_With (Argument, "--random-seed=")
              or else Argument = "--random-seed"
            then
               Result.Config.Random_Seed :=
                 Parse_Seed
                   (Take_Value ("--random-seed", Argument), "--random-seed");
            elsif Argument = "--dry-run" then
               Result.Dry := True;
            elsif Argument = "--fail-fast" then
               Saw_Fail_Fast := True;
               Result.Errors := Fail_Fast;
            elsif Argument = "--continue-on-error" then
               Saw_Continue := True;
               Result.Errors := Continue_After_Error;
            elsif Argument = "--allow-empty" then
               Result.Allow_Empty := True;
            elsif Argument = "--require-metrics" then
               Result.Require_Metrics := True;
            else
               raise Option_Error with "unknown benchmark option: " & Argument;
            end if;
         end;
         Index := Index + 1;
      end loop;

      if Saw_Help and then Arguments'Length /= 1
      then
         raise Option_Error with "--help cannot be combined with other options";
      end if;
      if Result.Requested_Action = List_Selected and then Result.Dry then
         raise Option_Error with "--list and --dry-run cannot be combined";
      end if;
      if Saw_Fail_Fast and then Saw_Continue then
         raise Option_Error with
           "--fail-fast and --continue-on-error cannot be combined";
      end if;
      if Length (Result.Exact) > 0
        and then (Result.Filter_Count > 0
                  or else Length (Result.Group) > 0
                  or else Result.Tag_Count > 0)
      then
         raise Option_Error with
           "--exact cannot be combined with --filter, --group, or --tag";
      end if;
      return Result;
   end Parse;

   function Parse_Command_Line
     (Base_Config : Configuration := Default_Configuration)
      return Runner_Options
   is
      Arguments : Argument_List (1 .. Ada.Command_Line.Argument_Count);
   begin
      for Index in Arguments'Range loop
         Arguments (Index) :=
           To_Unbounded_String (Ada.Command_Line.Argument (Index));
      end loop;
      return Parse (Arguments, Base_Config);
   end Parse_Command_Line;

   function Action (Options : Runner_Options) return Runner_Action is
     (Options.Requested_Action);

   function Effective_Configuration
     (Options : Runner_Options) return Configuration is (Options.Config);

   function Format (Options : Runner_Options) return Output_Style is
     (Options.Output_Format);

   function Output_Path (Options : Runner_Options) return String is
     (To_String (Options.Path));

   function Is_Dry_Run (Options : Runner_Options) return Boolean is
     (Options.Dry);

   function Glob_Match (Pattern, Value : String) return Boolean is
      Pattern_Index : Integer := Pattern'First;
      Value_Index   : Integer := Value'First;
      Star          : Integer := Pattern'First - 1;
      Retry         : Integer := Value'First;
   begin
      while Value_Index <= Value'Last loop
         if Pattern_Index <= Pattern'Last
           and then (Pattern (Pattern_Index) = '?'
                     or else Pattern (Pattern_Index) = Value (Value_Index))
         then
            Pattern_Index := Pattern_Index + 1;
            Value_Index := Value_Index + 1;
         elsif Pattern_Index <= Pattern'Last
           and then Pattern (Pattern_Index) = '*'
         then
            Star := Pattern_Index;
            Pattern_Index := Pattern_Index + 1;
            Retry := Value_Index;
         elsif Star >= Pattern'First then
            Pattern_Index := Star + 1;
            Retry := Retry + 1;
            Value_Index := Retry;
         else
            return False;
         end if;
      end loop;
      while Pattern_Index <= Pattern'Last
        and then Pattern (Pattern_Index) = '*'
      loop
         Pattern_Index := Pattern_Index + 1;
      end loop;
      return Pattern_Index > Pattern'Last;
   end Glob_Match;

   function Pattern_Match (Pattern, Value : String) return Boolean is
   begin
      if Ada.Strings.Fixed.Index (Pattern, "*") = 0
        and then Ada.Strings.Fixed.Index (Pattern, "?") = 0
      then
         return Ada.Strings.Fixed.Index (Value, Pattern) /= 0;
      end if;
      return Glob_Match (Pattern, Value);
   end Pattern_Match;

   function Has_Tag (Tags, Wanted : String) return Boolean is
      First : Integer := Tags'First;
   begin
      if Tags'Length = 0 then
         return False;
      end if;
      for Index in Tags'Range loop
         if Tags (Index) = ',' then
            if Tags (First .. Index - 1) = Wanted then
               return True;
            end if;
            First := Index + 1;
         end if;
      end loop;
      return Tags (First .. Tags'Last) = Wanted;
   end Has_Tag;

   function Is_Selected
     (Target  : Suite;
      Options : Runner_Options;
      Index   : Case_Index) return Boolean
   is
      Item : Descriptor renames Target.Cases (Index);
      Full : constant String := To_String (Item.Full);
      Any_Filter : Boolean := Options.Filter_Count = 0;
   begin
      Check_Index (Target, Index);
      if Length (Options.Exact) > 0
        and then Full /= To_String (Options.Exact)
      then
         return False;
      end if;
      if Length (Options.Group) > 0
        and then To_String (Item.Group) /= To_String (Options.Group)
      then
         return False;
      end if;
      for Filter_Index in 1 .. Options.Filter_Count loop
         Any_Filter := Any_Filter or else Pattern_Match
           (To_String (Options.Filters (Filter_Index)), Full);
      end loop;
      if not Any_Filter then
         return False;
      end if;
      for Tag_Index in 1 .. Options.Tag_Count loop
         if not Has_Tag
           (To_String (Item.Tags), To_String (Options.Tags (Tag_Index)))
         then
            return False;
         end if;
      end loop;
      for Skip_Index in 1 .. Options.Skip_Count loop
         if Pattern_Match (To_String (Options.Skips (Skip_Index)), Full) then
            return False;
         end if;
      end loop;
      return True;
   end Is_Selected;

   procedure Selected_Indices
     (Target  : Suite;
      Options : Runner_Options;
      Values  : out Index_Array;
      Count   : out Natural)
   is
   begin
      Count := 0;
      for Index in 1 .. Target.Count loop
         if Is_Selected (Target, Options, Index) then
            Count := Count + 1;
            Values (Count) := Index;
         end if;
      end loop;
      if Options.Order = Name_Order then
         for Position in 2 .. Count loop
            declare
               Value : constant Case_Index := Values (Position);
               Place : Positive := Position;
            begin
               while Place > 1
                 and then To_String (Target.Cases (Values (Place - 1)).Full)
                          > To_String (Target.Cases (Value).Full)
               loop
                  Values (Place) := Values (Place - 1);
                  Place := Place - 1;
               end loop;
               Values (Place) := Value;
            end;
         end loop;
      end if;
   end Selected_Indices;

   function Successful (Summary : Run_Summary) return Boolean is
     (Summary.Status = Succeeded);

   procedure Initialize_Summary
     (Target   : Suite;
      Options  : Runner_Options;
      Selected : Natural;
      Summary  : out Run_Summary) is
   begin
      Summary :=
        (Discovered => Target.Count,
         Selected   => Selected,
         Skipped    => Target.Count - Selected,
         Dry_Run    => Options.Dry,
         others     => <>);
      if Selected = 0 and then not Options.Allow_Empty then
         Summary.Status := No_Matching_Cases;
      end if;
   end Initialize_Summary;

   procedure List
     (Target  : Suite;
      Options : Runner_Options;
      Summary : out Run_Summary;
      Output  : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output)
   is
      Values : Index_Array;
      Count  : Natural;
   begin
      Selected_Indices (Target, Options, Values, Count);
      Initialize_Summary (Target, Options, Count, Summary);
      for Position in 1 .. Count loop
         Ada.Text_IO.Put_Line
           (Output, To_String (Target.Cases (Values (Position)).Full));
      end loop;
   end List;

   function CSV_String (Value : String) return String is
      Quoted : Boolean := False;
   begin
      for Character of Value loop
         Quoted := Quoted
           or else Character = ',' or else Character = '"'
           or else Character = ASCII.LF or else Character = ASCII.CR;
      end loop;
      if not Quoted then
         return Value;
      end if;
      declare
         Result : Unbounded_String := To_Unbounded_String ("""");
      begin
         for Character of Value loop
            if Character = '"' then
               Append (Result, """""");
            else
               Append (Result, Character);
            end if;
         end loop;
         Append (Result, '"');
         return To_String (Result);
      end;
   end CSV_String;

   function Hex (Value : Natural) return Character is
     (if Value < 10 then Character'Val (Character'Pos ('0') + Value)
      else Character'Val (Character'Pos ('a') + Value - 10));

   function JSON_String (Value : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("""");
      Code   : Natural;
   begin
      for Character of Value loop
         case Character is
            when '"' =>
               Append (Result, '\');
               Append (Result, '"');
            when '\' =>
               Append (Result, '\');
               Append (Result, '\');
            when ASCII.LF => Append (Result, "\n");
            when ASCII.CR => Append (Result, "\r");
            when ASCII.HT => Append (Result, "\t");
            when others =>
               Code := Standard.Character'Pos (Character);
               if Code < 32 then
                  Append (Result, "\u00");
                  Append (Result, Hex (Code / 16));
                  Append (Result, Hex (Code mod 16));
               else
                  Append (Result, Character);
               end if;
         end case;
      end loop;
      Append (Result, '"');
      return To_String (Result);
   end JSON_String;

   function Outcome_Name (Outcome : Case_Outcome) return String is
     (case Outcome is
         when Completed_Outcome    => "completed",
         when Dry_Run_Outcome      => "dry_run",
         when Inconclusive_Outcome => "inconclusive",
         when Unavailable_Outcome  => "unavailable",
         when Failed_Outcome       => "failed");

   procedure Put_Machine_Header (File : Ada.Text_IO.File_Type) is
   begin
      Ada.Text_IO.Put_Line
        (File,
         "suite,benchmark,result_kind,outcome,dry_run,median_ns,mean_ns,"
         & "confidence_low_ns,confidence_high_ns,relative_change_percent,"
         & "change_low_percent,change_high_percent,verdict,detail");
   end Put_Machine_Header;

   procedure Put_Machine
     (File       : Ada.Text_IO.File_Type;
      Style      : Output_Style;
      Suite_Name : String;
      Case_Name  : String;
      Kind       : Result_Kind;
      Outcome    : Case_Outcome;
      Dry         : Boolean;
      Median      : String := "";
      Mean        : String := "";
      Low         : String := "";
      High        : String := "";
      Change      : String := "";
      Change_Low  : String := "";
      Change_High : String := "";
      Verdict     : String := "";
      Detail      : String := "") is
   begin
      if Style = CSV then
         Put_Machine_Header (File);
         Ada.Text_IO.Put_Line
           (File,
            CSV_String (Suite_Name) & ',' & CSV_String (Case_Name) & ','
            & Lower (Result_Kind'Image (Kind)) & ',' & Outcome_Name (Outcome)
            & ',' & Lower (Boolean'Image (Dry)) & ',' & Median & ',' & Mean
            & ',' & Low & ',' & High & ',' & Change & ',' & Change_Low & ','
            & Change_High & ',' & Verdict & ',' & CSV_String (Detail));
      else
         Ada.Text_IO.Put_Line
           (File,
            "{""suite"":" & JSON_String (Suite_Name)
            & ",""benchmark"":" & JSON_String (Case_Name)
            & ",""result_kind"":"
            & JSON_String (Lower (Result_Kind'Image (Kind)))
            & ",""outcome"":" & JSON_String (Outcome_Name (Outcome))
            & ",""dry_run"":" & Lower (Boolean'Image (Dry))
            & ",""median_ns"":" & (if Median = "" then "null" else Median)
            & ",""mean_ns"":" & (if Mean = "" then "null" else Mean)
            & ",""confidence_low_ns"":"
            & (if Low = "" then "null" else Low)
            & ",""confidence_high_ns"":"
            & (if High = "" then "null" else High)
            & ",""relative_change_percent"":"
            & (if Change = "" then "null" else Change)
            & ",""change_low_percent"":"
            & (if Change_Low = "" then "null" else Change_Low)
            & ",""change_high_percent"":"
            & (if Change_High = "" then "null" else Change_High)
            & ",""verdict"":"
            & (if Verdict = "" then "null" else JSON_String (Verdict))
            & ",""detail"":" & JSON_String (Detail) & "}");
      end if;
   end Put_Machine;

   function Has_Unavailable
     (Result : Measurement;
      Config : Configuration) return Boolean is
   begin
      for Axis in Metric_Axis loop
         if Config.Metrics (Axis)
           and then Metric_Status (Result, Axis) /= Metric_Collected
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Unavailable;

   function Dry_Configuration (Base : Configuration) return Configuration is
     (Base with delta
        Warmup_Time => 0.0,
        Measurement_Time => 0.000_010,
        Maximum_Sampling_Time => 0.010,
        Samples => Sample_Count'First,
        Minimum_Sample_Time => 0.000_001,
        Maximum_Iterations => 1_000,
        Subtract_Timer_Cost => False,
        Metrics => Time_Metrics,
        Scheduler_Probe => null,
        CPU_Quiescence => (Enabled => False),
        Interference => (Enabled => False, Response => Observe),
        Placement => (Enabled => False),
        Host_Lock => (Enabled => False),
        Collect_Process_Telemetry => False,
        Progress => null);

   function Execution_Configuration
     (Options : Runner_Options) return Configuration is
     (if Options.Dry then Dry_Configuration (Options.Config)
      elsif Options.Output_Format /= Human then
        (Options.Config with delta Progress => null)
      else Options.Config);

   function Multi_Inconclusive (Result : Multi_Comparison) return Boolean is
   begin
      for Index in Comparison_Case_Index range 2 .. Cases (Result) loop
         if Verdict (Versus_Reference (Result, Index)) = Inconclusive then
            return True;
         end if;
      end loop;
      return False;
   end Multi_Inconclusive;

   function Multi_Has_Unavailable
     (Result : Multi_Comparison;
      Config : Configuration) return Boolean is
   begin
      for Index in Comparison_Case_Index range 1 .. Cases (Result) loop
         if Has_Unavailable (Case_Measurement (Result, Index), Config) then
            return True;
         end if;
      end loop;
      return False;
   end Multi_Has_Unavailable;

   function Machine_Context
     (Suite_Name : String;
      Case_Name  : String;
      Kind       : Result_Kind;
      Outcome    : Case_Outcome;
      Dry         : Boolean := False)
      return Flyology_Bench.Reporters.Machine_Context is
     (Flyology_Bench.Reporters.Make_Machine_Context
        (Suite_Name, Case_Name, Lower (Result_Kind'Image (Kind)),
         Outcome_Name (Outcome), Dry));

   procedure Put_Measurement_Machine
     (File       : Ada.Text_IO.File_Type;
      Style      : Output_Style;
      Suite_Name : String;
      Case_Name  : String;
      Outcome    : Case_Outcome;
      Result     : Measurement)
   is
      Context : constant Flyology_Bench.Reporters.Machine_Context :=
        Machine_Context
          (Suite_Name, Case_Name, Ordinary_Measurement, Outcome);
   begin
      if Style = CSV then
         Flyology_Bench.Reporters.Put_CSV_Header (File, Context);
         Flyology_Bench.Reporters.Put_CSV (Case_Name, Result, File, Context);
         Flyology_Bench.Reporters.Put_Metrics_CSV_Header (File, Context);
         Flyology_Bench.Reporters.Put_Metrics_CSV
           (Case_Name, Result, File, Context);
      else
         Flyology_Bench.Reporters.Put_JSON
           (Case_Name, Result, File, Context);
      end if;
   end Put_Measurement_Machine;

   procedure Put_Comparison_Machine
     (File           : Ada.Text_IO.File_Type;
      Style          : Output_Style;
      Suite_Name     : String;
      Case_Name      : String;
      Outcome        : Case_Outcome;
      Reference_Name : String;
      Contender_Name : String;
      Result         : Comparison)
   is
      Context : constant Flyology_Bench.Reporters.Machine_Context :=
        Machine_Context
          (Suite_Name, Case_Name, Paired_Comparison, Outcome);
   begin
      if Style = CSV then
         Flyology_Bench.Reporters.Put_Comparison_CSV_Header (File, Context);
         Flyology_Bench.Reporters.Put_Comparison_CSV
           (Reference_Name, Contender_Name, Result, File, Context);
         Flyology_Bench.Reporters.Put_Comparison_Metrics_CSV_Header
           (File, Context);
         Flyology_Bench.Reporters.Put_Comparison_Metrics_CSV
           (Reference_Name, Contender_Name, Result, File, Context);
      else
         Flyology_Bench.Reporters.Put_Comparison_JSON
           (Reference_Name, Contender_Name, Result, File, Context);
      end if;
   end Put_Comparison_Machine;

   procedure Put_Summary
     (File       : Ada.Text_IO.File_Type;
      Suite_Name : String;
      Style      : Output_Style;
      Summary    : Run_Summary)
   is
      Detail : constant String :=
        "discovered=" & Image (Summary.Discovered)
        & " selected=" & Image (Summary.Selected)
        & " completed=" & Image (Summary.Completed)
        & " skipped=" & Image (Summary.Skipped)
        & " failed=" & Image (Summary.Failed)
        & " inconclusive=" & Image (Summary.Inconclusive)
        & " unavailable=" & Image (Summary.Unavailable)
        & " rejected=" & Image (Summary.Rejected);
   begin
      if Style = Human then
         Ada.Text_IO.Put_Line
           (File,
            "suite " & Suite_Name & ": " & Detail & " status="
            & Lower (Final_Status'Image (Summary.Status)));
      elsif Style = CSV then
         Put_Machine_Header (File);
         Ada.Text_IO.Put_Line
           (File,
            CSV_String (Suite_Name) & ",,summary,"
            & (if Successful (Summary) then "completed" else "failed")
            & ',' & Lower (Boolean'Image (Summary.Dry_Run))
            & ",,,,,,,,," & CSV_String (Detail));
      else
         Ada.Text_IO.Put_Line
           (File,
            "{""suite"":" & JSON_String (Suite_Name)
            & ",""benchmark"":null,""result_kind"":""summary"",""outcome"":"
            & JSON_String
                ((if Successful (Summary) then "completed" else "failed"))
            & ",""dry_run"":" & Lower (Boolean'Image (Summary.Dry_Run))
            & ",""discovered"":" & Image (Summary.Discovered)
            & ",""selected"":" & Image (Summary.Selected)
            & ",""completed"":" & Image (Summary.Completed)
            & ",""skipped"":" & Image (Summary.Skipped)
            & ",""failed"":" & Image (Summary.Failed)
            & ",""inconclusive"":" & Image (Summary.Inconclusive)
            & ",""unavailable"":" & Image (Summary.Unavailable)
            & ",""rejected"":" & Image (Summary.Rejected)
            & ",""status"":"
            & JSON_String (Lower (Final_Status'Image (Summary.Status))) & "}");
      end if;
   end Put_Summary;

   procedure Execute
     (Target     : Suite;
      Suite_Name : String;
      Options    : Runner_Options;
      Summary    : out Run_Summary;
      Output     : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Progress   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Error)
   is
      Values : Index_Array;
      Count  : Natural;

      procedure Run_To (File : Ada.Text_IO.File_Type) is
         Config : constant Configuration := Execution_Configuration (Options);
         Stop : Boolean := False;

         procedure Report_Callback_Failure
           (Name  : String;
            Kind  : Result_Kind;
            Error : Ada.Exceptions.Exception_Occurrence)
         is
            Detail : constant String :=
              Ada.Exceptions.Exception_Name (Error) & ": "
              & Ada.Exceptions.Exception_Message (Error);
         begin
            Summary.Failed := Summary.Failed + 1;
            if Options.Output_Format = Human then
               Ada.Text_IO.Put_Line
                 (File, "case " & Name & ": failed: " & Detail);
            else
               Put_Machine
                 (File, Options.Output_Format, Suite_Name, Name, Kind,
                  Failed_Outcome, Options.Dry, Detail => Detail);
            end if;
            Ada.Text_IO.Put_Line
              (Progress, "benchmark " & Name & " failed: " & Detail);
            Stop := Options.Errors = Fail_Fast;
         end Report_Callback_Failure;
      begin
         if Options.Requested_Action = Show_Help then
            Summary := (others => <>);
            Put_Help (File);
            return;
         elsif Options.Requested_Action = List_Selected then
            List (Target, Options, Summary, File);
            if Summary.Selected = 0 and then not Options.Allow_Empty then
               Ada.Text_IO.Put_Line
                 (Progress, "no benchmark cases matched the selection");
            end if;
            return;
         end if;

         Initialize_Summary (Target, Options, Count, Summary);
         if Options.Output_Format = Human then
            Ada.Text_IO.Put_Line
              (File,
               "suite " & Suite_Name & ": selected " & Image (Count)
               & " of " & Image (Target.Count)
               & (if Options.Dry then " [DRY RUN]" else ""));
         end if;

         if Count = 0 then
            Put_Summary (File, Suite_Name, Options.Output_Format, Summary);
            if not Options.Allow_Empty then
               Ada.Text_IO.Put_Line
                 (Progress, "no benchmark cases matched the selection");
            end if;
            return;
         end if;

         for Position in 1 .. Count loop
            exit when Stop;
            declare
               Index : constant Case_Index := Values (Position);
               Item  : Descriptor renames Target.Cases (Index);
               Name  : constant String := To_String (Item.Full);
            begin
               Ada.Text_IO.Put_Line
                 (Progress,
                  "running " & Name
                  & (if Options.Dry then " [DRY RUN]" else ""));
               case Item.Result is
                  when Ordinary_Measurement =>
                     declare
                        Result  : Measurement;
                        Outcome : Case_Outcome := Completed_Outcome;
                        Returned : Boolean := False;
                     begin
                        begin
                           Item.Measurement_Run (Config, Result);
                           Returned := True;
                        exception
                           when Error : others =>
                              Report_Callback_Failure
                                (Name, Item.Result, Error);
                        end;
                        if Returned then
                           Summary.Completed := Summary.Completed + 1;
                           if Options.Dry then
                              Outcome := Dry_Run_Outcome;
                           elsif Options.Require_Metrics
                             and then Has_Unavailable (Result, Config)
                           then
                              Outcome := Unavailable_Outcome;
                              Summary.Unavailable := Summary.Unavailable + 1;
                           end if;
                           if Options.Output_Format = Human then
                              Ada.Text_IO.Put_Line
                                (File, "case " & Name & ": "
                                 & Outcome_Name (Outcome));
                              if not Options.Dry then
                                 Flyology_Bench.Reporters.Put_Console
                                   (Name, Result, File,
                                    Style => Flyology_Bench.Reporters.Plain);
                              end if;
                           elsif Options.Dry then
                              Put_Machine
                                (File, Options.Output_Format, Suite_Name, Name,
                                 Item.Result, Outcome, True,
                                 Detail =>
                                   "validation only; not performance data");
                           else
                              Put_Measurement_Machine
                                (File, Options.Output_Format, Suite_Name, Name,
                                 Outcome, Result);
                           end if;
                        end if;
                     end;

                  when Paired_Comparison =>
                     declare
                        Result  : Comparison;
                        Outcome : Case_Outcome := Completed_Outcome;
                        Reference : Measurement;
                        Contender : Measurement;
                        Returned : Boolean := False;
                     begin
                        begin
                           Item.Comparison_Run (Config, Result);
                           Returned := True;
                        exception
                           when Error : others =>
                              Report_Callback_Failure
                                (Name, Item.Result, Error);
                        end;
                        if Returned then
                           Summary.Completed := Summary.Completed + 1;
                           Reference := Reference_Measurement (Result);
                           Contender := Contender_Measurement (Result);
                           if Options.Dry then
                              Outcome := Dry_Run_Outcome;
                           else
                              if Verdict (Result) = Inconclusive then
                                 Outcome := Inconclusive_Outcome;
                                 Summary.Inconclusive :=
                                   Summary.Inconclusive + 1;
                              end if;
                              if Options.Require_Metrics
                                and then
                                  (Has_Unavailable (Reference, Config)
                                   or else Has_Unavailable (Contender, Config))
                              then
                                 Outcome := Unavailable_Outcome;
                                 Summary.Unavailable := Summary.Unavailable + 1;
                              end if;
                           end if;
                           if Options.Output_Format = Human then
                              Ada.Text_IO.Put_Line
                                (File, "case " & Name & ": "
                                 & Outcome_Name (Outcome));
                              if not Options.Dry then
                                 Flyology_Bench.Reporters.Put_Comparison_Console
                                   (To_String (Item.Reference_Name),
                                    To_String (Item.Contender_Name), Result,
                                    File,
                                    Style => Flyology_Bench.Reporters.Plain);
                              end if;
                           elsif Options.Dry then
                              Put_Machine
                                (File, Options.Output_Format, Suite_Name, Name,
                                 Item.Result, Outcome, True,
                                 Detail =>
                                   "validation only; not performance data");
                           else
                              Put_Comparison_Machine
                                (File, Options.Output_Format, Suite_Name, Name,
                                 Outcome, To_String (Item.Reference_Name),
                                 To_String (Item.Contender_Name), Result);
                           end if;
                        end if;
                     end;

                  when Multi_Way_Comparison =>
                     declare
                        Result   : Multi_Comparison;
                        Outcome  : Case_Outcome := Completed_Outcome;
                        Returned : Boolean := False;
                     begin
                        begin
                           Item.Multi_Run (Config, Result);
                           Returned := True;
                        exception
                           when Error : others =>
                              Report_Callback_Failure
                                (Name, Item.Result, Error);
                        end;
                        if Returned then
                           Summary.Completed := Summary.Completed + 1;
                           if Options.Dry then
                              Outcome := Dry_Run_Outcome;
                           else
                              if Multi_Inconclusive (Result) then
                                 Outcome := Inconclusive_Outcome;
                                 Summary.Inconclusive :=
                                   Summary.Inconclusive + 1;
                              end if;
                              if Options.Require_Metrics
                                and then Multi_Has_Unavailable (Result, Config)
                              then
                                 Outcome := Unavailable_Outcome;
                                 Summary.Unavailable := Summary.Unavailable + 1;
                              end if;
                           end if;
                           if Options.Output_Format = Human then
                              Ada.Text_IO.Put_Line
                                (File, "case " & Name & ": "
                                 & Outcome_Name (Outcome));
                              if not Options.Dry then
                                 Item.Multi_Console (Result, File);
                              end if;
                           elsif Options.Dry then
                              Put_Machine
                                (File, Options.Output_Format, Suite_Name, Name,
                                 Item.Result, Outcome, True,
                                 Detail =>
                                   "validation only; not performance data");
                           else
                              declare
                                 Context : constant
                                   Flyology_Bench.Reporters.Machine_Context :=
                                     Machine_Context
                                       (Suite_Name, Name, Item.Result, Outcome);
                              begin
                                 if Options.Output_Format = CSV then
                                    Flyology_Bench.Reporters
                                      .Put_Multi_Comparison_CSV_Header
                                        (File, Context);
                                    Item.Multi_CSV (Result, File, Context);
                                 else
                                    Item.Multi_JSON (Result, File, Context);
                                 end if;
                              end;
                           end if;
                        end if;
                     end;
               end case;
            end;
         end loop;

         if Stop then
            Summary.Skipped :=
              Summary.Skipped + Count - Summary.Completed - Summary.Failed;
         end if;
         if Summary.Rejected > 0 then
            Summary.Status := Regression_Rejected;
         elsif Summary.Failed > 0 then
            Summary.Status := Benchmark_Failed;
         elsif Summary.Unavailable > 0 then
            Summary.Status := Requested_Metric_Unavailable;
         end if;
         Put_Summary (File, Suite_Name, Options.Output_Format, Summary);
      end Run_To;

      File : Ada.Text_IO.File_Type;
   begin
      if not Valid_Segment (Suite_Name) then
         raise Constraint_Error with "invalid suite name: " & Suite_Name;
      end if;
      Selected_Indices (Target, Options, Values, Count);
      if Length (Options.Path) = 0 then
         Run_To (Output);
      else
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, To_String (Options.Path));
         begin
            Run_To (File);
            Ada.Text_IO.Close (File);
         exception
            when others =>
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
               raise;
         end;
      end if;
   end Execute;

   procedure Put_Help
     (Output : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output) is
   begin
      Ada.Text_IO.Put_Line (Output, "Flyology_Bench suite options:");
      Ada.Text_IO.Put_Line (Output, "  --list                      list selected identities");
      Ada.Text_IO.Put_Line (Output, "  --exact NAME                select one full identity");
      Ada.Text_IO.Put_Line (Output, "  --filter PATTERN            substring or *,? glob on identity");
      Ada.Text_IO.Put_Line (Output, "  --skip PATTERN              exclude matching identities");
      Ada.Text_IO.Put_Line (Output, "  --group GROUP               select an exact group");
      Ada.Text_IO.Put_Line (Output, "  --tag TAG                   require a tag (repeatable)");
      Ada.Text_IO.Put_Line (Output, "  --order registration|name   deterministic execution order");
      Ada.Text_IO.Put_Line (Output, "  --warmup DURATION           override warmup");
      Ada.Text_IO.Put_Line (Output, "  --measurement-time DURATION override measurement budget");
      Ada.Text_IO.Put_Line (Output, "  --maximum-sampling-time DURATION 0 disables the cap");
      Ada.Text_IO.Put_Line (Output, "  --samples 10..1000          override sample count");
      Ada.Text_IO.Put_Line (Output, "  --minimum-sample-time DURATION   calibration floor");
      Ada.Text_IO.Put_Line (Output, "  --practical-threshold PERCENT    0 <= value < 100");
      Ada.Text_IO.Put_Line (Output, "  --random-seed INTEGER       deterministic random seed");
      Ada.Text_IO.Put_Line (Output, "  --output-style human|csv|json");
      Ada.Text_IO.Put_Line (Output, "  --output PATH               write results without progress/ANSI");
      Ada.Text_IO.Put_Line (Output, "  --dry-run                   validate callbacks; numbers are invalid");
      Ada.Text_IO.Put_Line (Output, "  --fail-fast | --continue-on-error");
      Ada.Text_IO.Put_Line (Output, "  --require-metrics           fail on unavailable requested axes");
      Ada.Text_IO.Put_Line (Output, "  --allow-empty               make no-match successful");
      Ada.Text_IO.Put_Line (Output, "  --help                      show this help");
      Ada.Text_IO.Put_Line
        (Output, "Durations are strict decimal values with ns, us, ms, or s.");
   end Put_Help;
end Flyology_Bench.Suites;
