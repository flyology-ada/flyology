--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Flyology_Bench.Scaling;

--  Coherent console, CSV, and newline-delimited JSON schemas for sweeps.
--  These reporters do not alter the crate's existing measurement schemas.
package Flyology_Bench.Sweeps.Reporters is
   --  Renders sweep and scaling data without altering legacy schemas.

   --  Print an ordinary table with median time, mean interval, and rates.
   --  @param Case_Name Suite-compatible full benchmark identity.
   --  @param Result Ordinary sweep results.
   --  @param File Destination text stream.
   procedure Put_Console
     (Case_Name : String;
      Result    : Ordinary_Sweep_Result;
      File      : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print paired time, rate, confidence, and verdict rows.
   --  @param Case_Name Suite-compatible full benchmark identity.
   --  @param Reference_Name Reference implementation display name.
   --  @param Contender_Name Contender implementation display name.
   --  @param Result Paired sweep results.
   --  @param File Destination text stream.
   procedure Put_Comparison_Console
     (Case_Name      : String;
      Reference_Name : String;
      Contender_Name : String;
      Result         : Paired_Sweep_Result;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print the ordinary sweep CSV header.
   --  @param File Destination text stream.
   procedure Put_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
   --  Print one ordinary CSV row per attempted point.
   --  @param Case_Name Suite-compatible full benchmark identity.
   --  @param Result Ordinary sweep results.
   --  @param File Destination text stream.
   procedure Put_CSV
     (Case_Name : String;
      Result    : Ordinary_Sweep_Result;
      File      : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print the paired sweep CSV header.
   --  @param File Destination text stream.
   procedure Put_Comparison_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
   --  Print one paired CSV row per attempted point.
   --  @param Case_Name Suite-compatible full benchmark identity.
   --  @param Reference_Name Reference implementation display name.
   --  @param Contender_Name Contender implementation display name.
   --  @param Result Paired sweep results.
   --  @param File Destination text stream.
   procedure Put_Comparison_CSV
     (Case_Name      : String;
      Reference_Name : String;
      Contender_Name : String;
      Result         : Paired_Sweep_Result;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Emit exactly one JSON object per point.
   --  @param Case_Name Suite-compatible full benchmark identity.
   --  @param Result Ordinary sweep results.
   --  @param File Destination text stream.
   procedure Put_NDJSON
     (Case_Name : String;
      Result    : Ordinary_Sweep_Result;
      File      : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
   --  Emit exactly one paired JSON object per point.
   --  @param Case_Name Suite-compatible full benchmark identity.
   --  @param Reference_Name Reference implementation display name.
   --  @param Contender_Name Contender implementation display name.
   --  @param Result Paired sweep results.
   --  @param File Destination text stream.
   procedure Put_Comparison_NDJSON
     (Case_Name      : String;
      Reference_Name : String;
      Contender_Name : String;
      Result         : Paired_Sweep_Result;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);

   --  Print selected and competing empirical scaling diagnostics.
   --  @param Case_Name Stable analyzed case identity.
   --  @param Result Empirical scaling analysis.
   --  @param File Destination text stream.
   procedure Put_Scaling_Console
     (Case_Name : String;
      Result    : Scaling.Empirical_Scaling_Analysis;
      File      : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
   --  Print the long-form empirical scaling CSV header.
   --  @param File Destination text stream.
   procedure Put_Scaling_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
   --  Print one CSV row per candidate scaling model.
   --  @param Case_Name Stable analyzed case identity.
   --  @param Result Empirical scaling analysis.
   --  @param File Destination text stream.
   procedure Put_Scaling_CSV
     (Case_Name : String;
      Result    : Scaling.Empirical_Scaling_Analysis;
      File      : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
   --  Emit one JSON object containing all scaling diagnostics.
   --  @param Case_Name Stable analyzed case identity.
   --  @param Result Empirical scaling analysis.
   --  @param File Destination text stream.
   procedure Put_Scaling_NDJSON
     (Case_Name : String;
      Result    : Scaling.Empirical_Scaling_Analysis;
      File      : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output);
end Flyology_Bench.Sweeps.Reporters;
