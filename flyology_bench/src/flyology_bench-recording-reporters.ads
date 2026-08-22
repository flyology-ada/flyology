--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Flyology_Bench.Reporters;

--  Human and machine-readable reporters for externally recorded spans.

package Flyology_Bench.Recording.Reporters is
   --  ANSI-selection policy shared with runner reporters.
   subtype Console_Style is Flyology_Bench.Reporters.Console_Style;
   --  Select ANSI only for an interactive terminal.
   Auto  : constant Console_Style := Flyology_Bench.Reporters.Auto;
   --  Never emit ANSI styling.
   Plain : constant Console_Style := Flyology_Bench.Reporters.Plain;
   --  Always emit ANSI styling.
   ANSI  : constant Console_Style := Flyology_Bench.Reporters.ANSI;

   --  Print an individual-span summary and one row for every requested axis.
   --  @param Result Recorded snapshot.
   --  @param File Destination text file.
   --  @param Style ANSI selection policy.
   procedure Put_Console
     (Result : Recorded_Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Style  : Console_Style := Auto);

   --  Print the long-form recorded-metric CSV schema.
   --  @param File Destination text file.
   procedure Put_CSV_Header (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one long-form summary row per requested axis.
   --  @param Result Recorded snapshot.
   --  @param File Destination text file.
   procedure Put_CSV
     (Result : Recorded_Measurement; File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print the raw individual-span metric CSV schema.
   --  @param File Destination text file.
   procedure Put_Samples_CSV_Header (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one row per retained span and requested axis. Observation identity
   --  and outcome remain aligned across axes; unavailable values have an empty
   --  value field and an explicit status.
   --  @param Result Recorded snapshot.
   --  @param File Destination text file.
   procedure Put_Samples_CSV
     (Result : Recorded_Measurement; File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one newline-delimited JSON object with summaries and aligned raw
   --  individual-span rows.
   --  @param Result Recorded snapshot.
   --  @param File Destination text file.
   procedure Put_JSON
     (Result : Recorded_Measurement; File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print an independent-distribution comparison table.
   --  @param Result Independent comparison.
   --  @param File Destination text file.
   --  @param Style ANSI selection policy.
   procedure Put_Comparison_Console
     (Result : Recorded_Comparison;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Style  : Console_Style := Auto);

   --  Print the independent-comparison CSV schema.
   --  @param File Destination text file.
   procedure Put_Comparison_CSV_Header (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one independent-comparison row per axis requested by either side,
   --  including explicit unavailable statuses.
   --  @param Result Independent comparison.
   --  @param File Destination text file.
   procedure Put_Comparison_CSV
     (Result : Recorded_Comparison; File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print one newline-delimited JSON independent-comparison object.
   --  @param Result Independent comparison.
   --  @param File Destination text file.
   procedure Put_Comparison_JSON
     (Result : Recorded_Comparison; File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
end Flyology_Bench.Recording.Reporters;
