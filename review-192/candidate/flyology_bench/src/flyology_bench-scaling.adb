--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Numerics.Long_Elementary_Functions;
with Flyology_Bench.Scaling_Policy;

package body Flyology_Bench.Scaling is
   use type Sweeps.Exact_Value;
   use type Sweeps.Parameter_Kind;

   Minimum_Point_Count      : constant := 4;
   Minimum_R_Squared        : constant Long_Float := 0.90;
   Maximum_RMS_Log_Residual : constant Long_Float := 0.10;
   Identifiability_Margin   : constant Long_Float := 0.000_1;
   Tiny                     : constant Long_Float := 1.0E-12;

   function Finite (Value : Long_Float) return Boolean
   is (Value = Value and then abs Value <= Long_Float'Last);

   procedure Append (Set : in out Observation_Set; Point : Sweeps.Parameter_Point; Observation : Long_Float)
   is
   begin
      if Set.Has_Kind and then Sweeps.Kind (Point) /= Set.Kind_Value then
         raise Constraint_Error with "empirical scaling cannot mix size and count parameters";
      end if;
      for Index in 1 .. Set.Count loop
         if Sweeps.Value (Set.Data (Index).Point) = Sweeps.Value (Point) then
            raise Constraint_Error
              with "duplicate empirical-scaling numeric input " & Sweeps.Identity (Point);
         end if;
      end loop;
      if Set.Count = Set.Maximum_Points then
         raise Constraint_Error with "empirical-scaling observation capacity exceeded";
      end if;
      if not Set.Has_Kind then
         Set.Kind_Value := Sweeps.Kind (Point);
         Set.Has_Kind := True;
      end if;
      Set.Count := Set.Count + 1;
      Set.Data (Set.Count) := (Point => Point, Value => Observation);
   end Append;

   function Length (Set : Observation_Set) return Natural
   is (Set.Count);

   function Log_Basis (Model : Scaling_Model; Input : Long_Float; Valid : out Boolean) return Long_Float is
      Log_N : Long_Float;
   begin
      Valid := Input > 0.0 and then Finite (Input);
      if not Valid then
         return 0.0;
      end if;
      Log_N := Ada.Numerics.Long_Elementary_Functions.Log (Input);
      case Model is
         when Constant_Model    =>
            return 0.0;

         when Logarithmic_Model =>
            Valid := Log_N > 0.0;
            return (if Valid then Ada.Numerics.Long_Elementary_Functions.Log (Log_N) else 0.0);

         when Linear_Model      =>
            return Log_N;

         when N_Log_N_Model     =>
            Valid := Log_N > 0.0;
            return (if Valid then Log_N + Ada.Numerics.Long_Elementary_Functions.Log (Log_N) else 0.0);

         when Quadratic_Model   =>
            return 2.0 * Log_N;

         when Cubic_Model       =>
            return 3.0 * Log_N;
      end case;
   exception
      when Constraint_Error =>
         Valid := False;
         return 0.0;
   end Log_Basis;

   function Nominal_Exponent (Model : Scaling_Model) return Long_Float
   is (case Model is
         when Constant_Model | Logarithmic_Model => 0.0,
         when Linear_Model | N_Log_N_Model       => 1.0,
         when Quadratic_Model                    => 2.0,
         when Cubic_Model                        => 3.0);

   function Analyze (Set : Observation_Set) return Empirical_Scaling_Analysis is
      Result           : Empirical_Scaling_Analysis;
      Minimum          : Sweeps.Exact_Value := Sweeps.Exact_Value'Last;
      Maximum          : Sweeps.Exact_Value := 1;
      Sum_Log_Y        : Long_Float := 0.0;
      Mean_Log_Y       : Long_Float := 0.0;
      TSS              : Long_Float := 0.0;
      Best_RMS         : Long_Float := Long_Float'Last;
      Second_RMS       : Long_Float := Long_Float'Last;
      Best             : Scaling_Model := Constant_Model;
      Available_Models : Natural := 0;
   begin
      for Model in Scaling_Model loop
         Result.Diagnostics (Model).Model := Model;
         Result.Diagnostics (Model).Nominal_Exponent := Nominal_Exponent (Model);
      end loop;
      Result.Point_Count := Set.Count;
      Result.Has_Kind := Set.Has_Kind;
      Result.Kind_Value := Set.Kind_Value;
      if Set.Count > 0 then
         for Index in 1 .. Set.Count loop
            declare
               Input : constant Sweeps.Exact_Value := Sweeps.Value (Set.Data (Index).Point);
            begin
               Minimum := Sweeps.Exact_Value'Min (Minimum, Input);
               Maximum := Sweeps.Exact_Value'Max (Maximum, Input);
            end;
         end loop;
         Result.Has_Range := True;
         Result.Minimum := Minimum;
         Result.Maximum := Maximum;
      end if;
      if Set.Count < Minimum_Point_Count then
         Result.State := Too_Few_Distinct_Points;
         return Result;
      end if;

      for Index in 1 .. Set.Count loop
         declare
            Observed : constant Long_Float := Set.Data (Index).Value;
         begin
            if not Finite (Observed) or else Observed <= 0.0 then
               Result.State := Invalid_Observation;
               return Result;
            end if;
            Sum_Log_Y := Sum_Log_Y + Ada.Numerics.Long_Elementary_Functions.Log (Observed);
         exception
            when Constraint_Error =>
               Result.State := Scaling_Numeric_Overflow;
               return Result;
         end;
      end loop;

      if Scaling_Policy.Range_Is_Degenerate (Minimum, Maximum) then
         Result.State := Degenerate_Input_Range;
         return Result;
      end if;

      Mean_Log_Y := Sum_Log_Y / Long_Float (Set.Count);
      for Index in 1 .. Set.Count loop
         declare
            Log_Y : constant Long_Float :=
              Ada.Numerics.Long_Elementary_Functions.Log (Set.Data (Index).Value);
         begin
            TSS := TSS + (Log_Y - Mean_Log_Y)**2;
         end;
      end loop;

      for Model in Scaling_Model loop
         declare
            Diagnostic       : Model_Diagnostic :=
              (Model => Model, Nominal_Exponent => Nominal_Exponent (Model), others => <>);
            Sum_Intercept    : Long_Float := 0.0;
            Intercept        : Long_Float := 0.0;
            SSE              : Long_Float := 0.0;
            Maximum_Residual : Long_Float := 0.0;
            Model_Valid      : Boolean := True;
         begin
            for Index in 1 .. Set.Count loop
               declare
                  Basis_Valid : Boolean;
                  Log_F       : constant Long_Float :=
                    Log_Basis (Model, Long_Float (Sweeps.Value (Set.Data (Index).Point)), Basis_Valid);
                  Log_Y       : constant Long_Float :=
                    Ada.Numerics.Long_Elementary_Functions.Log (Set.Data (Index).Value);
               begin
                  if not Basis_Valid or else not Finite (Log_F) then
                     Model_Valid := False;
                     exit;
                  end if;
                  Sum_Intercept := Sum_Intercept + Log_Y - Log_F;
               end;
            end loop;

            if Model_Valid then
               Intercept := Sum_Intercept / Long_Float (Set.Count);
               Diagnostic.Coefficient := Ada.Numerics.Long_Elementary_Functions.Exp (Intercept);
               if not Finite (Diagnostic.Coefficient) or else Diagnostic.Coefficient <= 0.0 then
                  Model_Valid := False;
               end if;
            end if;

            if Model_Valid then
               for Index in 1 .. Set.Count loop
                  declare
                     Basis_Valid : Boolean;
                     Log_F       : constant Long_Float :=
                       Log_Basis (Model, Long_Float (Sweeps.Value (Set.Data (Index).Point)), Basis_Valid);
                     Log_Y       : constant Long_Float :=
                       Ada.Numerics.Long_Elementary_Functions.Log (Set.Data (Index).Value);
                     Residual    : constant Long_Float := Log_Y - (Intercept + Log_F);
                  begin
                     pragma Assert (Basis_Valid);
                     SSE := SSE + Residual**2;
                     Maximum_Residual := Long_Float'Max (Maximum_Residual, abs Residual);
                  end;
               end loop;
               Diagnostic.Available := True;
               Diagnostic.RMS_Log_Residual :=
                 Ada.Numerics.Long_Elementary_Functions.Sqrt (SSE / Long_Float (Set.Count));
               Diagnostic.Maximum_Absolute_Log_Residual := Maximum_Residual;
               Diagnostic.R_Squared :=
                 (if TSS <= Tiny then (if SSE <= Tiny then 1.0 else 0.0) else 1.0 - SSE / TSS);
               Available_Models := Available_Models + 1;

               if Diagnostic.RMS_Log_Residual < Best_RMS then
                  Second_RMS := Best_RMS;
                  Best_RMS := Diagnostic.RMS_Log_Residual;
                  Best := Model;
               elsif Diagnostic.RMS_Log_Residual < Second_RMS then
                  Second_RMS := Diagnostic.RMS_Log_Residual;
               end if;
            end if;
            Result.Diagnostics (Model) := Diagnostic;
         exception
            when Constraint_Error =>
               Result.Diagnostics (Model) := Diagnostic;
         end;
      end loop;

      if Available_Models = 0 then
         Result.State := Scaling_Numeric_Overflow;
         return Result;
      end if;

      Result.Selected := Best;
      if Best_RMS > Maximum_RMS_Log_Residual or else Result.Diagnostics (Best).R_Squared < Minimum_R_Squared
      then
         Result.State := No_Adequate_Model;
      elsif Available_Models > 1 and then Second_RMS - Best_RMS <= Identifiability_Margin then
         Result.State := Poor_Model_Identifiability;
      else
         Result.State := Scaling_Available;
         Result.Diagnostics (Best).Selected := True;
      end if;
      return Result;
   exception
      when Constraint_Error =>
         Result.State := Scaling_Numeric_Overflow;
         return Result;
   end Analyze;

   function Status (Result : Empirical_Scaling_Analysis) return Scaling_Status
   is (Result.State);
   function Available (Result : Empirical_Scaling_Analysis) return Boolean
   is (Result.State = Scaling_Available);
   function Selected_Model (Result : Empirical_Scaling_Analysis) return Scaling_Model
   is (Result.Selected);
   function Diagnostic (Result : Empirical_Scaling_Analysis; Model : Scaling_Model) return Model_Diagnostic
   is (Result.Diagnostics (Model));
   function Input_Kind_Available (Result : Empirical_Scaling_Analysis) return Boolean
   is (Result.Has_Kind);
   function Input_Kind (Result : Empirical_Scaling_Analysis) return Sweeps.Parameter_Kind is
   begin
      if not Result.Has_Kind then
         raise Constraint_Error with "empirical scaling has no parameter kind";
      end if;
      return Result.Kind_Value;
   end Input_Kind;
   function Input_Range_Available (Result : Empirical_Scaling_Analysis) return Boolean
   is (Result.Has_Range);
   function Minimum_Input (Result : Empirical_Scaling_Analysis) return Sweeps.Exact_Value is
   begin
      if not Result.Has_Range then
         raise Constraint_Error with "empirical scaling has no input range";
      end if;
      return Result.Minimum;
   end Minimum_Input;
   function Maximum_Input (Result : Empirical_Scaling_Analysis) return Sweeps.Exact_Value is
   begin
      if not Result.Has_Range then
         raise Constraint_Error with "empirical scaling has no input range";
      end if;
      return Result.Maximum;
   end Maximum_Input;
   function Points_Analyzed (Result : Empirical_Scaling_Analysis) return Natural
   is (Result.Point_Count);
end Flyology_Bench.Scaling;
