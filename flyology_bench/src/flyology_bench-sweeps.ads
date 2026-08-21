--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Strings.Bounded;
with Interfaces;

--  Ordered benchmark parameter sweeps and work-normalized throughput views.
--  Sweep executors call a statically instantiated measurement or comparison
--  procedure once per point; parameter selection is outside every timed batch.
package Flyology_Bench.Sweeps is
   --  Maximum optional point-label length.
   Max_Label_Length : constant := 64;
   --  Maximum caller-named work-unit length.
   Max_Unit_Length  : constant := 32;
   --  Maximum retained exception-message length.
   Max_Error_Length : constant := 160;

   --  Exact positive numeric parameter or work value.
   subtype Exact_Value is
     Interfaces.Unsigned_64 range 1 .. Interfaces.Unsigned_64'Last;

   --  Meaning of an exact numeric point.
   --  @enum Size_Parameter Input size in caller-defined terms.
   --  @enum Count_Parameter Input count in caller-defined terms.
   type Parameter_Kind is (Size_Parameter, Count_Parameter);

   --  Exact bounded point identity with optional display label.
   type Parameter_Point is private;

   --  Construct one exact positive numeric point. Labels are optional stable
   --  display metadata and use [A-Za-z0-9][A-Za-z0-9_.-]*.
   --  @param Kind Meaning of the numeric input.
   --  @param Value Exact positive input.
   --  @param Label Optional stable display label.
   --  @return Validated parameter point.
   function Point
     (Kind  : Parameter_Kind;
      Value : Exact_Value;
      Label : String := "") return Parameter_Point;

   --  Return a point's parameter kind.
   --  @param Item Parameter point.
   --  @return Size or count identity.
   function Kind (Item : Parameter_Point) return Parameter_Kind;
   --  Return a point's exact input.
   --  @param Item Parameter point.
   --  @return Positive unsigned value.
   function Value (Item : Parameter_Point) return Exact_Value;
   --  Return a point's optional label.
   --  @param Item Parameter point.
   --  @return Label or an empty string.
   function Label (Item : Parameter_Point) return String;

   --  Canonical point identity, independent of the optional label.
   --  @param Item Parameter point.
   --  @return size:VALUE or count:VALUE.
   function Identity (Item : Parameter_Point) return String;

   --  Bounded ordered collection of unique parameter points.
   --  @field Maximum_Points Point capacity.
   type Point_Set (Maximum_Points : Positive) is tagged private;

   --  Append in execution order. A repeated kind/value identity is rejected
   --  even when its label differs.
   --  @param Set Destination collection.
   --  @param Item Point appended at the end.
   procedure Append (Set : in out Point_Set; Item : Parameter_Point);
   --  Return the number of points.
   --  @param Set Point collection.
   --  @return Appended point count.
   function Length (Set : Point_Set) return Natural;
   --  Return one point in execution order.
   --  @param Set Point collection.
   --  @param Index One-based position.
   --  @return Selected point.
   function Element (Set : Point_Set; Index : Positive) return Parameter_Point;

   --  Work-unit identity.
   --  @enum Items Logical items processed.
   --  @enum Bytes Bytes processed.
   --  @enum Caller_Named Caller-defined bounded unit.
   type Work_Unit_Kind is (Items, Bytes, Caller_Named);
   --  Human-readable display divisor.
   --  @enum Decimal_Scaling Powers of 1000 with SI prefixes.
   --  @enum Binary_Scaling Powers of 1024 with IEC prefixes.
   type Display_Scaling is (Decimal_Scaling, Binary_Scaling);
   --  Favorable throughput direction.
   --  @enum Higher_Is_Better More work per second is favorable.
   type Throughput_Direction is (Higher_Is_Better);

   --  Exact integral work performed by one logical operation.
   type Work_Amount is private;

   --  Construct an integral work amount per logical operation. Value must be
   --  finite, positive, exactly integral, and representable by Exact_Value.
   --  Caller_Named requires a valid Unit; built-in units require Unit = "".
   --  @param Value Integral amount supplied as a floating-point value.
   --  @param Unit Built-in or caller-named unit kind.
   --  @param Name Required only for Caller_Named.
   --  @param Scaling Human display scaling.
   --  @return Validated exact work amount.
   function Work
     (Value   : Long_Float;
      Unit    : Work_Unit_Kind;
      Name    : String := "";
      Scaling : Display_Scaling := Decimal_Scaling) return Work_Amount;

   --  Construct work from an already exact positive value.
   --  @param Value Exact integral amount.
   --  @param Unit Built-in or caller-named unit kind.
   --  @param Name Required only for Caller_Named.
   --  @param Scaling Human display scaling.
   --  @return Validated exact work amount.
   function Work
     (Value   : Exact_Value;
      Unit    : Work_Unit_Kind;
      Name    : String := "";
      Scaling : Display_Scaling := Decimal_Scaling) return Work_Amount;

   --  Return exact unscaled work.
   --  @param Amount Work identity.
   --  @return Exact raw value.
   function Raw_Value (Amount : Work_Amount) return Exact_Value;
   --  Return work-unit kind.
   --  @param Amount Work identity.
   --  @return Items, bytes, or caller-named.
   function Unit_Kind (Amount : Work_Amount) return Work_Unit_Kind;
   --  Return stable raw unit name.
   --  @param Amount Work identity.
   --  @return items, bytes, or caller name.
   function Unit_Name (Amount : Work_Amount) return String;
   --  Return the requested display scaling.
   --  @param Amount Work identity.
   --  @return Decimal or binary scaling.
   function Display_Scale (Amount : Work_Amount) return Display_Scaling;
   --  Return human-scaled work value.
   --  @param Amount Work identity.
   --  @return Raw value divided by the selected display power.
   function Display_Value (Amount : Work_Amount) return Long_Float;
   --  Return human-scaled unit.
   --  @param Amount Work identity.
   --  @return Prefixed items, bytes, or caller unit.
   function Display_Unit (Amount : Work_Amount) return String;
   --  Return the favorable rate direction.
   --  @param Amount Work identity.
   --  @return Higher_Is_Better.
   function Direction
     (Amount : Work_Amount) return Throughput_Direction;

   --  Availability of wall-derived rate summaries.
   --  @enum Throughput_Available Every rate is finite and positive.
   --  @enum Wall_Time_Unavailable No completed wall measurement exists.
   --  @enum Invalid_Wall_Summary Wall inputs are invalid or incoherent.
   --  @enum Throughput_Overflow Derived arithmetic exceeded numeric bounds.
   type Throughput_Availability is
     (Throughput_Available,
      Wall_Time_Unavailable,
      Invalid_Wall_Summary,
      Throughput_Overflow);

   --  Median and confidence-bound operations and work rates.
   type Throughput_Summary is private;

   --  Derive rate summaries from a wall-time summary. The median rates are
   --  exact inversions of Median_Nanoseconds. Confidence endpoints invert the
   --  mean-time interval and therefore reverse its endpoints.
   --  @param Amount Exact work per logical operation.
   --  @param Median_Nanoseconds Median wall time per operation.
   --  @param Mean_Confidence_Low_NS Lower mean-time interval endpoint.
   --  @param Mean_Confidence_High_NS Upper mean-time interval endpoint.
   --  @return Available or explicitly unavailable rate summary.
   function Derive_Throughput
     (Amount                   : Work_Amount;
      Median_Nanoseconds       : Long_Float;
      Mean_Confidence_Low_NS   : Long_Float;
      Mean_Confidence_High_NS  : Long_Float) return Throughput_Summary;

   --  Derive throughput from a completed wall measurement.
   --  @param Amount Exact work per logical operation.
   --  @param Result Completed or default measurement.
   --  @return Available or explicitly unavailable rate summary.
   function Derive_Throughput
     (Amount : Work_Amount;
      Result : Measurement) return Throughput_Summary;

   --  Return rate availability.
   --  @param Summary Derived rate summary.
   --  @return Exact availability state.
   function Availability
     (Summary : Throughput_Summary) return Throughput_Availability;
   --  Test whether all rates are usable.
   --  @param Summary Derived rate summary.
   --  @return True only for Throughput_Available.
   function Available (Summary : Throughput_Summary) return Boolean;
   --  Test whether the source wall summary remains valid. This is true when
   --  rate arithmetic overflowed after validating the collected wall values.
   --  @param Summary Derived rate summary.
   --  @return True for available rates or throughput-only overflow.
   function Wall_Time_Available
     (Summary : Throughput_Summary) return Boolean;
   --  Return median logical operations per second.
   --  @param Summary Derived rate summary.
   --  @return Median wall-rate inversion, or zero when unavailable.
   function Operations_Per_Second
     (Summary : Throughput_Summary) return Long_Float;
   --  Return lower operations-per-second confidence endpoint.
   --  @param Summary Derived rate summary.
   --  @return Inverted upper mean-time endpoint, or zero.
   function Operations_Confidence_Low
     (Summary : Throughput_Summary) return Long_Float;
   --  Return upper operations-per-second confidence endpoint.
   --  @param Summary Derived rate summary.
   --  @return Inverted lower mean-time endpoint, or zero.
   function Operations_Confidence_High
     (Summary : Throughput_Summary) return Long_Float;
   --  Return median work units per second.
   --  @param Summary Derived rate summary.
   --  @return Median operations rate times raw work, or zero.
   function Work_Units_Per_Second
     (Summary : Throughput_Summary) return Long_Float;
   --  Return lower work-rate confidence endpoint.
   --  @param Summary Derived rate summary.
   --  @return Lower operations endpoint times raw work, or zero.
   function Work_Confidence_Low
     (Summary : Throughput_Summary) return Long_Float;
   --  Return upper work-rate confidence endpoint.
   --  @param Summary Derived rate summary.
   --  @return Upper operations endpoint times raw work, or zero.
   function Work_Confidence_High
     (Summary : Throughput_Summary) return Long_Float;

   --  Behavior after one point cannot produce a valid measurement.
   --  @enum Stop_On_Point_Failure Retain failure and stop before later points.
   --  @enum Continue_After_Point_Failure Retain failure and attempt later points.
   type Sweep_Failure_Policy is
     (Stop_On_Point_Failure, Continue_After_Point_Failure);
   --  Interpretation of Configuration.Maximum_Sampling_Time.
   --  @enum Per_Point_Budget Apply the limit independently at every point.
   --  @enum Whole_Sweep_Budget Treat the limit as total outer elapsed time.
   type Sweep_Budget_Scope is (Per_Point_Budget, Whole_Sweep_Budget);
   --  Whether timed measurement occurs.
   --  @enum Collect_Measurements Select and measure every attempted point.
   --  @enum Dry_Run Validate selection and work only; produce no rate.
   type Sweep_Mode is (Collect_Measurements, Dry_Run);

   --  Per_Point_Budget passes Config.Maximum_Sampling_Time unchanged to every
   --  point. Whole_Sweep_Budget interprets that field as an outer elapsed-time
   --  budget, including selection, warmup, calibration, and collection; each
   --  point receives the remaining duration as its collection limit. Zero is
   --  unlimited in either mode.
   --  @field Failure Stop or continue after one failed point.
   --  @field Budget Per-point or whole-sweep budget interpretation.
   --  @field Mode Measurement or unmistakable dry run.
   type Sweep_Policy is record
      Failure : Sweep_Failure_Policy := Stop_On_Point_Failure;
      Budget  : Sweep_Budget_Scope := Per_Point_Budget;
      Mode    : Sweep_Mode := Collect_Measurements;
   end record;

   --  Exact outcome for one attempted point.
   --  @enum Point_Not_Run Internal initial state.
   --  @enum Point_Measured Valid wall measurement and throughput.
   --  @enum Point_Dry_Run Selection succeeded without timing.
   --  @enum Point_Setup_Failed Work or selection raised.
   --  @enum Point_Measurement_Failed Measurement raised.
   --  @enum Point_Budget_Exhausted Whole-sweep budget ended before the point.
   --  @enum Point_Wall_Time_Unavailable Wall summary could not derive a rate.
   --  @enum Point_Throughput_Overflow Rate arithmetic overflowed.
   type Point_Status is
     (Point_Not_Run,
      Point_Measured,
      Point_Dry_Run,
      Point_Setup_Failed,
      Point_Measurement_Failed,
      Point_Budget_Exhausted,
      Point_Wall_Time_Unavailable,
      Point_Throughput_Overflow);

   --  Inspectable ordinary measurement and rate for one exact point.
   type Ordinary_Point_Result is private;
   --  Inspectable adjacent paired comparison and rates for one exact point.
   type Paired_Point_Result is private;

   --  Bounded ordinary point results in attempted order.
   --  @field Maximum_Points Result capacity.
   type Ordinary_Sweep_Result (Maximum_Points : Positive) is private;
   --  Bounded paired point results in attempted order.
   --  @field Maximum_Points Result capacity.
   type Paired_Sweep_Result (Maximum_Points : Positive) is private;

   --  Return retained ordinary point count.
   --  @param Result Ordinary sweep.
   --  @return Attempted point count.
   function Length (Result : Ordinary_Sweep_Result) return Natural;
   --  Return retained paired point count.
   --  @param Result Paired sweep.
   --  @return Attempted point count.
   function Length (Result : Paired_Sweep_Result) return Natural;
   --  Return one ordinary point result.
   --  @param Result Ordinary sweep.
   --  @param Index One-based attempted position.
   --  @return Inspectable point result.
   function Element
     (Result : Ordinary_Sweep_Result;
      Index  : Positive) return Ordinary_Point_Result;
   --  Return one paired point result.
   --  @param Result Paired sweep.
   --  @param Index One-based attempted position.
   --  @return Inspectable point result.
   function Element
     (Result : Paired_Sweep_Result;
      Index  : Positive) return Paired_Point_Result;
   --  Test whether failure policy stopped an ordinary sweep.
   --  @param Result Ordinary sweep.
   --  @return True when registered points remain unattempted.
   function Stopped_Early (Result : Ordinary_Sweep_Result) return Boolean;
   --  Test whether failure policy stopped a paired sweep.
   --  @param Result Paired sweep.
   --  @return True when registered points remain unattempted.
   function Stopped_Early (Result : Paired_Sweep_Result) return Boolean;

   --  Return an ordinary result's exact point.
   --  @param Result Point result.
   --  @return Parameter identity and label.
   function Parameter (Result : Ordinary_Point_Result) return Parameter_Point;
   --  Return a paired result's exact point.
   --  @param Result Point result.
   --  @return Parameter identity and label.
   function Parameter (Result : Paired_Point_Result) return Parameter_Point;
   --  Return ordinary work per logical operation.
   --  @param Result Point result.
   --  @return Exact work identity.
   --  @exception Constraint_Error Work was not established.
   function Work_Per_Operation
     (Result : Ordinary_Point_Result) return Work_Amount;
   --  Return paired work per logical operation.
   --  @param Result Point result.
   --  @return Exact work identity shared by both sides.
   --  @exception Constraint_Error Work was not established.
   function Work_Per_Operation
     (Result : Paired_Point_Result) return Work_Amount;
   --  Test whether ordinary setup established exact work.
   --  @param Result Point result.
   --  @return False when work failed or the point was skipped before setup.
   function Work_Available
     (Result : Ordinary_Point_Result) return Boolean;
   --  Test whether paired setup established exact work.
   --  @param Result Point result.
   --  @return False when work failed or the point was skipped before setup.
   function Work_Available
     (Result : Paired_Point_Result) return Boolean;
   --  Test whether the ordinary runner returned a measurement.
   --  @param Result Point result.
   --  @return True even when only the later throughput derivation failed.
   function Collection_Available
     (Result : Ordinary_Point_Result) return Boolean;
   --  Test whether the paired runner returned a comparison.
   --  @param Result Point result.
   --  @return True even when only the later throughput derivation failed.
   function Collection_Available
     (Result : Paired_Point_Result) return Boolean;
   --  Return an ordinary point's exact outcome.
   --  @param Result Point result.
   --  @return Point status.
   function Status (Result : Ordinary_Point_Result) return Point_Status;
   --  Return a paired point's exact outcome.
   --  @param Result Point result.
   --  @return Point status.
   function Status (Result : Paired_Point_Result) return Point_Status;
   --  Return a retained ordinary failure message.
   --  @param Result Point result.
   --  @return Bounded exception identity/message or empty string.
   function Failure_Message (Result : Ordinary_Point_Result) return String;
   --  Return a retained paired failure message.
   --  @param Result Point result.
   --  @return Bounded exception identity/message or empty string.
   function Failure_Message (Result : Paired_Point_Result) return String;
   --  Return ordinary measurement storage.
   --  @param Result Point result.
   --  @return Completed or default measurement according to Collection_Available.
   function Data (Result : Ordinary_Point_Result) return Measurement;
   --  Return paired comparison storage.
   --  @param Result Point result.
   --  @return Completed or default comparison according to Collection_Available.
   function Data (Result : Paired_Point_Result) return Comparison;
   --  Return ordinary wall-derived throughput.
   --  @param Result Point result.
   --  @return Available or explicitly unavailable rate summary.
   function Throughput
     (Result : Ordinary_Point_Result) return Throughput_Summary;
   --  Return reference-side throughput.
   --  @param Result Paired point result.
   --  @return Reference rate summary.
   function Reference_Throughput
     (Result : Paired_Point_Result) return Throughput_Summary;
   --  Return contender-side throughput.
   --  @param Result Paired point result.
   --  @return Contender rate summary.
   function Contender_Throughput
     (Result : Paired_Point_Result) return Throughput_Summary;

   generic
      --  Select input/fixture state before measurement starts.
      with procedure Select_Point (Item : Parameter_Point);
      --  State exact logical work before measurement starts.
      with function Work_For (Item : Parameter_Point) return Work_Amount;
      --  Normally an already-instantiated Flyology_Bench.Measure procedure.
      with procedure Run_Point
        (Config : Configuration;
         Result : out Measurement);
   --  Execute an ordered ordinary sweep with statically bound formals.
   --  @param Case_Name Suite-compatible full benchmark identity.
   --  @param Points Ordered exact points.
   --  @param Config Base runner configuration.
   --  @param Policy Budget, failure, and dry-run policy.
   --  @param Result Bounded inspectable outcomes.
   procedure Measure_Sweep
     (Case_Name : String;
      Points    : Point_Set;
      Config    : Configuration := Default_Configuration;
      Policy    : Sweep_Policy := (others => <>);
      Result    : out Ordinary_Sweep_Result);

   generic
      with procedure Select_Point (Item : Parameter_Point);
      with function Work_For (Item : Parameter_Point) return Work_Amount;
      --  Normally an already-instantiated adjacent, order-balanced Compare or
      --  Compare_Batched procedure. It is invoked once at every point.
      with procedure Run_Point
        (Config : Configuration;
         Result : out Comparison);
   --  Execute an ordered adjacent paired sweep with statically bound formals.
   --  @param Case_Name Suite-compatible full benchmark identity.
   --  @param Points Ordered exact points.
   --  @param Config Base comparison configuration.
   --  @param Policy Budget, failure, and dry-run policy.
   --  @param Result Bounded inspectable outcomes.
   procedure Compare_Sweep
     (Case_Name : String;
      Points    : Point_Set;
      Config    : Configuration := Default_Configuration;
      Policy    : Sweep_Policy := (others => <>);
      Result    : out Paired_Sweep_Result);

