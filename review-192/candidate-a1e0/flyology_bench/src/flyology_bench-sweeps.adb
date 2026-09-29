--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Unbounded;

package body Flyology_Bench.Sweeps is
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;

   Nanoseconds_Per_Second : constant Long_Float := 1_000_000_000.0;

   function Finite (Value : Long_Float) return Boolean
   is (Value = Value and then abs Value <= Long_Float'Last);

   function Image (Value : Interfaces.Unsigned_64) return String is
      Raw : constant String := Interfaces.Unsigned_64'Image (Value);
   begin
      return (if Raw (Raw'First) = ' ' then Raw (Raw'First + 1 .. Raw'Last) else Raw);
   end Image;

   function Valid_Name (Value : String) return Boolean is
   begin
      if Value'Length = 0 then
         return False;
      end if;
      for Index in Value'Range loop
         declare
            Ch : constant Character := Value (Index);
         begin
            if not (Ch in 'A' .. 'Z'
                    or else Ch in 'a' .. 'z'
                    or else Ch in '0' .. '9'
                    or else (Index /= Value'First and then Ch in '_' | '.' | '-'))
            then
               return False;
            end if;
         end;
      end loop;
      return True;
   end Valid_Name;

   function Error_Text (Value : String) return Errors.Bounded_String is
      Last : constant Natural := Natural'Min (Value'Length, Max_Error_Length);
   begin
      if Last = 0 then
         return Errors.Null_Bounded_String;
      end if;
      return Errors.To_Bounded_String (Value (Value'First .. Value'First + Last - 1));
   end Error_Text;

   function Point (Kind : Parameter_Kind; Value : Exact_Value; Label : String := "") return Parameter_Point is
   begin
      if Label'Length > Max_Label_Length or else (Label'Length > 0 and then not Valid_Name (Label)) then
         raise Constraint_Error with "invalid sweep point label";
      end if;
      return (Kind_Value => Kind, Exact => Value, Label_Value => Labels.To_Bounded_String (Label));
   end Point;

   function Kind (Item : Parameter_Point) return Parameter_Kind
   is (Item.Kind_Value);

   function Value (Item : Parameter_Point) return Exact_Value
   is (Item.Exact);

   function Label (Item : Parameter_Point) return String
   is (Labels.To_String (Item.Label_Value));

   function Identity (Item : Parameter_Point) return String
   is ((case Item.Kind_Value is
          when Size_Parameter  => "size:",
          when Count_Parameter => "count:")
       & Image (Item.Exact));

   procedure Append (Set : in out Point_Set; Item : Parameter_Point) is
   begin
      for Index in 1 .. Set.Count loop
         if Set.Items (Index).Kind_Value = Item.Kind_Value and then Set.Items (Index).Exact = Item.Exact then
            raise Constraint_Error with "duplicate sweep point identity " & Identity (Item);
         end if;
      end loop;
      if Set.Count = Set.Maximum_Points then
         raise Constraint_Error with "sweep point capacity exceeded";
      end if;
      Set.Count := Set.Count + 1;
      Set.Items (Set.Count) := Item;
   end Append;

   function Length (Set : Point_Set) return Natural
   is (Set.Count);

   function Element (Set : Point_Set; Index : Positive) return Parameter_Point is
   begin
      if Index > Set.Count then
         raise Constraint_Error with "sweep point index out of range";
      end if;
      return Set.Items (Index);
   end Element;

   function Work
     (Value   : Long_Float;
      Unit    : Work_Unit_Kind;
      Name    : String := "";
      Scaling : Display_Scaling := Decimal_Scaling) return Work_Amount
   is
      Exact : Exact_Value;
   begin
      if not Finite (Value) or else Value <= 0.0 or else Value /= Long_Float'Floor (Value) then
         raise Constraint_Error with "work amount must be finite, positive, and integral";
      end if;
      begin
         Exact := Exact_Value (Value);
      exception
         when Constraint_Error =>
            raise Constraint_Error with "work amount is not representable";
      end;
      if Long_Float (Exact) /= Value then
         raise Constraint_Error with "work amount lost exactness";
      end if;
      return Work (Exact, Unit, Name, Scaling);
   end Work;

   function Work
     (Value   : Exact_Value;
      Unit    : Work_Unit_Kind;
      Name    : String := "";
      Scaling : Display_Scaling := Decimal_Scaling) return Work_Amount is
   begin
      if Unit = Caller_Named then
         if Name'Length > Max_Unit_Length or else not Valid_Name (Name) then
            raise Constraint_Error with "invalid caller-named work unit";
         end if;
      elsif Name'Length /= 0 then
         raise Constraint_Error with "built-in work units cannot carry a caller name";
      end if;
      return
        (Exact => Value, Kind_Value => Unit, Name_Value => Units.To_Bounded_String (Name), Scale => Scaling);
   end Work;

   function Raw_Value (Amount : Work_Amount) return Exact_Value
   is (Amount.Exact);

   function Unit_Kind (Amount : Work_Amount) return Work_Unit_Kind
   is (Amount.Kind_Value);

   function Unit_Name (Amount : Work_Amount) return String
   is (case Amount.Kind_Value is
         when Items        => "items",
         when Bytes        => "bytes",
         when Caller_Named => Units.To_String (Amount.Name_Value));

   function Display_Scale (Amount : Work_Amount) return Display_Scaling
   is (Amount.Scale);

   function Scale_Power (Amount : Work_Amount) return Natural is
      Base  : constant Long_Float := (if Amount.Scale = Decimal_Scaling then 1_000.0 else 1_024.0);
      Limit : constant Natural := 6;
      Test  : Long_Float := Long_Float (Amount.Exact);
      Power : Natural := 0;
   begin
      while Power < Limit and then Test >= Base loop
         Test := Test / Base;
         Power := Power + 1;
      end loop;
      return Power;
   end Scale_Power;

   function Prefix (Scale : Display_Scaling; Power : Natural) return String is
   begin
      if Scale = Decimal_Scaling then
         return
           (case Power is
              when 0      => "",
              when 1      => "k",
              when 2      => "M",
              when 3      => "G",
              when 4      => "T",
              when 5      => "P",
              when others => "E");
      else
         return
           (case Power is
              when 0      => "",
              when 1      => "Ki",
              when 2      => "Mi",
              when 3      => "Gi",
              when 4      => "Ti",
              when 5      => "Pi",
              when others => "Ei");
      end if;
   end Prefix;

   function Display_Value (Amount : Work_Amount) return Long_Float is
      Base   : constant Long_Float := (if Amount.Scale = Decimal_Scaling then 1_000.0 else 1_024.0);
      Result : Long_Float := Long_Float (Amount.Exact);
   begin
      for Index in 1 .. Scale_Power (Amount) loop
         Result := Result / Base;
      end loop;
      return Result;
   end Display_Value;

   function Display_Unit (Amount : Work_Amount) return String is
      Base_Unit : constant String :=
        (case Amount.Kind_Value is
           when Items        => "items",
           when Bytes        => "B",
           when Caller_Named => Units.To_String (Amount.Name_Value));
   begin
      return Prefix (Amount.Scale, Scale_Power (Amount)) & Base_Unit;
   end Display_Unit;

   function Direction (Amount : Work_Amount) return Throughput_Direction is
      pragma Unreferenced (Amount);
   begin
      return Higher_Is_Better;
   end Direction;

   function Derive_Throughput
     (Amount                  : Work_Amount;
      Median_Nanoseconds      : Long_Float;
      Mean_Confidence_Low_NS  : Long_Float;
      Mean_Confidence_High_NS : Long_Float) return Throughput_Summary
   is
      Result     : Throughput_Summary;
      Work_Value : constant Long_Float := Long_Float (Amount.Exact);
   begin
      if not Finite (Median_Nanoseconds)
        or else not Finite (Mean_Confidence_Low_NS)
        or else not Finite (Mean_Confidence_High_NS)
        or else Median_Nanoseconds <= 0.0
        or else Mean_Confidence_Low_NS <= 0.0
        or else Mean_Confidence_High_NS < Mean_Confidence_Low_NS
      then
         Result.State := Invalid_Wall_Summary;
         return Result;
      end if;

      Result.Operations := Nanoseconds_Per_Second / Median_Nanoseconds;
      Result.Operations_Low := Nanoseconds_Per_Second / Mean_Confidence_High_NS;
      Result.Operations_High := Nanoseconds_Per_Second / Mean_Confidence_Low_NS;
      Result.Work_Rate := Result.Operations * Work_Value;
      Result.Work_Low := Result.Operations_Low * Work_Value;
      Result.Work_High := Result.Operations_High * Work_Value;
      if not Finite (Result.Operations)
        or else not Finite (Result.Operations_Low)
        or else not Finite (Result.Operations_High)
        or else not Finite (Result.Work_Rate)
        or else not Finite (Result.Work_Low)
        or else not Finite (Result.Work_High)
      then
         Result := (State => Throughput_Overflow, others => 0.0);
      else
         Result.State := Throughput_Available;
      end if;
      return Result;
   exception
      when Constraint_Error =>
         return (State => Throughput_Overflow, others => 0.0);
   end Derive_Throughput;

   function Derive_Throughput (Amount : Work_Amount; Result : Measurement) return Throughput_Summary is
      Median : constant Long_Float := Median_Nanoseconds (Result);
      Low    : constant Long_Float := Mean_Confidence_Low_Nanoseconds (Result);
      High   : constant Long_Float := Mean_Confidence_High_Nanoseconds (Result);
   begin
      if Iterations_Per_Sample (Result) = 0 or else (Median = 0.0 and then Low = 0.0 and then High = 0.0) then
         return (State => Wall_Time_Unavailable, others => 0.0);
      end if;
      return Derive_Throughput (Amount, Median, Low, High);
   exception
      when others =>
         return (State => Wall_Time_Unavailable, others => 0.0);
   end Derive_Throughput;

   function Availability (Summary : Throughput_Summary) return Throughput_Availability
   is (Summary.State);

   function Available (Summary : Throughput_Summary) return Boolean
   is (Summary.State = Throughput_Available);

   function Wall_Time_Available (Summary : Throughput_Summary) return Boolean
   is (Summary.State in Throughput_Available | Throughput_Overflow);

   function Operations_Per_Second (Summary : Throughput_Summary) return Long_Float
   is (Summary.Operations);
   function Operations_Confidence_Low (Summary : Throughput_Summary) return Long_Float
   is (Summary.Operations_Low);
   function Operations_Confidence_High (Summary : Throughput_Summary) return Long_Float
   is (Summary.Operations_High);
   function Work_Units_Per_Second (Summary : Throughput_Summary) return Long_Float
   is (Summary.Work_Rate);
   function Work_Confidence_Low (Summary : Throughput_Summary) return Long_Float
   is (Summary.Work_Low);
   function Work_Confidence_High (Summary : Throughput_Summary) return Long_Float
   is (Summary.Work_High);

   function Length (Result : Ordinary_Sweep_Result) return Natural
   is (Result.Count);
   function Length (Result : Paired_Sweep_Result) return Natural
   is (Result.Count);

   function Element (Result : Ordinary_Sweep_Result; Index : Positive) return Ordinary_Point_Result is
   begin
      if Index > Result.Count then
         raise Constraint_Error with "ordinary sweep result index out of range";
      end if;
      return Result.Items (Index);
   end Element;

   function Element (Result : Paired_Sweep_Result; Index : Positive) return Paired_Point_Result is
   begin
      if Index > Result.Count then
         raise Constraint_Error with "paired sweep result index out of range";
      end if;
      return Result.Items (Index);
   end Element;

   function Stopped_Early (Result : Ordinary_Sweep_Result) return Boolean
   is (Result.Stopped);
   function Stopped_Early (Result : Paired_Sweep_Result) return Boolean
   is (Result.Stopped);
   function Parameter (Result : Ordinary_Point_Result) return Parameter_Point
   is (Result.Point_Value);
   function Parameter (Result : Paired_Point_Result) return Parameter_Point
   is (Result.Point_Value);
   function Work_Per_Operation (Result : Ordinary_Point_Result) return Work_Amount is
   begin
      if not Result.Has_Work then
         raise Constraint_Error with "work was not established for sweep point";
      end if;
      return Result.Work_Value;
   end Work_Per_Operation;
   function Work_Per_Operation (Result : Paired_Point_Result) return Work_Amount is
   begin
      if not Result.Has_Work then
         raise Constraint_Error with "work was not established for sweep point";
      end if;
      return Result.Work_Value;
   end Work_Per_Operation;
   function Work_Available (Result : Ordinary_Point_Result) return Boolean
   is (Result.Has_Work);
   function Work_Available (Result : Paired_Point_Result) return Boolean
   is (Result.Has_Work);
   function Collection_Available (Result : Ordinary_Point_Result) return Boolean
   is (Result.Collected);
   function Collection_Available (Result : Paired_Point_Result) return Boolean
   is (Result.Collected);
   function Status (Result : Ordinary_Point_Result) return Point_Status
   is (Result.State);
   function Status (Result : Paired_Point_Result) return Point_Status
   is (Result.State);
   function Failure_Message (Result : Ordinary_Point_Result) return String
   is (Errors.To_String (Result.Message));
   function Failure_Message (Result : Paired_Point_Result) return String
   is (Errors.To_String (Result.Message));
   function Data (Result : Ordinary_Point_Result) return Measurement
   is (Result.Measurement_Value);
   function Data (Result : Paired_Point_Result) return Comparison
   is (Result.Comparison_Value);
   function Throughput (Result : Ordinary_Point_Result) return Throughput_Summary
   is (Result.Rate);
   function Reference_Throughput (Result : Paired_Point_Result) return Throughput_Summary
   is (Result.Reference_Rate);
   function Contender_Throughput (Result : Paired_Point_Result) return Throughput_Summary
   is (Result.Contender_Rate);

   function Progress_Identity (Case_Name : String; Item : Parameter_Point) return String
   is (if Case_Name'Length = 0 then Identity (Item) else Case_Name & "/" & Identity (Item));

   function Remaining_Budget (Started : Ada.Real_Time.Time; Limit : Nonnegative_Duration) return Duration is
      Elapsed : constant Duration := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
   begin
      return Duration'Max (0.0, Duration (Limit) - Elapsed);
   end Remaining_Budget;

   procedure Measure_Sweep
     (Case_Name : String;
      Points    : Point_Set;
      Config    : Configuration := Default_Configuration;
      Policy    : Sweep_Policy := (others => <>);
      Result    : out Ordinary_Sweep_Result)
   is
      Started     : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Whole_Limit : constant Nonnegative_Duration :=
        (if Policy.Budget = Whole_Sweep_Budget then Config.Maximum_Sampling_Time else 0.0);

      function Should_Stop (State : Point_Status) return Boolean
      is (State not in Point_Measured | Point_Dry_Run and then Policy.Failure = Stop_On_Point_Failure);
   begin
      Result.Count := 0;
      Result.Stopped := False;
      if Points.Count > Result.Maximum_Points then
         raise Constraint_Error with "ordinary sweep result capacity is too small";
      end if;

      for Index in 1 .. Points.Count loop
         declare
            Item         : constant Parameter_Point := Points.Items (Index);
            Item_Result  : Ordinary_Point_Result;
            Point_Config : Configuration := Config;
            Remaining    : Duration := Duration'Last;
         begin
            Item_Result.Point_Value := Item;
            Result.Count := Result.Count + 1;
            if Whole_Limit > 0.0 then
               Remaining := Remaining_Budget (Started, Whole_Limit);
               if Remaining < Duration'Small then
                  Item_Result.State := Point_Budget_Exhausted;
                  Item_Result.Message := Error_Text ("whole-sweep budget exhausted");
                  Result.Items (Result.Count) := Item_Result;
                  if Should_Stop (Item_Result.State) then
                     Result.Stopped := Index < Points.Count;
                     exit;
                  else
                     goto Continue_Point;
                  end if;
               end if;
            end if;
            Point_Config.Progress_Name :=
              Ada.Strings.Unbounded.To_Unbounded_String (Progress_Identity (Case_Name, Item));

            begin
               Item_Result.Work_Value := Work_For (Item);
               Item_Result.Has_Work := True;
               Select_Point (Item);
            exception
               when Failure : others =>
                  Item_Result.State := Point_Setup_Failed;
                  Item_Result.Message :=
                    Error_Text
                      (Ada.Exceptions.Exception_Name (Failure)
                       & ": "
                       & Ada.Exceptions.Exception_Message (Failure));
            end;

            if Item_Result.State = Point_Not_Run
              and then Policy.Mode = Collect_Measurements
              and then Whole_Limit > 0.0
            then
               Remaining := Remaining_Budget (Started, Whole_Limit);
               if Remaining < Duration'Small then
                  Item_Result.State := Point_Budget_Exhausted;
                  Item_Result.Message := Error_Text ("whole-sweep budget exhausted during point setup");
               else
                  Point_Config.Maximum_Sampling_Time := Nonnegative_Duration (Remaining);
               end if;
            end if;

            if Item_Result.State = Point_Not_Run then
               if Policy.Mode = Dry_Run then
                  Item_Result.State := Point_Dry_Run;
               else
                  begin
                     Run_Point (Point_Config, Item_Result.Measurement_Value);
                     Item_Result.Collected := True;
                     Item_Result.Rate :=
                       Derive_Throughput (Item_Result.Work_Value, Item_Result.Measurement_Value);
                     Item_Result.State :=
                       (case Availability (Item_Result.Rate) is
                          when Throughput_Available => Point_Measured,
                          when Throughput_Overflow  => Point_Throughput_Overflow,
                          when others               => Point_Wall_Time_Unavailable);
                  exception
                     when Failure : others =>
                        Item_Result.Measurement_Value := (others => <>);
                        Item_Result.Rate := (others => <>);
                        Item_Result.Collected := False;
                        Item_Result.State := Point_Measurement_Failed;
                        Item_Result.Message :=
                          Error_Text
                            (Ada.Exceptions.Exception_Name (Failure)
                             & ": "
                             & Ada.Exceptions.Exception_Message (Failure));
                  end;
               end if;
            end if;
            Result.Items (Result.Count) := Item_Result;
            if Should_Stop (Item_Result.State) then
               Result.Stopped := Index < Points.Count;
               exit;
            end if;
            <<Continue_Point>>
            null;
         end;
      end loop;
   end Measure_Sweep;

   procedure Compare_Sweep
     (Case_Name : String;
      Points    : Point_Set;
      Config    : Configuration := Default_Configuration;
      Policy    : Sweep_Policy := (others => <>);
      Result    : out Paired_Sweep_Result)
   is
      Started     : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Whole_Limit : constant Nonnegative_Duration :=
        (if Policy.Budget = Whole_Sweep_Budget then Config.Maximum_Sampling_Time else 0.0);

      function Should_Stop (State : Point_Status) return Boolean
      is (State not in Point_Measured | Point_Dry_Run and then Policy.Failure = Stop_On_Point_Failure);
   begin
      Result.Count := 0;
      Result.Stopped := False;
      if Points.Count > Result.Maximum_Points then
         raise Constraint_Error with "paired sweep result capacity is too small";
      end if;

      for Index in 1 .. Points.Count loop
         declare
            Item         : constant Parameter_Point := Points.Items (Index);
            Item_Result  : Paired_Point_Result;
            Point_Config : Configuration := Config;
            Remaining    : Duration := Duration'Last;
         begin
            Item_Result.Point_Value := Item;
            Result.Count := Result.Count + 1;
            if Whole_Limit > 0.0 then
               Remaining := Remaining_Budget (Started, Whole_Limit);
               if Remaining < Duration'Small then
                  Item_Result.State := Point_Budget_Exhausted;
                  Item_Result.Message := Error_Text ("whole-sweep budget exhausted");
                  Result.Items (Result.Count) := Item_Result;
                  if Should_Stop (Item_Result.State) then
                     Result.Stopped := Index < Points.Count;
                     exit;
                  else
                     goto Continue_Point;
                  end if;
               end if;
            end if;
            Point_Config.Progress_Name :=
              Ada.Strings.Unbounded.To_Unbounded_String (Progress_Identity (Case_Name, Item));

            begin
               Item_Result.Work_Value := Work_For (Item);
               Item_Result.Has_Work := True;
               Select_Point (Item);
            exception
               when Failure : others =>
                  Item_Result.State := Point_Setup_Failed;
                  Item_Result.Message :=
                    Error_Text
                      (Ada.Exceptions.Exception_Name (Failure)
                       & ": "
                       & Ada.Exceptions.Exception_Message (Failure));
            end;

            if Item_Result.State = Point_Not_Run
              and then Policy.Mode = Collect_Measurements
              and then Whole_Limit > 0.0
            then
               Remaining := Remaining_Budget (Started, Whole_Limit);
               if Remaining < Duration'Small then
                  Item_Result.State := Point_Budget_Exhausted;
                  Item_Result.Message := Error_Text ("whole-sweep budget exhausted during point setup");
               else
                  Point_Config.Maximum_Sampling_Time := Nonnegative_Duration (Remaining);
               end if;
            end if;

            if Item_Result.State = Point_Not_Run then
               if Policy.Mode = Dry_Run then
                  Item_Result.State := Point_Dry_Run;
               else
                  begin
                     Run_Point (Point_Config, Item_Result.Comparison_Value);
                     Item_Result.Collected := True;
                     Item_Result.Reference_Rate :=
                       Derive_Throughput
                         (Item_Result.Work_Value, Reference_Measurement (Item_Result.Comparison_Value));
                     Item_Result.Contender_Rate :=
                       Derive_Throughput
                         (Item_Result.Work_Value, Contender_Measurement (Item_Result.Comparison_Value));
                     if Availability (Item_Result.Reference_Rate) = Throughput_Overflow
                       or else Availability (Item_Result.Contender_Rate) = Throughput_Overflow
                     then
                        Item_Result.State := Point_Throughput_Overflow;
                     elsif not Available (Item_Result.Reference_Rate)
                       or else not Available (Item_Result.Contender_Rate)
                     then
                        Item_Result.State := Point_Wall_Time_Unavailable;
                     else
                        Item_Result.State := Point_Measured;
                     end if;
                  exception
                     when Failure : others =>
                        Item_Result.Comparison_Value := (others => <>);
                        Item_Result.Reference_Rate := (others => <>);
                        Item_Result.Contender_Rate := (others => <>);
                        Item_Result.Collected := False;
                        Item_Result.State := Point_Measurement_Failed;
                        Item_Result.Message :=
                          Error_Text
                            (Ada.Exceptions.Exception_Name (Failure)
                             & ": "
                             & Ada.Exceptions.Exception_Message (Failure));
                  end;
               end if;
            end if;
            Result.Items (Result.Count) := Item_Result;
            if Should_Stop (Item_Result.State) then
               Result.Stopped := Index < Points.Count;
               exit;
            end if;
            <<Continue_Point>>
            null;
         end;
      end loop;
   end Compare_Sweep;
end Flyology_Bench.Sweeps;
