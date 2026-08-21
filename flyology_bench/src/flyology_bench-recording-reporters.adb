--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Characters.Handling;
with Ada.Environment_Variables;
with Ada.Strings;
with Ada.Strings.Fixed;
with Interfaces.C;

package body Flyology_Bench.Recording.Reporters is
   package Float_IO is new Ada.Text_IO.Float_IO (Long_Float);
   use type Interfaces.C.int;
   use type Flyology_Bench.Reporters.Console_Style;

   ESC     : constant Character := Character'Val (27);
   Reset   : constant String := ESC & "[0m";
   Bold    : constant String := ESC & "[1m";
   Dim     : constant String := ESC & "[2m";
   Cyan    : constant String := ESC & "[36m";
   Green   : constant String := ESC & "[32m";
   Yellow  : constant String := ESC & "[33m";
   Red     : constant String := ESC & "[31m";

   function Isatty (Descriptor : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, Isatty, "isatty");

   function Terminal_ANSI return Boolean is
     (Isatty (Interfaces.C.int (1)) = 1
      and then not Ada.Environment_Variables.Exists ("NO_COLOR")
      and then
        (not Ada.Environment_Variables.Exists ("TERM")
         or else Ada.Environment_Variables.Value ("TERM") /= "dumb"));

   function Styled (Style : Console_Style) return Boolean is
     (Style = ANSI or else (Style = Auto and then Terminal_ANSI));

   function Image (Value : Long_Float; Aft : Natural := 3) return String is
      Buffer : String (1 .. 64);
   begin
      Float_IO.Put
        (Buffer, Value, Aft => Aft,
         Exp => (if abs Value >= 1.0E+40 then 4 else 0));
      return Ada.Strings.Fixed.Trim (Buffer, Ada.Strings.Both);
   end Image;

   function Natural_Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Boolean_Image (Value : Boolean) return String is
     (if Value then "true" else "false");

   function Duration_Image (Value : Duration) return String is
     (Image (Long_Float (Value), 3) & " s");

   function Pad (Value : String; Width : Positive) return String is
      Result : String (1 .. Width) := (others => ' ');
      Count  : constant Natural := Natural'Min (Value'Length, Width);
   begin
      if Count > 0 then
         Result (1 .. Count) := Value (Value'First .. Value'First + Count - 1);
      end if;
      return Result;
   end Pad;

   function Left_Pad (Value : String; Width : Positive) return String is
      Result : String (1 .. Width) := (others => ' ');
      Count  : constant Natural := Natural'Min (Value'Length, Width);
   begin
      if Count > 0 then
         Result (Width - Count + 1 .. Width) :=
           Value (Value'Last - Count + 1 .. Value'Last);
      end if;
      return Result;
   end Left_Pad;

   function Metric_Status_Name (Value : Metric_Availability) return String is
   begin
      case Value is
         when Metric_Not_Requested => return "not_requested";
         when Metric_Collected => return "collected";
         when Unsupported_Platform => return "unsupported_platform";
         when Permission_Denied => return "permission_denied";
         when Unsupported_Event => return "unsupported_event";
         when Counter_Resources_Unavailable =>
            return "counter_resources_unavailable";
         when Probe_Failed => return "probe_failed";
         when Metric_Partially_Collected => return "partially_collected";
      end case;
   end Metric_Status_Name;

   function Attribution_Name (Value : Metric_Attribution) return String is
   begin
      case Value is
         when Exact_Window => return "exact_window";
         when Same_Native_Thread_Window => return "same_native_thread_window";
         when Native_Task_Tree_Window => return "native_task_tree_window";
         when Shared_Process_Window => return "shared_process_window";
         when Shared_Runtime_Window => return "shared_runtime_window";
         when Unattributable => return "unattributable";
      end case;
   end Attribution_Name;

   function Verdict_Name (Value : Comparison_Verdict) return String is
   begin
      case Value is
         when Inconclusive => return "inconclusive";
         when Practically_Equivalent => return "practically_equivalent";
         when Contender_Faster => return "contender_faster";
         when Reference_Faster => return "reference_faster";
      end case;
   end Verdict_Name;

   function Metric_Verdict_Name (Value : Metric_Verdict) return String is
   begin
      case Value is
         when Metric_Inconclusive => return "inconclusive";
         when Metric_Practically_Equivalent =>
            return "practically_equivalent";
         when Contender_Better => return "contender_better";
         when Reference_Better => return "reference_better";
         when Metric_Diagnostic => return "diagnostic";
      end case;
   end Metric_Verdict_Name;

   function Method_Name (Value : Metric_Comparison_Method) return String is
     (if Value = Relative_Ratio then "relative_ratio"
      else "absolute_difference");

   function Outcome_Name (Value : Sample_Outcome) return String is
     (Ada.Characters.Handling.To_Lower (Value'Image));

   function CSV_String (Value : String) return String is
      Quotes : Natural := 0;
   begin
      for Character of Value loop
         if Character = '"' then
            Quotes := Quotes + 1;
         end if;
      end loop;
      declare
         Result : String (1 .. Value'Length + Quotes + 2);
         Cursor : Natural := 1;
      begin
         Result (Cursor) := '"';
         Cursor := Cursor + 1;
         for Character of Value loop
            Result (Cursor) := Character;
            Cursor := Cursor + 1;
            if Character = '"' then
               Result (Cursor) := '"';
               Cursor := Cursor + 1;
            end if;
         end loop;
         Result (Cursor) := '"';
         return Result;
      end;
   end CSV_String;

   function JSON_String (Value : String) return String is
      Buffer : String (1 .. Value'Length * 6 + 2);
      Last   : Natural := 0;

      procedure Append (Character : Standard.Character) is
      begin
         Last := Last + 1;
         Buffer (Last) := Character;
      end Append;

      function Hex_Digit (Number : Natural) return Character is
        (if Number < 10
         then Character'Val (Character'Pos ('0') + Number)
         else Character'Val (Character'Pos ('A') + Number - 10));
   begin
      Append ('"');
      for Character of Value loop
         case Standard.Character'Pos (Character) is
            when 8 => Append ('\'); Append ('b');
            when 9 => Append ('\'); Append ('t');
            when 10 => Append ('\'); Append ('n');
            when 12 => Append ('\'); Append ('f');
            when 13 => Append ('\'); Append ('r');
            when 0 .. 7 | 11 | 14 .. 31 =>
               Append ('\');
               Append ('u');
               Append ('0');
               Append ('0');
               Append (Hex_Digit (Standard.Character'Pos (Character) / 16));
               Append (Hex_Digit (Standard.Character'Pos (Character) mod 16));
            when Standard.Character'Pos ('"')
               | Standard.Character'Pos ('\') =>
               Append ('\');
               Append (Character);
            when others =>
               Append (Character);
         end case;
      end loop;
      Append ('"');
      return Buffer (1 .. Last);
   end JSON_String;

   function Scope_Name (Value : Metric_Scope) return String is
   begin
      return Ada.Characters.Handling.To_Lower (Value'Image);
   end Scope_Name;

   procedure Put_Console
     (Result : Recorded_Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Style  : Console_Style := Auto)
   is
      Color : constant Boolean := Styled (Style);
   begin
      if Color then
         Ada.Text_IO.Put (File, Bold & Cyan);
      end if;
      Ada.Text_IO.Put_Line
        (File, "-- " & Name (Result) & " / recorded spans --");
      if Color then
         Ada.Text_IO.Put (File, Reset);
      end if;
      Ada.Text_IO.Put_Line
        (File,
         "session     | " & Duration_Image (Session_Elapsed (Result))
         & " wall time    individual spans, independent sampling");
      Ada.Text_IO.Put_Line
        (File,
         "statistics  | " & Image (Confidence_Level_Percent (Result))
         & "% confidence    " & Natural_Image (Bootstrap_Resamples (Result))
         & " bootstrap resamples");
      Ada.Text_IO.Put_Line
        (File,
         "observed    | " & Natural_Image (Observed (Result))
         & " finished    " & Natural_Image (Retained (Result))
         & " retained    " & Natural_Image (Dropped (Result)) & " omitted");
      Ada.Text_IO.Put_Line
        (File,
         "lifecycle   | " & Natural_Image (In_Flight (Result))
         & " in flight    " & Natural_Image (Abandoned (Result))
         & " abandoned    "
         & Natural_Image (Outcomes (Result, Failure)
           + Outcomes (Result, Timeout) + Outcomes (Result, Cancelled))
         & " errors");
      Ada.Text_IO.New_Line (File);
      if Color then
         Ada.Text_IO.Put (File, Dim);
      end if;
      Ada.Text_IO.Put_Line
        (File, Pad ("axis", 30) & " " & Pad ("attribution", 26)
         & " samples      median         p95        status");
      if Color then
         Ada.Text_IO.Put (File, Reset);
      end if;
      for Axis in Metric_Axis loop
         if Metric_Status (Result, Axis) /= Metric_Not_Requested then
            declare
               Summary : constant Metric_Summary :=
                 Metric_Statistics (Result, Axis);
               Status  : constant Metric_Availability :=
                 Metric_Status (Result, Axis);
            begin
               if Color then
                  Ada.Text_IO.Put
                    (File, (if Status = Metric_Collected then Green else Yellow));
               end if;
               Ada.Text_IO.Put
                 (File, Pad (Metric_Name (Axis), 30) & " "
                  & Pad (Attribution_Name (Attribution (Result, Axis)), 26)
                  & " " & Left_Pad (Natural_Image (Metric_Samples (Result, Axis)), 7)
                  & "  ");
               if Summary.Available then
                  Ada.Text_IO.Put
                    (File, Left_Pad (Image (Summary.Median), 12) & "  "
                     & Left_Pad (Image (Summary.P95), 12));
               else
                  Ada.Text_IO.Put (File, Pad ("-", 12) & "  " & Pad ("-", 12));
               end if;
               Ada.Text_IO.Put_Line
                 (File, "  " & Metric_Status_Name (Status)
                  & (if Scope_Changed_Samples (Result, Axis) > 0
                     then " (" & Natural_Image
                       (Scope_Changed_Samples (Result, Axis)) & " scope changed)"
                     else ""));
               if Color then
                  Ada.Text_IO.Put (File, Reset);
               end if;
            end;
         end if;
      end loop;
   end Put_Console;

   procedure Put_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output) is
   begin
      Ada.Text_IO.Put_Line
        (File, "name,sample_semantics,confidence_level_percent,"
         & "bootstrap_resamples,axis,scope,attribution,unit,status,"
         & "samples,unavailable_samples,scope_changed,min,median,mean,ci_low,"
         & "ci_high,p95,p99,max,"
         & "observed,retained,dropped,in_flight,abandoned,success,failure,"
         & "timeout,cancelled,session_elapsed_s");
   end Put_CSV_Header;

   procedure Put_CSV
     (Result : Recorded_Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output) is
   begin
      for Axis in Metric_Axis loop
         if Metric_Status (Result, Axis) /= Metric_Not_Requested then
            declare
               Summary : constant Metric_Summary :=
                 Metric_Statistics (Result, Axis);
               Values : constant String :=
                 (if Summary.Available
                  then Image (Summary.Minimum) & "," & Image (Summary.Median)
                    & "," & Image (Summary.Mean) & ","
                    & Image (Summary.Confidence_Low) & ","
                    & Image (Summary.Confidence_High) & ","
                    & Image (Summary.P95) & "," & Image (Summary.P99) & ","
                    & Image (Summary.Maximum)
                  else ",,,,,,,");
            begin
               Ada.Text_IO.Put_Line
                 (File, CSV_String (Name (Result)) & ",individual_span,"
                  & Image (Confidence_Level_Percent (Result)) & ","
                  & Natural_Image (Bootstrap_Resamples (Result)) & ","
                  & CSV_String (Metric_Name (Axis)) & ","
                  & CSV_String (Scope_Name (Scope (Axis))) & ","
                  & CSV_String (Attribution_Name (Attribution (Result, Axis)))
                  & "," & CSV_String (Metric_Unit (Axis)) & ","
                  & Metric_Status_Name (Metric_Status (Result, Axis)) & ","
                  & Natural_Image (Metric_Samples (Result, Axis)) & ","
                  & Natural_Image
                    (Unavailable_Metric_Samples (Result, Axis)) & ","
                  & Natural_Image (Scope_Changed_Samples (Result, Axis)) & ","
                  & Values & "," & Natural_Image (Observed (Result)) & ","
                  & Natural_Image (Retained (Result)) & ","
                  & Natural_Image (Dropped (Result)) & ","
                  & Natural_Image (In_Flight (Result)) & ","
                  & Natural_Image (Abandoned (Result)) & ","
                  & Natural_Image (Outcomes (Result, Success)) & ","
                  & Natural_Image (Outcomes (Result, Failure)) & ","
                  & Natural_Image (Outcomes (Result, Timeout)) & ","
                  & Natural_Image (Outcomes (Result, Cancelled)) & ","
                  & Image (Long_Float (Session_Elapsed (Result))));
            end;
         end if;
      end loop;
   end Put_CSV;

   procedure Put_Samples_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output) is
   begin
      Ada.Text_IO.Put_Line
        (File, "name,sample_semantics,observation,outcome,axis,scope,"
         & "attribution,unit,status,value");
   end Put_Samples_CSV_Header;

   procedure Put_Samples_CSV
     (Result : Recorded_Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output) is
   begin
      for Index in 1 .. Retained (Result) loop
         for Axis in Metric_Axis loop
            if Metric_Status (Result, Axis) /= Metric_Not_Requested then
               declare
                  Status : constant Metric_Availability :=
                    Sample_Metric_Status (Result, Index, Axis);
               begin
                  Ada.Text_IO.Put_Line
                    (File, CSV_String (Name (Result)) & ",individual_span,"
                     & Natural_Image (Observation_Id (Result, Index)) & ","
                     & Outcome_Name (Outcome_At (Result, Index)) & ","
                     & CSV_String (Metric_Name (Axis)) & ","
                     & CSV_String (Scope_Name (Scope (Axis))) & ","
                     & CSV_String
                       (Attribution_Name (Attribution (Result, Axis))) & ","
                     & CSV_String (Metric_Unit (Axis)) & ","
                     & Metric_Status_Name (Status) & ","
                     & (if Status = Metric_Collected
                        then Image (Sample_Metric_Value (Result, Index, Axis))
                        else ""));
               end;
            end if;
         end loop;
      end loop;
   end Put_Samples_CSV;

   procedure Put_JSON
     (Result : Recorded_Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output)
   is
      First : Boolean := True;
   begin
      Ada.Text_IO.Put
        (File, "{""name"":" & JSON_String (Name (Result))
         & ",""sample_semantics"":""individual_span"""
         & ",""observed"":" & Natural_Image (Observed (Result))
         & ",""retained"":" & Natural_Image (Retained (Result))
         & ",""statistics"":{""confidence_level_percent"":"
         & Image (Confidence_Level_Percent (Result))
         & ",""bootstrap_resamples"":"
         & Natural_Image (Bootstrap_Resamples (Result))
         & ",""bootstrap"":""independent""}"
         & ",""dropped"":" & Natural_Image (Dropped (Result))
         & ",""in_flight"":" & Natural_Image (In_Flight (Result))
         & ",""abandoned"":" & Natural_Image (Abandoned (Result))
         & ",""session_elapsed_s"":"
         & Image (Long_Float (Session_Elapsed (Result)))
         & ",""outcomes"":{""success"":"
         & Natural_Image (Outcomes (Result, Success))
         & ",""failure"":" & Natural_Image (Outcomes (Result, Failure))
         & ",""timeout"":" & Natural_Image (Outcomes (Result, Timeout))
         & ",""cancelled"":" & Natural_Image (Outcomes (Result, Cancelled))
         & "},""metrics"":[");
      for Axis in Metric_Axis loop
         if Metric_Status (Result, Axis) /= Metric_Not_Requested then
            if not First then
               Ada.Text_IO.Put (File, ",");
            end if;
            First := False;
            declare
               Summary : constant Metric_Summary :=
                 Metric_Statistics (Result, Axis);
            begin
               Ada.Text_IO.Put
                 (File, "{""axis"":" & JSON_String (Metric_Name (Axis))
                  & ",""scope"":" & JSON_String (Scope_Name (Scope (Axis)))
                  & ",""attribution"":"
                  & JSON_String (Attribution_Name (Attribution (Result, Axis)))
                  & ",""unit"":" & JSON_String (Metric_Unit (Axis))
                  & ",""status"":"
                  & JSON_String (Metric_Status_Name (Metric_Status (Result, Axis)))
                  & ",""samples"":"
                  & Natural_Image (Metric_Samples (Result, Axis))
                  & ",""unavailable_samples"":"
                  & Natural_Image (Unavailable_Metric_Samples (Result, Axis))
                  & ",""scope_changed"":"
                  & Natural_Image (Scope_Changed_Samples (Result, Axis)));
               if Summary.Available then
                  Ada.Text_IO.Put
                    (File, ",""summary"":{""min"":" & Image (Summary.Minimum)
                     & ",""median"":" & Image (Summary.Median)
                     & ",""mean"":" & Image (Summary.Mean)
                     & ",""ci_low"":" & Image (Summary.Confidence_Low)
                     & ",""ci_high"":" & Image (Summary.Confidence_High)
                     & ",""p95"":" & Image (Summary.P95)
                     & ",""p99"":" & Image (Summary.P99)
                     & ",""max"":" & Image (Summary.Maximum) & "}");
               end if;
               Ada.Text_IO.Put (File, "}");
            end;
         end if;
      end loop;
      Ada.Text_IO.Put (File, "],""samples"":[");
      for Index in 1 .. Retained (Result) loop
         if Index > 1 then
            Ada.Text_IO.Put (File, ",");
         end if;
         Ada.Text_IO.Put
           (File, "{""observation"":"
            & Natural_Image (Observation_Id (Result, Index))
            & ",""outcome"":" & JSON_String (Outcome_Name
              (Outcome_At (Result, Index))) & ",""metrics"":[");
         First := True;
         for Axis in Metric_Axis loop
            if Metric_Status (Result, Axis) /= Metric_Not_Requested then
               if not First then
                  Ada.Text_IO.Put (File, ",");
               end if;
               First := False;
               declare
                  Status : constant Metric_Availability :=
                    Sample_Metric_Status (Result, Index, Axis);
               begin
                  Ada.Text_IO.Put
                    (File, "{""axis"":" & JSON_String (Metric_Name (Axis))
                     & ",""status"":" & JSON_String
                       (Metric_Status_Name (Status))
                     & ",""value"":"
                     & (if Status = Metric_Collected
                        then Image (Sample_Metric_Value (Result, Index, Axis))
                        else "null") & "}");
               end;
            end if;
         end loop;
         Ada.Text_IO.Put (File, "]}");
      end loop;
      Ada.Text_IO.Put_Line (File, "]}");
   end Put_JSON;

   procedure Put_Comparison_Console
     (Result : Recorded_Comparison;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Style  : Console_Style := Auto)
   is
      Color : constant Boolean := Styled (Style);
      Tone  : constant String :=
        (case Verdict (Result) is
           when Contender_Faster => Green,
           when Reference_Faster => Red,
           when Practically_Equivalent => Cyan,
           when Inconclusive => Yellow);
   begin
      if Color then
         Ada.Text_IO.Put (File, Bold & Tone);
      end if;
      Ada.Text_IO.Put_Line
        (File, "-- independent comparison: " & Reference_Name (Result)
         & " vs " & Contender_Name (Result) & " --");
      Ada.Text_IO.Put_Line
        (File, Image (Confidence_Level_Percent (Result)) & "% confidence,"
         & Natural_Image (Bootstrap_Resamples (Result))
         & " bootstrap resamples");
      if Wall_Comparison_Available (Result) then
         Ada.Text_IO.Put_Line
           (File, "speedup  " & Image (Speedup (Result)) & "x  ["
            & Image (Speedup_Confidence_Low (Result)) & ", "
            & Image (Speedup_Confidence_High (Result)) & "]");
         Ada.Text_IO.Put_Line
           (File, "change   " & Image (Relative_Change_Percent (Result))
            & "%  [" & Image (Relative_Change_Confidence_Low (Result)) & ", "
            & Image (Relative_Change_Confidence_High (Result)) & "]  "
            & Verdict_Name (Verdict (Result)));
      else
         Ada.Text_IO.Put_Line
           (File, "wall     unavailable; no speedup or relative change");
      end if;
      if Color then
         Ada.Text_IO.Put (File, Reset);
      end if;
      Ada.Text_IO.Put_Line
        (File, Pad ("axis", 28) & " " & Pad ("reference", 20) & " "
         & Pad ("contender", 20) & " result");
      for Axis in Metric_Axis loop
         declare
            Reference_Status : constant Metric_Availability :=
              Reference_Metric_Status (Result, Axis);
            Contender_Status : constant Metric_Availability :=
              Contender_Metric_Status (Result, Axis);
            Item : constant Metric_Comparison_Result :=
              Compare_Metric (Result, Axis);
         begin
            if Reference_Status /= Metric_Not_Requested
              or else Contender_Status /= Metric_Not_Requested
            then
               Ada.Text_IO.Put_Line
                 (File, Pad (Metric_Name (Axis), 28) & " "
                  & Pad (Metric_Status_Name (Reference_Status), 20) & " "
                  & Pad (Metric_Status_Name (Contender_Status), 20) & " "
                  & (if Item.Available
                     then Image (Item.Change) & " "
                       & Metric_Verdict_Name (Item.Verdict)
                     else "unavailable"));
            end if;
         end;
      end loop;
   end Put_Comparison_Console;

   procedure Put_Comparison_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output) is
   begin
      Ada.Text_IO.Put_Line
        (File, "reference,contender,comparison_design,"
         & "confidence_level_percent,bootstrap_resamples,axis,unit,"
         & "reference_status,contender_status,available,method,"
         & "reference_median,contender_median,change,ci_low,ci_high,verdict");
   end Put_Comparison_CSV_Header;

   procedure Put_Comparison_CSV
     (Result : Recorded_Comparison;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output) is
   begin
      for Axis in Metric_Axis loop
         declare
            Item : constant Metric_Comparison_Result :=
              Compare_Metric (Result, Axis);
            Reference_Status : constant Metric_Availability :=
              Reference_Metric_Status (Result, Axis);
            Contender_Status : constant Metric_Availability :=
              Contender_Metric_Status (Result, Axis);
         begin
            if Reference_Status /= Metric_Not_Requested
              or else Contender_Status /= Metric_Not_Requested
            then
               Ada.Text_IO.Put_Line
                 (File, CSV_String (Reference_Name (Result)) & ","
                  & CSV_String (Contender_Name (Result)) & ",independent,"
                  & Image (Confidence_Level_Percent (Result)) & ","
                  & Natural_Image (Bootstrap_Resamples (Result)) & ","
                  & CSV_String (Metric_Name (Axis)) & ","
                  & CSV_String (Metric_Unit (Axis)) & ","
                  & Metric_Status_Name (Reference_Status) & ","
                  & Metric_Status_Name (Contender_Status) & ","
                  & Boolean_Image (Item.Available) & ","
                  & (if Item.Available
                     then Method_Name (Item.Method) & ","
                       & Image (Item.Reference_Median) & ","
                       & Image (Item.Contender_Median) & ","
                       & Image (Item.Change) & ","
                       & Image (Item.Confidence_Low) & ","
                       & Image (Item.Confidence_High) & ","
                       & Metric_Verdict_Name (Item.Verdict)
                     else ",,,,,,"));
            end if;
         end;
      end loop;
   end Put_Comparison_CSV;

   procedure Put_Comparison_JSON
     (Result : Recorded_Comparison;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output)
   is
      First : Boolean := True;
   begin
      Ada.Text_IO.Put
        (File, "{""reference"":" & JSON_String (Reference_Name (Result))
         & ",""contender"":" & JSON_String (Contender_Name (Result))
         & ",""comparison_design"":""independent"""
         & ",""statistics"":{""confidence_level_percent"":"
         & Image (Confidence_Level_Percent (Result))
         & ",""bootstrap_resamples"":"
         & Natural_Image (Bootstrap_Resamples (Result))
         & ",""bootstrap"":""independent""}"
         & ",""wall_comparison_available"":"
         & Boolean_Image (Wall_Comparison_Available (Result))
         & ",""speedup"":"
         & (if Wall_Comparison_Available (Result)
            then Image (Speedup (Result)) else "null")
         & ",""speedup_ci_low"":"
         & (if Wall_Comparison_Available (Result)
            then Image (Speedup_Confidence_Low (Result)) else "null")
         & ",""speedup_ci_high"":"
         & (if Wall_Comparison_Available (Result)
            then Image (Speedup_Confidence_High (Result)) else "null")
         & ",""relative_change_percent"":"
         & (if Wall_Comparison_Available (Result)
            then Image (Relative_Change_Percent (Result)) else "null")
         & ",""relative_change_ci_low"":"
         & (if Wall_Comparison_Available (Result)
            then Image (Relative_Change_Confidence_Low (Result)) else "null")
         & ",""relative_change_ci_high"":"
         & (if Wall_Comparison_Available (Result)
            then Image (Relative_Change_Confidence_High (Result)) else "null")
         & ",""verdict"":" & JSON_String (Verdict_Name (Verdict (Result)))
         & ",""metrics"":[");
      for Axis in Metric_Axis loop
         declare
            Item : constant Metric_Comparison_Result :=
              Compare_Metric (Result, Axis);
            Reference_Status : constant Metric_Availability :=
              Reference_Metric_Status (Result, Axis);
            Contender_Status : constant Metric_Availability :=
              Contender_Metric_Status (Result, Axis);
         begin
            if Reference_Status /= Metric_Not_Requested
              or else Contender_Status /= Metric_Not_Requested
            then
               if not First then
                  Ada.Text_IO.Put (File, ",");
               end if;
               First := False;
               Ada.Text_IO.Put
                 (File, "{""axis"":" & JSON_String (Metric_Name (Axis))
                  & ",""unit"":" & JSON_String (Metric_Unit (Axis))
                  & ",""reference_status"":"
                  & JSON_String (Metric_Status_Name (Reference_Status))
                  & ",""contender_status"":"
                  & JSON_String (Metric_Status_Name (Contender_Status))
                  & ",""available"":" & Boolean_Image (Item.Available)
                  & (if Item.Available
                     then ",""method"":"
                       & JSON_String (Method_Name (Item.Method))
                       & ",""reference_median"":"
                       & Image (Item.Reference_Median)
                       & ",""contender_median"":"
                       & Image (Item.Contender_Median)
                       & ",""change"":" & Image (Item.Change)
                       & ",""ci_low"":" & Image (Item.Confidence_Low)
                       & ",""ci_high"":" & Image (Item.Confidence_High)
                       & ",""verdict"":"
                       & JSON_String (Metric_Verdict_Name (Item.Verdict))
                     else "") & "}");
            end if;
         end;
      end loop;
      Ada.Text_IO.Put_Line (File, "]}");
   end Put_Comparison_JSON;
end Flyology_Bench.Recording.Reporters;
