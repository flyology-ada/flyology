--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;

package Flyology_Bench.Reporters is
   --  Renders benchmark measurements and comparisons for people and tools.

   --  Selects whether human-readable console output uses ANSI styling.
   --  @enum Auto Enable ANSI only when the destination is an interactive
   --  terminal and styling has not been disabled by the environment.
   --  @enum Plain Never emit ANSI control sequences.
   --  @enum ANSI Emit ANSI color and terminal control sequences.
   type Console_Style is (Auto, Plain, ANSI);

   --  Render an in-place terminal progress display. Pass this procedure's
   --  access value as Configuration.Progress. Non-terminal output receives one
   --  plain line per phase instead of cursor control sequences. Multi-way
   --  sampling identifies the implementation in a fixed-width field.
   --  @param Name Human-readable benchmark identity.
   --  @param Phase Current benchmark stage.
   --  @param Completed Completed units in the current stage.
   --  @param Total Total units in the current stage, or zero when unbounded.
   procedure Terminal_Progress
     (Name      : String;
      Phase     : Progress_Phase;
      Completed : Natural;
      Total     : Natural);

   --  Return a configuration that renders terminal progress for the run.
   --  @param Base Measurement policy to preserve apart from its callback.
   --  @param Name Human-readable benchmark identity shown during progress.
   --  @return Base with Terminal_Progress installed.
   function Terminal_Mode
     (Base : Configuration := Default_Configuration;
      Name : String := "benchmark") return Configuration;

   --  Print one compact, human-readable benchmark summary.
   --  @param Name Benchmark name.
   --  @param Result Completed measurement.
   --  @param File Destination text file.
   --  @param Include_Telemetry Whether to append host context to the card:
   --  the interference, placement, and claim observations retained with the
   --  measurement, plus process-wide telemetry from the most recent
   --  terminal-mode run.
   --  @param Style ANSI styling policy.
   procedure Put_Console
     (Name   : String;
      Result : Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Style  : Console_Style := Auto;
      Include_Telemetry : Boolean := True);

   --  Print the schema header expected by Put_CSV rows.
   --  @param File Destination text file.
   procedure Put_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one benchmark as a CSV row with nanosecond-valued statistics.
   --  @param Name Benchmark name.
   --  @param Result Completed measurement.
   --  @param File Destination text file.
   procedure Put_CSV
     (Name   : String;
      Result : Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print the long-form schema header used by Put_Metrics_CSV rows.
   --  @param File Destination text file.
   procedure Put_Metrics_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one row per requested metric axis. Unavailable axes retain their
   --  identity, scope, unit, and specific status with an available=false
   --  marker.
   --  @param Name Benchmark name.
   --  @param Result Completed measurement.
   --  @param File Destination text file.
   procedure Put_Metrics_CSV
     (Name   : String;
      Result : Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Versioned long-form schema for built-in and custom axes. The original
   --  Put_Metrics_CSV schema remains unchanged.
   --  @param File Destination text file.
   procedure Put_Extended_Metrics_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
   --  Print versioned built-in and custom metric rows.
   --  @param Name Benchmark identity.
   --  @param Result Completed measurement.
   --  @param File Destination text file.
   procedure Put_Extended_Metrics_CSV
     (Name   : String;
      Result : Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Emit one self-contained JSON object per built-in or custom axis.
   --  @param Name Benchmark identity.
   --  @param Result Completed measurement.
   --  @param File Destination text file.
   procedure Put_Metrics_NDJSON
     (Name   : String;
      Result : Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one benchmark as a newline-delimited JSON object.
   --  @param Name Benchmark name.
   --  @param Result Completed measurement.
   --  @param File Destination text file.
   procedure Put_JSON
     (Name   : String;
      Result : Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one compact paired-comparison summary. Speedup greater than one
   --  and negative time change both mean the contender was faster.
   --  @param Reference_Name Name of the existing or baseline operation.
   --  @param Contender_Name Name of the operation compared with it.
   --  @param Result Completed paired comparison.
   --  @param File Destination text file.
   --  @param Style ANSI styling policy.
   procedure Put_Comparison_Console
     (Reference_Name : String;
      Contender_Name : String;
      Result         : Comparison;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Style          : Console_Style := Auto);

   --  Print the schema header expected by Put_Comparison_CSV rows.
   --  @param File Destination text file.
   procedure Put_Comparison_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one paired comparison as a CSV row.
   --  @param Reference_Name Name of the existing or baseline operation.
   --  @param Contender_Name Name of the operation compared with it.
   --  @param Result Completed paired comparison.
   --  @param File Destination text file.
   procedure Put_Comparison_CSV
     (Reference_Name : String;
      Contender_Name : String;
      Result         : Comparison;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print the long-form schema header used by comparison metric rows.
   --  @param File Destination text file.
   procedure Put_Comparison_Metrics_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one row per requested paired metric comparison.
   --  @param Reference_Name Reference implementation name.
   --  @param Contender_Name Contender implementation name.
   --  @param Result Completed paired comparison.
   --  @param File Destination text file.
   procedure Put_Comparison_Metrics_CSV
     (Reference_Name : String;
      Contender_Name : String;
      Result         : Comparison;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print the versioned built-in/custom comparison schema.
   --  @param File Destination text file.
   procedure Put_Extended_Comparison_Metrics_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
   --  Print versioned built-in and custom paired metric rows.
   --  @param Reference_Name Reference benchmark identity.
   --  @param Contender_Name Contender benchmark identity.
   --  @param Result Completed paired comparison.
   --  @param File Destination text file.
   procedure Put_Extended_Comparison_Metrics_CSV
     (Reference_Name : String;
      Contender_Name : String;
      Result         : Comparison;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
   --  Emit one JSON object per built-in or custom paired axis.
   --  @param Reference_Name Reference benchmark identity.
   --  @param Contender_Name Contender benchmark identity.
   --  @param Result Completed paired comparison.
   --  @param File Destination text file.
   procedure Put_Comparison_Metrics_NDJSON
     (Reference_Name : String;
      Contender_Name : String;
      Result         : Comparison;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one paired comparison as a newline-delimited JSON object.
   --  @param Reference_Name Name of the existing or baseline operation.
   --  @param Contender_Name Name of the operation compared with it.
   --  @param Result Completed paired comparison.
   --  @param File Destination text file.
   procedure Put_Comparison_JSON
     (Reference_Name : String;
      Contender_Name : String;
      Result         : Comparison;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   generic
      --  Same enumeration used to instantiate Compare_Many.
      type Case_Id is (<>);
   --  Print a colored table of every implementation versus case one.
   --  @param Result Completed multi-way comparison.
   --  @param File Destination text file.
   --  @param Style ANSI styling policy.
   --  @param Show_Individual_Details Print a full measurement card for every
   --  implementation after the comparison table. Process telemetry remains
   --  attached once to the overall shootout.
   procedure Put_Multi_Comparison_Console
     (Result : Multi_Comparison;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Style  : Console_Style := Auto;
      Show_Individual_Details : Boolean := False);

   --  Print the schema header used by multi-way CSV rows.
   --  @param File Destination text file.
   procedure Put_Multi_Comparison_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   generic
      --  Same enumeration used to instantiate Compare_Many.
      type Case_Id is (<>);
   --  Print one CSV row per contender versus case one.
   --  @param Result Completed multi-way comparison.
   --  @param File Destination text file.
   procedure Put_Multi_Comparison_CSV
     (Result : Multi_Comparison;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   generic
      --  Same enumeration used to instantiate Compare_Many.
      type Case_Id is (<>);
   --  Print one long-form comparison metric row per contender and axis. Use
   --  Put_Comparison_Metrics_CSV_Header for the schema header.
   --  @param Result Completed multi-way comparison.
   --  @param File Destination text file.
   procedure Put_Multi_Comparison_Metrics_CSV
     (Result : Multi_Comparison;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   generic
      --  Same enumeration used to instantiate Compare_Many.
      type Case_Id is (<>);
   --  Print one JSON object containing the reference and all contender rows.
   --  @param Result Completed multi-way comparison.
   --  @param File Destination text file.
   procedure Put_Multi_Comparison_JSON
     (Result : Multi_Comparison;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
end Flyology_Bench.Reporters;
