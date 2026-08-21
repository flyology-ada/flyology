--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Characters.Handling;
with Ada.Strings.Unbounded;

package body Flyology_Bench.Sweeps.Reporters is
   use Ada.Text_IO;

   function Trimmed (Value : String) return String is
   begin
      if Value'Length > 0 and then Value (Value'First) = ' ' then
         return Value (Value'First + 1 .. Value'Last);
      end if;
      return Value;
   end Trimmed;

   function Number (Value : Long_Float) return String is
     (Trimmed (Long_Float'Image (Value)));

   function Number (Value : Exact_Value) return String is
     (Trimmed (Exact_Value'Image (Value)));

   function Token (Value : String) return String is
     (Ada.Characters.Handling.To_Lower (Trimmed (Value)));

   function Status_Name (Value : Point_Status) return String is
     (Token (Point_Status'Image (Value)));

   function Availability_Name
     (Value : Throughput_Availability) return String is
     (Token (Throughput_Availability'Image (Value)));

   function Kind_Name (Value : Parameter_Kind) return String is
     (case Value is
         when Size_Parameter  => "size",
         when Count_Parameter => "count");

   function Work_Kind_Name (Value : Work_Unit_Kind) return String is
     (case Value is
         when Items        => "items",
         when Bytes        => "bytes",
         when Caller_Named => "caller_named");

   function Scaling_Name (Value : Display_Scaling) return String is
     (case Value is
         when Decimal_Scaling => "decimal",
         when Binary_Scaling  => "binary");

   function Verdict_Name (Value : Comparison_Verdict) return String is
     (Token (Comparison_Verdict'Image (Value)));

   function Model_Name (Value : Scaling.Scaling_Model) return String is
     (case Value is
         when Scaling.Constant_Model    => "constant",
         when Scaling.Logarithmic_Model => "logarithmic",
         when Scaling.Linear_Model      => "linear",
         when Scaling.N_Log_N_Model     => "n_log_n",
         when Scaling.Quadratic_Model   => "quadratic",
         when Scaling.Cubic_Model       => "cubic");

   function Scaling_Status_Name (Value : Scaling.Scaling_Status) return String is
     (Token (Scaling.Scaling_Status'Image (Value)));

   function CSV (Value : String) return String is
      use Ada.Strings.Unbounded;
      Escaped : Unbounded_String;
      Needs_Quotes : Boolean := False;
   begin
      for Ch of Value loop
         if Ch = ',' or else Ch = '"'
           or else Ch = Character'Val (10)
           or else Ch = Character'Val (13)
         then
            Needs_Quotes := True;
         end if;
         if Ch = '"' then
            Append (Escaped, """");
         end if;
         Append (Escaped, Ch);
      end loop;
      return
        (if Needs_Quotes then '"' & To_String (Escaped) & '"'
         else To_String (Escaped));
   end CSV;

   function Hex (Value : Natural) return Character is
     (if Value < 10 then Character'Val (Character'Pos ('0') + Value)
      else Character'Val (Character'Pos ('a') + Value - 10));

   function JSON (Value : String) return String is
      use Ada.Strings.Unbounded;
      Escaped : Unbounded_String;
   begin
      for Ch of Value loop
         case Ch is
            when '"' => Append (Escaped, "\""");
            when '\' => Append (Escaped, "\\");
            when Character'Val (8)  => Append (Escaped, "\b");
            when Character'Val (9)  => Append (Escaped, "\t");
            when Character'Val (10) => Append (Escaped, "\n");
            when Character'Val (12) => Append (Escaped, "\f");
            when Character'Val (13) => Append (Escaped, "\r");
            when others =>
               if Character'Pos (Ch) < 32 then
                  Append (Escaped, "\u00");
                  Append (Escaped, Hex (Character'Pos (Ch) / 16));
                  Append (Escaped, Hex (Character'Pos (Ch) mod 16));
               else
                  Append (Escaped, Ch);
               end if;
         end case;
      end loop;
      return To_String (Escaped);
   end JSON;

   function Boolean_Name (Value : Boolean) return String is
     (if Value then "true" else "false");

   function Maybe_Number
     (Summary : Throughput_Summary;
      Value   : Long_Float;
      JSON_Mode : Boolean := False) return String is
     (if Available (Summary) then Number (Value)
      elsif JSON_Mode then "null" else "");

   function Median_Or_Empty
     (State : Point_Status;
      Item  : Measurement;
      JSON_Mode : Boolean := False) return String is
     (if State = Point_Measured then Number (Median_Nanoseconds (Item))
      elsif JSON_Mode then "null" else "");

   function Low_Or_Empty
     (State : Point_Status;
      Item  : Measurement;
      JSON_Mode : Boolean := False) return String is
     (if State = Point_Measured
      then Number (Mean_Confidence_Low_Nanoseconds (Item))
      elsif JSON_Mode then "null" else "");

   function High_Or_Empty
     (State : Point_Status;
      Item  : Measurement;
      JSON_Mode : Boolean := False) return String is
     (if State = Point_Measured
      then Number (Mean_Confidence_High_Nanoseconds (Item))
      elsif JSON_Mode then "null" else "");

   procedure Put_Console
     (Case_Name : String;
      Result    : Ordinary_Sweep_Result;
      File      : File_Type := Standard_Output)
   is
   begin
      Put_Line (File, "empirical sweep " & Case_Name);
      Put_Line
        (File,
         "parameter  label  status  median ns/op  mean 95% CI ns/op"
         & "  operations/s [mean-time-derived CI]  work/s  work/op");
      Put_Line (File, "throughput direction: higher is better");
      for Index in 1 .. Length (Result) loop
         declare
            Item : constant Ordinary_Point_Result := Element (Result, Index);
            Point_Value : constant Parameter_Point := Parameter (Item);
            Rate : constant Throughput_Summary := Throughput (Item);
            Measurement_Value : constant Measurement := Data (Item);
         begin
            Put_Line
              (File,
               Identity (Point_Value) & "  " & Label (Point_Value) & "  "
               & Status_Name (Status (Item)) & "  "
               & Median_Or_Empty (Status (Item), Measurement_Value) & "  ["
               & Low_Or_Empty (Status (Item), Measurement_Value) & ", "
               & High_Or_Empty (Status (Item), Measurement_Value) & "]  "
               & Maybe_Number (Rate, Operations_Per_Second (Rate)) & " ["
               & Maybe_Number (Rate, Operations_Confidence_Low (Rate)) & ", "
               & Maybe_Number (Rate, Operations_Confidence_High (Rate)) & "]  "
               & Maybe_Number (Rate, Work_Units_Per_Second (Rate)) & " "
               & Unit_Name (Work_Per_Operation (Item)) & "/s  "
               & Number (Raw_Value (Work_Per_Operation (Item))) & " "
               & Unit_Name (Work_Per_Operation (Item)));
         end;
      end loop;
   end Put_Console;

   procedure Put_Comparison_Console
     (Case_Name      : String;
      Reference_Name : String;
      Contender_Name : String;
      Result         : Paired_Sweep_Result;
      File           : File_Type := Standard_Output)
   is
   begin
      Put_Line
        (File, "empirical paired sweep " & Case_Name & " ("
         & Reference_Name & " vs " & Contender_Name & ")");
      Put_Line
        (File,
         "parameter  status  reference median [mean CI]  contender median"
         & " [mean CI]  reference op/s [rate CI]  contender op/s [rate CI]"
         & "  reference work/s"
         & "  contender work/s  work/op  paired verdict");
      Put_Line (File, "throughput direction: higher is better");
      for Index in 1 .. Length (Result) loop
         declare
            Item : constant Paired_Point_Result := Element (Result, Index);
            Pair : constant Comparison := Data (Item);
            Reference : constant Measurement := Reference_Measurement (Pair);
            Contender : constant Measurement := Contender_Measurement (Pair);
            Reference_Rate : constant Throughput_Summary :=
              Reference_Throughput (Item);
            Contender_Rate : constant Throughput_Summary :=
              Contender_Throughput (Item);
            Measured : constant Boolean := Status (Item) = Point_Measured;
         begin
            Put_Line
              (File,
               Identity (Parameter (Item)) & "  " & Status_Name (Status (Item))
               & "  " & Median_Or_Empty (Status (Item), Reference) & " ["
               & Low_Or_Empty (Status (Item), Reference) & ", "
               & High_Or_Empty (Status (Item), Reference) & "]  "
               & Median_Or_Empty (Status (Item), Contender) & " ["
               & Low_Or_Empty (Status (Item), Contender) & ", "
               & High_Or_Empty (Status (Item), Contender) & "]  "
               & Maybe_Number
                   (Reference_Rate, Operations_Per_Second (Reference_Rate))
               & " [" & Maybe_Number
                   (Reference_Rate,
                    Operations_Confidence_Low (Reference_Rate))
               & ", " & Maybe_Number
                   (Reference_Rate,
                    Operations_Confidence_High (Reference_Rate)) & "]  "
               & Maybe_Number
                   (Contender_Rate, Operations_Per_Second (Contender_Rate))
               & " [" & Maybe_Number
                   (Contender_Rate,
                    Operations_Confidence_Low (Contender_Rate))
               & ", " & Maybe_Number
                   (Contender_Rate,
                    Operations_Confidence_High (Contender_Rate)) & "]  "
               & Maybe_Number
                   (Reference_Rate, Work_Units_Per_Second (Reference_Rate))
               & "  "
               & Maybe_Number
                   (Contender_Rate, Work_Units_Per_Second (Contender_Rate))
               & "  "
               & Number (Raw_Value (Work_Per_Operation (Item))) & " "
               & Unit_Name (Work_Per_Operation (Item)) & "  "
               & (if Measured then Verdict_Name (Verdict (Pair)) else ""));
         end;
      end loop;
   end Put_Comparison_Console;

   procedure Put_CSV_Header (File : File_Type := Standard_Output) is
   begin
      Put_Line
        (File,
         "benchmark,point,parameter_kind,parameter_value,parameter_label,"
         & "result_kind,work_kind,work_unit,work_value,work_scaling,"
         & "sample_semantics,available,status,failure,median_elapsed_ns,"
         & "mean_elapsed_ci_low_ns,mean_elapsed_ci_high_ns,"
         & "operations_per_second,operations_ci_low,operations_ci_high,"
         & "work_units_per_second,work_ci_low,work_ci_high,direction");
   end Put_CSV_Header;

   procedure Put_CSV
     (Case_Name : String;
      Result    : Ordinary_Sweep_Result;
      File      : File_Type := Standard_Output)
   is
   begin
      for Index in 1 .. Length (Result) loop
         declare
            Item : constant Ordinary_Point_Result := Element (Result, Index);
            Point_Value : constant Parameter_Point := Parameter (Item);
            Amount : constant Work_Amount := Work_Per_Operation (Item);
            Rate : constant Throughput_Summary := Throughput (Item);
            Measurement_Value : constant Measurement := Data (Item);
         begin
            Put_Line
              (File,
               CSV (Case_Name) & ',' & CSV (Identity (Point_Value)) & ','
               & Kind_Name (Kind (Point_Value)) & ','
               & Number (Value (Point_Value)) & ',' & CSV (Label (Point_Value))
               & ",ordinary_measurement," & Work_Kind_Name (Unit_Kind (Amount))
               & ',' & CSV (Unit_Name (Amount)) & ',' & Number (Raw_Value (Amount))
               & ',' & Scaling_Name (Display_Scale (Amount))
               & ",per_operation_batch_mean,"
               & Boolean_Name (Status (Item) = Point_Measured) & ','
               & Status_Name (Status (Item)) & ',' & CSV (Failure_Message (Item))
               & ',' & Median_Or_Empty (Status (Item), Measurement_Value)
               & ',' & Low_Or_Empty (Status (Item), Measurement_Value)
               & ',' & High_Or_Empty (Status (Item), Measurement_Value)
               & ',' & Maybe_Number (Rate, Operations_Per_Second (Rate))
               & ',' & Maybe_Number (Rate, Operations_Confidence_Low (Rate))
               & ',' & Maybe_Number (Rate, Operations_Confidence_High (Rate))
               & ',' & Maybe_Number (Rate, Work_Units_Per_Second (Rate))
               & ',' & Maybe_Number (Rate, Work_Confidence_Low (Rate))
               & ',' & Maybe_Number (Rate, Work_Confidence_High (Rate))
               & ",higher_is_better");
         end;
      end loop;
   end Put_CSV;

   procedure Put_Comparison_CSV_Header
     (File : File_Type := Standard_Output) is
   begin
      Put_Line
        (File,
         "benchmark,point,parameter_kind,parameter_value,parameter_label,"
         & "result_kind,reference,contender,work_kind,work_unit,work_value,"
         & "work_scaling,sample_semantics,available,status,failure,"
         & "reference_median_elapsed_ns,reference_mean_ci_low_ns,"
         & "reference_mean_ci_high_ns,contender_median_elapsed_ns,"
         & "contender_mean_ci_low_ns,contender_mean_ci_high_ns,"
         & "reference_operations_per_second,contender_operations_per_second,"
         & "reference_operations_ci_low,reference_operations_ci_high,"
         & "contender_operations_ci_low,contender_operations_ci_high,"
         & "reference_work_units_per_second,contender_work_units_per_second,"
         & "reference_work_ci_low,reference_work_ci_high,"
         & "contender_work_ci_low,contender_work_ci_high,"
         & "direction,paired_verdict");
   end Put_Comparison_CSV_Header;

   procedure Put_Comparison_CSV
     (Case_Name      : String;
      Reference_Name : String;
      Contender_Name : String;
      Result         : Paired_Sweep_Result;
      File           : File_Type := Standard_Output)
   is
   begin
      for Index in 1 .. Length (Result) loop
         declare
            Item : constant Paired_Point_Result := Element (Result, Index);
            Point_Value : constant Parameter_Point := Parameter (Item);
            Amount : constant Work_Amount := Work_Per_Operation (Item);
            Pair : constant Comparison := Data (Item);
            Reference : constant Measurement := Reference_Measurement (Pair);
            Contender : constant Measurement := Contender_Measurement (Pair);
            Reference_Rate : constant Throughput_Summary :=
              Reference_Throughput (Item);
            Contender_Rate : constant Throughput_Summary :=
              Contender_Throughput (Item);
            Measured : constant Boolean := Status (Item) = Point_Measured;
         begin
            Put_Line
              (File,
               CSV (Case_Name) & ',' & CSV (Identity (Point_Value)) & ','
               & Kind_Name (Kind (Point_Value)) & ','
               & Number (Value (Point_Value)) & ',' & CSV (Label (Point_Value))
               & ",paired_comparison," & CSV (Reference_Name) & ','
               & CSV (Contender_Name) & ','
               & Work_Kind_Name (Unit_Kind (Amount)) & ','
               & CSV (Unit_Name (Amount)) & ',' & Number (Raw_Value (Amount))
               & ',' & Scaling_Name (Display_Scale (Amount))
               & ",per_operation_batch_mean," & Boolean_Name (Measured) & ','
               & Status_Name (Status (Item)) & ',' & CSV (Failure_Message (Item))
               & ',' & Median_Or_Empty (Status (Item), Reference)
               & ',' & Low_Or_Empty (Status (Item), Reference)
               & ',' & High_Or_Empty (Status (Item), Reference)
               & ',' & Median_Or_Empty (Status (Item), Contender)
               & ',' & Low_Or_Empty (Status (Item), Contender)
               & ',' & High_Or_Empty (Status (Item), Contender)
               & ',' & Maybe_Number
                 (Reference_Rate, Operations_Per_Second (Reference_Rate))
               & ',' & Maybe_Number
                 (Contender_Rate, Operations_Per_Second (Contender_Rate))
               & ',' & Maybe_Number
                 (Reference_Rate, Operations_Confidence_Low (Reference_Rate))
               & ',' & Maybe_Number
                 (Reference_Rate, Operations_Confidence_High (Reference_Rate))
               & ',' & Maybe_Number
                 (Contender_Rate, Operations_Confidence_Low (Contender_Rate))
               & ',' & Maybe_Number
                 (Contender_Rate, Operations_Confidence_High (Contender_Rate))
               & ',' & Maybe_Number
                 (Reference_Rate, Work_Units_Per_Second (Reference_Rate))
               & ',' & Maybe_Number
                 (Contender_Rate, Work_Units_Per_Second (Contender_Rate))
               & ',' & Maybe_Number
                 (Reference_Rate, Work_Confidence_Low (Reference_Rate))
               & ',' & Maybe_Number
                 (Reference_Rate, Work_Confidence_High (Reference_Rate))
               & ',' & Maybe_Number
                 (Contender_Rate, Work_Confidence_Low (Contender_Rate))
               & ',' & Maybe_Number
                 (Contender_Rate, Work_Confidence_High (Contender_Rate))
               & ",higher_is_better,"
               & (if Measured then Verdict_Name (Verdict (Pair)) else ""));
         end;
      end loop;
   end Put_Comparison_CSV;

   procedure Put_NDJSON
     (Case_Name : String;
      Result    : Ordinary_Sweep_Result;
      File      : File_Type := Standard_Output)
   is
   begin
      for Index in 1 .. Length (Result) loop
         declare
            Item : constant Ordinary_Point_Result := Element (Result, Index);
            Point_Value : constant Parameter_Point := Parameter (Item);
            Amount : constant Work_Amount := Work_Per_Operation (Item);
            Rate : constant Throughput_Summary := Throughput (Item);
            Measurement_Value : constant Measurement := Data (Item);
         begin
            Put_Line
              (File,
               "{""type"":""sweep_point"",""benchmark"":"""
               & JSON (Case_Name) & """,""point"":"""
               & JSON (Identity (Point_Value)) & """,""parameter_kind"":"""
               & Kind_Name (Kind (Point_Value)) & """,""parameter_value"":"
               & Number (Value (Point_Value)) & ",""parameter_label"":"""
               & JSON (Label (Point_Value))
               & """,""result_kind"":""ordinary_measurement"",""work"":{""kind"":"""
               & Work_Kind_Name (Unit_Kind (Amount)) & """,""unit"":"""
               & JSON (Unit_Name (Amount)) & """,""raw_value"":"
               & Number (Raw_Value (Amount)) & ",""display_scaling"":"""
               & Scaling_Name (Display_Scale (Amount))
               & """},""sample_semantics"":""per_operation_batch_mean"",""available"":"
               & Boolean_Name (Status (Item) = Point_Measured)
               & ",""status"":""" & Status_Name (Status (Item))
               & """,""failure"":""" & JSON (Failure_Message (Item))
               & """,""median_elapsed_ns"":"
               & Median_Or_Empty (Status (Item), Measurement_Value, True)
               & ",""mean_elapsed_ci_low_ns"":"
               & Low_Or_Empty (Status (Item), Measurement_Value, True)
               & ",""mean_elapsed_ci_high_ns"":"
               & High_Or_Empty (Status (Item), Measurement_Value, True)
               & ",""throughput"":{""availability"":"""
               & Availability_Name (Availability (Rate))
               & """,""direction"":""higher_is_better"",""operations_per_second"":"
               & Maybe_Number (Rate, Operations_Per_Second (Rate), True)
               & ",""operations_ci_low"":"
               & Maybe_Number (Rate, Operations_Confidence_Low (Rate), True)
               & ",""operations_ci_high"":"
               & Maybe_Number (Rate, Operations_Confidence_High (Rate), True)
               & ",""work_units_per_second"":"
               & Maybe_Number (Rate, Work_Units_Per_Second (Rate), True)
               & ",""work_ci_low"":"
               & Maybe_Number (Rate, Work_Confidence_Low (Rate), True)
               & ",""work_ci_high"":"
               & Maybe_Number (Rate, Work_Confidence_High (Rate), True)
               & "}}");
         end;
      end loop;
   end Put_NDJSON;

   procedure Put_Comparison_NDJSON
     (Case_Name      : String;
      Reference_Name : String;
      Contender_Name : String;
      Result         : Paired_Sweep_Result;
      File           : File_Type := Standard_Output)
   is
   begin
      for Index in 1 .. Length (Result) loop
         declare
            Item : constant Paired_Point_Result := Element (Result, Index);
            Point_Value : constant Parameter_Point := Parameter (Item);
            Amount : constant Work_Amount := Work_Per_Operation (Item);
            Pair : constant Comparison := Data (Item);
            Reference : constant Measurement := Reference_Measurement (Pair);
            Contender : constant Measurement := Contender_Measurement (Pair);
            Reference_Rate : constant Throughput_Summary :=
              Reference_Throughput (Item);
            Contender_Rate : constant Throughput_Summary :=
              Contender_Throughput (Item);
            Measured : constant Boolean := Status (Item) = Point_Measured;

            function Side_JSON
              (Name : String;
               Measurement_Value : Measurement;
               Rate : Throughput_Summary) return String is
              ("{""name"":""" & JSON (Name) & """,""median_elapsed_ns"":"
               & Median_Or_Empty (Status (Item), Measurement_Value, True)
               & ",""mean_elapsed_ci_low_ns"":"
               & Low_Or_Empty (Status (Item), Measurement_Value, True)
               & ",""mean_elapsed_ci_high_ns"":"
               & High_Or_Empty (Status (Item), Measurement_Value, True)
               & ",""operations_per_second"":"
               & Maybe_Number (Rate, Operations_Per_Second (Rate), True)
               & ",""operations_ci_low"":"
               & Maybe_Number (Rate, Operations_Confidence_Low (Rate), True)
               & ",""operations_ci_high"":"
               & Maybe_Number (Rate, Operations_Confidence_High (Rate), True)
               & ",""work_units_per_second"":"
               & Maybe_Number (Rate, Work_Units_Per_Second (Rate), True)
               & ",""work_ci_low"":"
               & Maybe_Number (Rate, Work_Confidence_Low (Rate), True)
               & ",""work_ci_high"":"
               & Maybe_Number (Rate, Work_Confidence_High (Rate), True)
               & "}");
         begin
            Put_Line
              (File,
               "{""type"":""sweep_point"",""benchmark"":"""
               & JSON (Case_Name) & """,""point"":"""
               & JSON (Identity (Point_Value)) & """,""parameter_kind"":"""
               & Kind_Name (Kind (Point_Value)) & """,""parameter_value"":"
               & Number (Value (Point_Value)) & ",""parameter_label"":"""
               & JSON (Label (Point_Value))
               & """,""result_kind"":""paired_comparison"",""work"":{""kind"":"""
               & Work_Kind_Name (Unit_Kind (Amount)) & """,""unit"":"""
               & JSON (Unit_Name (Amount)) & """,""raw_value"":"
               & Number (Raw_Value (Amount)) & ",""display_scaling"":"""
               & Scaling_Name (Display_Scale (Amount))
               & """},""sample_semantics"":""per_operation_batch_mean"",""available"":"
               & Boolean_Name (Measured) & ",""status"":"""
               & Status_Name (Status (Item)) & """,""failure"":"""
               & JSON (Failure_Message (Item)) & """,""direction"":""higher_is_better"",""reference"":"
               & Side_JSON (Reference_Name, Reference, Reference_Rate)
               & ",""contender"":"
               & Side_JSON (Contender_Name, Contender, Contender_Rate)
               & ",""paired_verdict"":"
               & (if Measured then '"' & Verdict_Name (Verdict (Pair)) & '"'
                  else "null") & "}");
         end;
      end loop;
   end Put_Comparison_NDJSON;

   procedure Put_Scaling_Console
     (Case_Name : String;
      Result    : Scaling.Empirical_Scaling_Analysis;
      File      : File_Type := Standard_Output)
   is
   begin
      Put_Line
        (File, "empirical scaling " & Case_Name & ": "
         & Scaling_Status_Name (Scaling.Status (Result)) & ", inputs "
         & Number (Scaling.Minimum_Input (Result)) & " .. "
         & Number (Scaling.Maximum_Input (Result)));
      Put_Line
        (File, "model  selected  coefficient  exponent  r_squared  rms_log_residual  max_log_residual");
      for Model in Scaling.Scaling_Model loop
         declare
            Item : constant Scaling.Model_Diagnostic :=
              Scaling.Diagnostic (Result, Model);
         begin
            Put_Line
              (File, Model_Name (Model) & "  " & Boolean_Name (Item.Selected)
               & "  " & (if Item.Available then Number (Item.Coefficient) else "")
               & "  " & Number (Item.Nominal_Exponent)
               & "  " & (if Item.Available then Number (Item.R_Squared) else "")
               & "  " & (if Item.Available
                            then Number (Item.RMS_Log_Residual) else "")
               & "  " & (if Item.Available
                            then Number (Item.Maximum_Absolute_Log_Residual)
                            else ""));
         end;
      end loop;
   end Put_Scaling_Console;

   procedure Put_Scaling_CSV_Header
     (File : File_Type := Standard_Output) is
   begin
      Put_Line
        (File,
         "benchmark,analysis,status,points,minimum_input,maximum_input,model,"
         & "available,selected,coefficient,nominal_exponent,r_squared,"
         & "rms_log_residual,maximum_absolute_log_residual");
   end Put_Scaling_CSV_Header;

   procedure Put_Scaling_CSV
     (Case_Name : String;
      Result    : Scaling.Empirical_Scaling_Analysis;
      File      : File_Type := Standard_Output)
   is
   begin
      for Model in Scaling.Scaling_Model loop
         declare
            Item : constant Scaling.Model_Diagnostic :=
              Scaling.Diagnostic (Result, Model);
         begin
            Put_Line
              (File, CSV (Case_Name) & ",empirical_scaling,"
               & Scaling_Status_Name (Scaling.Status (Result)) & ','
               & Trimmed (Natural'Image (Scaling.Points_Analyzed (Result)))
               & ',' & Number (Scaling.Minimum_Input (Result)) & ','
               & Number (Scaling.Maximum_Input (Result)) & ','
               & Model_Name (Model) & ',' & Boolean_Name (Item.Available) & ','
               & Boolean_Name (Item.Selected) & ','
               & (if Item.Available then Number (Item.Coefficient) else "") & ','
               & Number (Item.Nominal_Exponent) & ','
               & (if Item.Available then Number (Item.R_Squared) else "") & ','
               & (if Item.Available then Number (Item.RMS_Log_Residual) else "")
               & ',' & (if Item.Available
                         then Number (Item.Maximum_Absolute_Log_Residual)
                         else ""));
         end;
      end loop;
   end Put_Scaling_CSV;

   procedure Put_Scaling_NDJSON
     (Case_Name : String;
      Result    : Scaling.Empirical_Scaling_Analysis;
      File      : File_Type := Standard_Output)
   is
      use Ada.Strings.Unbounded;
      Models : Unbounded_String;
      First : Boolean := True;
   begin
      for Model in Scaling.Scaling_Model loop
         declare
            Item : constant Scaling.Model_Diagnostic :=
              Scaling.Diagnostic (Result, Model);
         begin
            if not First then
               Append (Models, ",");
            end if;
            First := False;
            Append
              (Models,
               "{""model"":""" & Model_Name (Model)
               & """,""available"":" & Boolean_Name (Item.Available)
               & ",""selected"":" & Boolean_Name (Item.Selected)
               & ",""coefficient"":"
               & (if Item.Available then Number (Item.Coefficient) else "null")
               & ",""nominal_exponent"":" & Number (Item.Nominal_Exponent)
               & ",""r_squared"":"
               & (if Item.Available then Number (Item.R_Squared) else "null")
               & ",""rms_log_residual"":"
               & (if Item.Available
                  then Number (Item.RMS_Log_Residual) else "null")
               & ",""maximum_absolute_log_residual"":"
               & (if Item.Available
                  then Number (Item.Maximum_Absolute_Log_Residual) else "null")
               & "}");
         end;
      end loop;
      Put_Line
        (File,
         "{""type"":""empirical_scaling"",""benchmark"":"""
         & JSON (Case_Name) & """,""status"":"""
         & Scaling_Status_Name (Scaling.Status (Result))
         & """,""available"":" & Boolean_Name (Scaling.Available (Result))
         & ",""points"":"
         & Trimmed (Natural'Image (Scaling.Points_Analyzed (Result)))
         & ",""minimum_input"":" & Number (Scaling.Minimum_Input (Result))
         & ",""maximum_input"":" & Number (Scaling.Maximum_Input (Result))
         & ",""selected_model"":"
         & (if Scaling.Available (Result)
            then '"' & Model_Name (Scaling.Selected_Model (Result)) & '"'
            else "null") & ",""models"":[" & To_String (Models) & "]}");
   end Put_Scaling_NDJSON;
end Flyology_Bench.Sweeps.Reporters;