private
   package Labels is new Ada.Strings.Bounded.Generic_Bounded_Length
     (Max => Max_Label_Length);
   package Units is new Ada.Strings.Bounded.Generic_Bounded_Length
     (Max => Max_Unit_Length);
   package Errors is new Ada.Strings.Bounded.Generic_Bounded_Length
     (Max => Max_Error_Length);

   type Parameter_Point is record
      Kind_Value  : Parameter_Kind := Size_Parameter;
      Exact       : Exact_Value := 1;
      Label_Value : Labels.Bounded_String := Labels.Null_Bounded_String;
   end record;

   type Point_Array is array (Positive range <>) of Parameter_Point;
   type Point_Set (Maximum_Points : Positive) is tagged record
      Count : Natural := 0;
      Items : Point_Array (1 .. Maximum_Points);
   end record;

   type Work_Amount is record
      Exact      : Exact_Value := 1;
      Kind_Value : Work_Unit_Kind := Items;
      Name_Value : Units.Bounded_String := Units.Null_Bounded_String;
      Scale      : Display_Scaling := Decimal_Scaling;
   end record;

   type Throughput_Summary is record
      State          : Throughput_Availability := Wall_Time_Unavailable;
      Operations     : Long_Float := 0.0;
      Operations_Low : Long_Float := 0.0;
      Operations_High : Long_Float := 0.0;
      Work_Rate      : Long_Float := 0.0;
      Work_Low       : Long_Float := 0.0;
      Work_High      : Long_Float := 0.0;
   end record;

   type Ordinary_Point_Result is record
      Point_Value : Parameter_Point;
      Work_Value  : Work_Amount;
      Has_Work    : Boolean := False;
      Collected   : Boolean := False;
      State       : Point_Status := Point_Not_Run;
      Message     : Errors.Bounded_String := Errors.Null_Bounded_String;
      Measurement_Value : Measurement;
      Rate        : Throughput_Summary;
   end record;

   type Paired_Point_Result is record
      Point_Value : Parameter_Point;
      Work_Value  : Work_Amount;
      Has_Work    : Boolean := False;
      Collected   : Boolean := False;
      State       : Point_Status := Point_Not_Run;
      Message     : Errors.Bounded_String := Errors.Null_Bounded_String;
      Comparison_Value : Comparison;
      Reference_Rate : Throughput_Summary;
      Contender_Rate : Throughput_Summary;
   end record;

   type Ordinary_Result_Array is
     array (Positive range <>) of Ordinary_Point_Result;
   type Paired_Result_Array is
     array (Positive range <>) of Paired_Point_Result;

   type Ordinary_Sweep_Result (Maximum_Points : Positive) is record
      Count   : Natural := 0;
      Stopped : Boolean := False;
      Items   : Ordinary_Result_Array (1 .. Maximum_Points);
   end record;

   type Paired_Sweep_Result (Maximum_Points : Positive) is record
      Count   : Natural := 0;
      Stopped : Boolean := False;
      Items   : Paired_Result_Array (1 .. Maximum_Points);
   end record;
end Flyology_Bench.Sweeps;
