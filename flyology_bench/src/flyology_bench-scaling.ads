--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Bench.Sweeps;

--  Empirical scaling analysis for stored or synthetic positive observations.
--  A selected model describes this observed range; it is not a proof of big-O.
package Flyology_Bench.Scaling is
   --  Fits bounded observations after collection without claiming big-O.

   --  Candidate empirical growth families.
   --  @enum Constant_Model Constant over the observed range.
   --  @enum Logarithmic_Model Proportional to log n.
   --  @enum Linear_Model Proportional to n.
   --  @enum N_Log_N_Model Proportional to n log n.
   --  @enum Quadratic_Model Proportional to n squared.
   --  @enum Cubic_Model Proportional to n cubed.
   type Scaling_Model is
     (Constant_Model,
      Logarithmic_Model,
      Linear_Model,
      N_Log_N_Model,
      Quadratic_Model,
      Cubic_Model);

   --  Availability of an empirical scaling result.
   --  @enum Scaling_Available A model met fit and identifiability rules.
   --  @enum Too_Few_Distinct_Points Fewer than four inputs were supplied.
   --  @enum Invalid_Observation An observation was nonpositive or non-finite.
   --  @enum Degenerate_Input_Range Inputs span less than a factor of two.
   --  @enum Scaling_Numeric_Overflow Fitting exceeded numeric bounds.
   --  @enum No_Adequate_Model No candidate met the goodness-of-fit rules.
   --  @enum Poor_Model_Identifiability Top candidates were indistinguishable.
   type Scaling_Status is
     (Scaling_Available,
      Too_Few_Distinct_Points,
      Invalid_Observation,
      Degenerate_Input_Range,
      Scaling_Numeric_Overflow,
      No_Adequate_Model,
      Poor_Model_Identifiability);

   --  Bounded ordered observations retained independently of collection.
   --  @field Maximum_Points Maximum observations stored by this value.
   type Observation_Set (Maximum_Points : Positive) is tagged private;

   --  Append one observation in retained order. Duplicate point identities and
   --  mixtures of size and count parameters are rejected. Observation validity
   --  is assessed by Analyze so invalid stored or synthetic data produces an
   --  explicit unavailable analysis.
   --  @param Set Destination bounded set.
   --  @param Point Exact positive input identity.
   --  @param Observation Positive measured or synthetic value.
   procedure Append
     (Set         : in out Observation_Set;
      Point       : Sweeps.Parameter_Point;
      Observation : Long_Float);

   --  Return the retained observation count.
   --  @param Set Observation set.
   --  @return Number of appended observations.
   function Length (Set : Observation_Set) return Natural;

   --  Diagnostics for one fixed candidate model.
   --  @field Model Candidate family.
   --  @field Available Whether its basis and arithmetic were valid.
   --  @field Selected Whether it has the smallest accepted residual.
   --  @field Coefficient Fitted multiplier in y = coefficient times f(n).
   --  @field Nominal_Exponent Polynomial exponent, excluding logarithmic terms.
   --  @field R_Squared Goodness of fit in log-observation space.
   --  @field RMS_Log_Residual Root-mean-square log residual.
   --  @field Maximum_Absolute_Log_Residual Largest absolute log residual.
   type Model_Diagnostic is record
      Model                    : Scaling_Model := Constant_Model;
      Available                : Boolean := False;
      Selected                 : Boolean := False;
      Coefficient              : Long_Float := 0.0;
      Nominal_Exponent         : Long_Float := 0.0;
      R_Squared                : Long_Float := 0.0;
      RMS_Log_Residual         : Long_Float := 0.0;
      Maximum_Absolute_Log_Residual : Long_Float := 0.0;
   end record;

   --  Selected and competing diagnostics over one observed input range.
   type Empirical_Scaling_Analysis is private;

   --  Fit y = coefficient * f(n) in log space for a fixed six-model set.
   --  At least four distinct positive points spanning a factor of two are
   --  required. An adequate selected model needs R-squared >= 0.90 and RMS
   --  log residual <= 0.10, and must be distinguishable from its competitor.
   --  @param Set Stored or synthetic observations.
   --  @return Available or explicitly unavailable empirical analysis.
   function Analyze
     (Set : Observation_Set) return Empirical_Scaling_Analysis;

   --  Return analysis availability.
   --  @param Result Empirical analysis.
   --  @return Exact availability or rejection state.
   function Status
     (Result : Empirical_Scaling_Analysis) return Scaling_Status;
   --  Test whether a model was selected adequately.
   --  @param Result Empirical analysis.
   --  @return True only for Scaling_Available.
   function Available
     (Result : Empirical_Scaling_Analysis) return Boolean;
   --  Return the lowest-residual candidate.
   --  @param Result Empirical analysis.
   --  @return Selected candidate; inspect Status before interpreting it.
   function Selected_Model
     (Result : Empirical_Scaling_Analysis) return Scaling_Model;
   --  Return one candidate's complete diagnostics.
   --  @param Result Empirical analysis.
   --  @param Model Candidate to inspect.
   --  @return Fitting diagnostics and availability.
   function Diagnostic
     (Result : Empirical_Scaling_Analysis;
      Model  : Scaling_Model) return Model_Diagnostic;
   --  Test whether the analysis has a retained parameter kind.
   --  @param Result Empirical analysis.
   --  @return False only when no observation was supplied.
   function Input_Kind_Available
     (Result : Empirical_Scaling_Analysis) return Boolean;
   --  Return the coherent parameter kind shared by all observations.
   --  @param Result Empirical analysis.
   --  @return Size or count parameter kind.
   --  @exception Constraint_Error No observation supplied a parameter kind.
   function Input_Kind
     (Result : Empirical_Scaling_Analysis) return Sweeps.Parameter_Kind;
   --  Test whether an observed input range exists.
   --  @param Result Empirical analysis.
   --  @return False only when no observation was supplied.
   function Input_Range_Available
     (Result : Empirical_Scaling_Analysis) return Boolean;
   --  Return the smallest observed input.
   --  @param Result Empirical analysis.
   --  @return Minimum exact input.
   --  @exception Constraint_Error No observation supplied an input.
   function Minimum_Input
     (Result : Empirical_Scaling_Analysis) return Sweeps.Exact_Value;
   --  Return the largest observed input.
   --  @param Result Empirical analysis.
   --  @return Maximum exact input.
   --  @exception Constraint_Error No observation supplied an input.
   function Maximum_Input
     (Result : Empirical_Scaling_Analysis) return Sweeps.Exact_Value;
   --  Return the number of supplied points.
   --  @param Result Empirical analysis.
   --  @return Observation count assessed by Analyze.
   function Points_Analyzed
     (Result : Empirical_Scaling_Analysis) return Natural;

private
   type Observation is record
      Point : Sweeps.Parameter_Point;
      Value : Long_Float := 0.0;
   end record;
   type Observation_Array is array (Positive range <>) of Observation;

   type Observation_Set (Maximum_Points : Positive) is tagged record
      Count      : Natural := 0;
      Has_Kind   : Boolean := False;
      Kind_Value : Sweeps.Parameter_Kind := Sweeps.Size_Parameter;
      Data       : Observation_Array (1 .. Maximum_Points);
   end record;

   type Diagnostic_Array is array (Scaling_Model) of Model_Diagnostic;

   type Empirical_Scaling_Analysis is record
      State        : Scaling_Status := Too_Few_Distinct_Points;
      Selected     : Scaling_Model := Constant_Model;
      Has_Kind     : Boolean := False;
      Kind_Value   : Sweeps.Parameter_Kind := Sweeps.Size_Parameter;
      Has_Range    : Boolean := False;
      Minimum      : Sweeps.Exact_Value := 1;
      Maximum      : Sweeps.Exact_Value := 1;
      Point_Count  : Natural := 0;
      Diagnostics  : Diagnostic_Array :=
        [for Model in Scaling_Model => (Model => Model, others => <>)];
   end record;
end Flyology_Bench.Scaling;
