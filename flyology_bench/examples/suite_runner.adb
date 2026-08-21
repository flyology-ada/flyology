--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology_Bench;
with Flyology_Bench.Suites;
with Interfaces;

procedure Suite_Runner is
   use type Interfaces.Unsigned_32;

   package Benchmarks is new Flyology_Bench.Suites (Maximum_Cases => 8);

   Value : Interfaces.Unsigned_32 := 1 with Volatile;

   procedure Mix is
   begin
      Value := Value * 1_664_525 + 1_013_904_223;
   end Mix;

   procedure Double_Mix is
   begin
      Mix;
      Mix;
   end Double_Mix;

   procedure Branch is
   begin
      Value := Value * 1_103_515_245 + 12_345;
      if (Value and 1) = 0 then
         Value := Value xor 16#A5A5_A5A5#;
      end if;
   end Branch;

   procedure Measure_Mix is new Flyology_Bench.Measure (Mix);
   procedure Measure_Branch is new Flyology_Bench.Measure (Branch);
   procedure Compare_Mixes is new Flyology_Bench.Compare
     (Reference_Operation => Mix,
      Contender_Operation => Double_Mix);

   procedure Run_Mix
     (Config : Flyology_Bench.Configuration;
      Result : out Flyology_Bench.Measurement) is
   begin
      Measure_Mix (Config, Result);
   end Run_Mix;

   procedure Run_Branch
     (Config : Flyology_Bench.Configuration;
      Result : out Flyology_Bench.Measurement) is
   begin
      Measure_Branch (Config, Result);
   end Run_Branch;

   procedure Run_Comparison
     (Config : Flyology_Bench.Configuration;
      Result : out Flyology_Bench.Comparison) is
   begin
      Compare_Mixes (Config, Result);
   end Run_Comparison;

   Target  : Benchmarks.Suite;
   Summary : Benchmarks.Run_Summary;
   Base    : constant Flyology_Bench.Configuration :=
     (Flyology_Bench.Default_Configuration with delta
        Warmup_Time => 0.010,
        Measurement_Time => 0.050,
        Maximum_Sampling_Time => 0.100,
        Samples => 20,
        Minimum_Sample_Time => 0.000_010,
        Random_Seed => 42);
begin
   Benchmarks.Register
     (Target, "mix", Run_Mix'Access,
      Group => "integer", Tags => "arithmetic,smoke");
   Benchmarks.Register
     (Target, "branch", Run_Branch'Access,
      Group => "integer", Tags => "branch,smoke");
   Benchmarks.Register_Paired
     (Target, "comparison", "mix", "double_mix", Run_Comparison'Access,
      Group => "integer", Tags => "arithmetic,paired");

   declare
      Options : constant Benchmarks.Runner_Options :=
        Benchmarks.Parse_Command_Line (Base);
   begin
      Benchmarks.Execute (Target, "maintained", Options, Summary);
      if not Benchmarks.Successful (Summary) then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end;
exception
   when Error : Benchmarks.Option_Error =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "suite option error: " & Ada.Exceptions.Exception_Message (Error));
      Benchmarks.Put_Help (Ada.Text_IO.Standard_Error);
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Suite_Runner;
