--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Environment_Variables;
with Ada.Characters.Handling;
with Flyology_Bench.Metadata;
with Interfaces.C;

package body Flyology_Bench.Reporters is
   package Float_IO is new Ada.Text_IO.Float_IO (Long_Float);
   use type Interfaces.C.int;
   use type Interfaces.Unsigned_64;

   ESC : constant Character := Character'Val (27);
   Reset : constant String := ESC & "[0m";
   Bold : constant String := ESC & "[1m";
   Dim : constant String := ESC & "[2m";
   Cyan : constant String := ESC & "[36m";
   Green : constant String := ESC & "[32m";
   Yellow : constant String := ESC & "[33m";
   Red : constant String := ESC & "[31m";
   Magenta : constant String := ESC & "[35m";

   function Isatty (Descriptor : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, Isatty, "isatty");

   function Native_Clock_Now
     (Value : access Interfaces.Unsigned_64) return Interfaces.C.int;
   pragma Import (C, Native_Clock_Now, "flyology_bench_clock_now");

   function Native_Process_Usage
     (CPU_Nanoseconds : access Interfaces.Unsigned_64;
      Resident_Bytes  : access Interfaces.Unsigned_64) return Interfaces.C.int;
   pragma Import (C, Native_Process_Usage, "flyology_bench_process_usage");

   function Image
     (Value : Long_Float;
      Aft   : Natural := 3) return String;
   function Time_Change_Image (Value : Long_Float) return String;
   function Schedule_Name (Value : Shootout_Schedule_Policy) return String;
   function Batching_Name (Value : Comparison_Batch_Policy) return String;

   function Memory_Image (Bytes : Long_Float) return String;
   function Pad (Value : String; Width : Positive) return String;
   function Left_Pad (Value : String; Width : Positive) return String;
   function Elapsed_Image
     (Nanoseconds : Interfaces.Unsigned_64) return String;

   function Terminal_ANSI return Boolean is
     (Isatty (Interfaces.C.int (1)) = 1
      and then not Ada.Environment_Variables.Exists ("NO_COLOR")
      and then
        (not Ada.Environment_Variables.Exists ("TERM")
         or else Ada.Environment_Variables.Value ("TERM") /= "dumb"));

   function Styled (Style : Console_Style) return Boolean is
     (Style = ANSI or else (Style = Auto and then Terminal_ANSI));

   function Phase_Name (Phase : Progress_Phase) return String is
   begin
      case Phase is
         when Starting                    => return "preparing benchmark";
         when Waiting_For_CPU_Quiescence => return "waiting for quiet CPU";
         when Warming                     => return "warming workload";
         when Calibrating                 => return "calibrating batch";
         when Sampling                    => return "collecting samples";
         when Analyzing                   => return "analyzing distribution";
         when Finished                    => return "benchmark complete";
      end case;
   end Phase_Name;

   Last_Progress_Phase : Progress_Phase := Finished;
   Last_Progress_Percent : Natural := 101;
   Last_Progress_Name : Ada.Strings.Unbounded.Unbounded_String :=
     Ada.Strings.Unbounded.Null_Unbounded_String;
   Progress_Start_RSS : Interfaces.Unsigned_64 := 0;
   Previous_CPU_Time : Interfaces.Unsigned_64 := 0;
   Previous_Wall_Time : Interfaces.Unsigned_64 := 0;
   Progress_Start_Wall : Interfaces.Unsigned_64 := 0;
   Total_Wall_Elapsed : Interfaces.Unsigned_64 := 0;
   Telemetry_Capacity : constant := 128;
   type Telemetry_Array is array (Positive range 1 .. Telemetry_Capacity)
     of Long_Float;
   CPU_History : Telemetry_Array := (others => 0.0);
   RSS_History : Telemetry_Array := (others => 0.0);
   Telemetry_Count : Natural := 0;
   Telemetry_Ready : Boolean := False;

   procedure Record_Telemetry
     (CPU_Percent : Long_Float;
      RSS_Bytes   : Long_Float) is
   begin
      if Telemetry_Count < Telemetry_Capacity then
         Telemetry_Count := Telemetry_Count + 1;
      else
         for Index in 1 .. Telemetry_Capacity - 1 loop
            CPU_History (Index) := CPU_History (Index + 1);
            RSS_History (Index) := RSS_History (Index + 1);
         end loop;
      end if;
      CPU_History (Telemetry_Count) := CPU_Percent;
      RSS_History (Telemetry_Count) := RSS_Bytes;
   end Record_Telemetry;

   function Elapsed_Image
     (Nanoseconds : Interfaces.Unsigned_64) return String
   is
      function Two_Digits (Value : Natural) return String is
        (Character'Val (Character'Pos ('0') + (Value / 10) mod 10)
         & Character'Val (Character'Pos ('0') + Value mod 10));
      Max_Tenths : constant Interfaces.Unsigned_64 := 3_599_999;
      Tenths_64 : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64'Min (Max_Tenths, Nanoseconds / 100_000_000);
      Tenths : constant Natural := Natural (Tenths_64);
      Hours : constant Natural := Tenths / 36_000;
      Minutes : constant Natural := (Tenths / 600) mod 60;
      Seconds : constant Natural := (Tenths / 10) mod 60;
      Fraction : constant Natural := Tenths mod 10;
   begin
      return Two_Digits (Hours) & ":" & Two_Digits (Minutes) & ":"
        & Two_Digits (Seconds) & "."
        & Character'Val (Character'Pos ('0') + Fraction);
   end Elapsed_Image;

   procedure Terminal_Progress
     (Name      : String;
      Phase     : Progress_Phase;
      Completed : Natural;
      Total     : Natural)
   is
      Width  : constant Positive := 24;
      Filled : Natural := 0;
      Percent : Natural := 0;
      CPU_Time : aliased Interfaces.Unsigned_64 := 0;
      RSS : aliased Interfaces.Unsigned_64 := 0;
      Wall_Time : aliased Interfaces.Unsigned_64 := 0;
      CPU_Percent : Long_Float := 0.0;
      Usage_Available : Boolean := False;
      Name_Separator : constant Natural :=
        Ada.Strings.Fixed.Index (Name, " / ");
   begin
      if Total > 0 then
         Percent := Natural'Min (100, Completed * 100 / Total);
         if Phase = Last_Progress_Phase
           and then Percent = Last_Progress_Percent
           and then Name = Ada.Strings.Unbounded.To_String (Last_Progress_Name)
         then
            return;
         end if;
      end if;
      Usage_Available :=
        Native_Process_Usage (CPU_Time'Access, RSS'Access) = 0
        and then Native_Clock_Now (Wall_Time'Access) = 0;
      if Usage_Available then
         if Phase = Starting or else Previous_Wall_Time = 0 then
            Progress_Start_RSS := RSS;
            Progress_Start_Wall := Wall_Time;
            Total_Wall_Elapsed := 0;
            Telemetry_Count := 0;
            Telemetry_Ready := False;
         elsif Wall_Time > Previous_Wall_Time then
            CPU_Percent :=
              100.0 * Long_Float (CPU_Time - Previous_CPU_Time)
              / Long_Float (Wall_Time - Previous_Wall_Time);
         end if;
         Previous_CPU_Time := CPU_Time;
         Previous_Wall_Time := Wall_Time;
         Total_Wall_Elapsed := Wall_Time - Progress_Start_Wall;
         Record_Telemetry (CPU_Percent, Long_Float (RSS));
         if Phase = Finished then
            Telemetry_Ready := True;
         end if;
      end if;
      if Terminal_ANSI then
         if Total > 0 then
            Filled := Natural'Min (Width, Completed * Width / Total);
         end if;
         Ada.Text_IO.Put (ASCII.CR & ESC & "[2K" & Magenta & "  fly " & Reset);
         if Name'Length > 0 then
            if Name_Separator = 0 then
               Ada.Text_IO.Put (Bold & Name & Reset & Dim & "  /  " & Reset);
            else
               Ada.Text_IO.Put
                 (Bold & Name (Name'First .. Name_Separator - 1) & Reset
                  & Dim & "  /  " & Reset
                  & Bold
                  & Pad (Name (Name_Separator + 3 .. Name'Last), 24)
                  & Reset & Dim & "  /  " & Reset);
            end if;
         end if;
         Ada.Text_IO.Put (Bold & Pad (Phase_Name (Phase), 23) & Reset);
         if Total > 0 and then Phase /= Finished then
            Ada.Text_IO.Put ("  " & Dim & "[");
            for Index in 1 .. Width loop
               Ada.Text_IO.Put (if Index <= Filled then "=" else "-");
            end loop;
            Ada.Text_IO.Put
              ("] " & Reset
               & Left_Pad
                   (Ada.Strings.Fixed.Trim
                      (Natural'Image (Percent), Ada.Strings.Both), 3)
               & "%");
         else
            Ada.Text_IO.Put ("  " & (1 .. 30 => ' '));
         end if;
         if Phase = Waiting_For_CPU_Quiescence then
            Ada.Text_IO.Put
              (Dim & "  host CPU gate"
               & "  elapsed " & Elapsed_Image (Total_Wall_Elapsed)
               & " (hh:mm:ss)" & Reset);
         elsif Usage_Available then
            declare
               CPU_Text : constant String :=
                 Ada.Strings.Fixed.Trim
                   (Image (CPU_Percent, 0), Ada.Strings.Both);
               Core_Text : constant String :=
                 Ada.Strings.Fixed.Trim
                   (Image (CPU_Percent / 100.0, 1), Ada.Strings.Both);
               RSS_Text : constant String := Memory_Image (Long_Float (RSS));
               Delta_Text : constant String :=
                 (if RSS >= Progress_Start_RSS then "+" else "")
                 & Memory_Image
                     (Long_Float (RSS) - Long_Float (Progress_Start_RSS));
            begin
            Ada.Text_IO.Put
              (Dim & "  cpu " & Left_Pad (CPU_Text, 5) & "% / "
               & Left_Pad (Core_Text, 5) & " cores"
               & "  rss " & Left_Pad (RSS_Text, 10)
               & " (" & Left_Pad (Delta_Text, 11) & ")"
               & "  elapsed " & Elapsed_Image (Total_Wall_Elapsed)
               & " (hh:mm:ss)" & Reset);
            end;
         end if;
         if Phase = Finished then
            Ada.Text_IO.Put_Line ("  " & Green & "done" & Reset);
         end if;
         Ada.Text_IO.Flush;
      elsif Phase /= Last_Progress_Phase then
         Ada.Text_IO.Put_Line
           ("flyology_bench: "
            & (if Name'Length = 0 then "" else Name & ": ")
            & Phase_Name (Phase));
      end if;
      Last_Progress_Phase := Phase;
      Last_Progress_Percent := (if Total > 0 then Percent else 101);
      Last_Progress_Name := Ada.Strings.Unbounded.To_Unbounded_String (Name);
   end Terminal_Progress;

   function Terminal_Mode
     (Base : Configuration := Default_Configuration;
      Name : String := "benchmark") return Configuration
   is
      Result : Configuration := Base;
   begin
      Result.Progress := Terminal_Progress'Access;
      Result.Collect_Process_Telemetry := True;
      Result.Progress_Name := Ada.Strings.Unbounded.To_Unbounded_String (Name);
      return Result;
   end Terminal_Mode;

   function Verdict_Name (Value : Comparison_Verdict) return String is
   begin
      case Value is
         when Inconclusive          => return "inconclusive";
         when Practically_Equivalent => return "practically equivalent";
         when Contender_Faster      => return "contender faster";
         when Reference_Faster      => return "reference faster";
      end case;
   end Verdict_Name;

   function Schedule_Name (Value : Shootout_Schedule_Policy) return String is
     (if Value = Balanced_Rounds then "balanced rounds" else "sequential cases");

   function Batching_Name (Value : Comparison_Batch_Policy) return String is
     (if Value = Equal_Time then "equal time" else "shared iterations");

   function Image
     (Value : Long_Float;
      Aft   : Natural := 3) return String
   is
      Buffer : String (1 .. 64);
   begin
      Float_IO.Put (Buffer, Value, Aft => Aft, Exp => 0);
      return Ada.Strings.Fixed.Trim (Buffer, Ada.Strings.Both);
   end Image;

   function Time_Change_Image (Value : Long_Float) return String is
   begin
      if Value < 0.0 then
         return Image (abs Value, 2) & "% less";
      elsif Value > 0.0 then
         return Image (Value, 2) & "% more";
      else
         return "same";
      end if;
   end Time_Change_Image;

   function JSON_Number (Value : Long_Float) return String is
      Buffer : String (1 .. 64);
   begin
      Float_IO.Put (Buffer, Value, Aft => 9, Exp => 0);
      return Ada.Strings.Fixed.Trim (Buffer, Ada.Strings.Both);
   end JSON_Number;

   function Duration_Image (Nanoseconds : Long_Float) return String is
   begin
      if abs Nanoseconds >= 1_000_000.0 then
         return Image (Nanoseconds / 1_000_000.0, 2) & " ms";
      elsif abs Nanoseconds >= 1_000.0 then
         return Image (Nanoseconds / 1_000.0, 2) & " us";
      elsif abs Nanoseconds >= 0.01 then
         return Image (Nanoseconds, 3) & " ns";
      else
         return Image (Nanoseconds * 1_000.0, 3) & " ps";
      end if;
   end Duration_Image;

   function Pretty_Name (Value : String) return String is
      Result : String := Ada.Characters.Handling.To_Lower (Value);
   begin
      for Character of Result loop
         if Character = '_' then
            Character := ' ';
         end if;
      end loop;
      return Result;
   end Pretty_Name;

   function Pad (Value : String; Width : Positive) return String is
   begin
      if Value'Length >= Width then
         return Value (Value'First .. Value'First + Width - 1);
      end if;
      return Value & (1 .. Width - Value'Length => ' ');
   end Pad;

   function Left_Pad (Value : String; Width : Positive) return String is
   begin
      if Value'Length >= Width then
         return Value (Value'Last - Width + 1 .. Value'Last);
      end if;
      return (1 .. Width - Value'Length => ' ') & Value;
   end Left_Pad;

   function Memory_Image (Bytes : Long_Float) return String is
   begin
      if abs Bytes >= 1_073_741_824.0 then
         return Image (Bytes / 1_073_741_824.0, 1) & " GiB";
      elsif abs Bytes >= 1_048_576.0 then
         return Image (Bytes / 1_048_576.0, 1) & " MiB";
      else
         return Image (Bytes / 1_024.0, 1) & " KiB";
      end if;
   end Memory_Image;

   function Sparkline
     (Values : Telemetry_Array;
      Count  : Positive) return String
   is
      Columns : constant Positive := Positive'Min (48, Count);
      Buffer  : String (1 .. Columns * 3);
      Minimum : Long_Float := Values (1);
      Maximum : Long_Float := Values (1);
   begin
      for Index in 2 .. Count loop
         Minimum := Long_Float'Min (Minimum, Values (Index));
         Maximum := Long_Float'Max (Maximum, Values (Index));
      end loop;
      for Column in 1 .. Columns loop
         declare
            Index : constant Positive :=
              (if Columns = 1 then 1
               else 1 + (Column - 1) * (Count - 1) / (Columns - 1));
            Level : Natural := 0;
            Start : constant Positive := (Column - 1) * 3 + 1;
         begin
            if Maximum > Minimum then
               Level := Natural'Min
                 (7, Natural
                    (Long_Float'Floor
                       (7.0 * (Values (Index) - Minimum)
                        / (Maximum - Minimum))));
            end if;
            Buffer (Start) := Character'Val (16#E2#);
            Buffer (Start + 1) := Character'Val (16#96#);
            Buffer (Start + 2) := Character'Val (16#81# + Level);
         end;
      end loop;
      return Buffer;
   end Sparkline;

   function Sample_Sparkline
     (Values : Sample_Array;
      Count  : Positive) return String
   is
      Columns : constant Positive := Positive'Min (48, Count);
      Buffer  : String (1 .. Columns * 3);
      Minimum : Long_Float := Values (1);
      Maximum : Long_Float := Values (1);
   begin
      for Index in 2 .. Count loop
         Minimum := Long_Float'Min (Minimum, Values (Sample_Index (Index)));
         Maximum := Long_Float'Max (Maximum, Values (Sample_Index (Index)));
      end loop;
      for Column in 1 .. Columns loop
         declare
            Index : constant Positive :=
              (if Columns = 1 then 1
               else 1 + (Column - 1) * (Count - 1) / (Columns - 1));
            Level : Natural := 0;
            Start : constant Positive := (Column - 1) * 3 + 1;
         begin
            if Maximum > Minimum then
               Level := Natural'Min
                 (7, Natural
                    (Long_Float'Floor
                       (7.0 * (Values (Sample_Index (Index)) - Minimum)
                        / (Maximum - Minimum))));
            end if;
            Buffer (Start) := Character'Val (16#E2#);
            Buffer (Start + 1) := Character'Val (16#96#);
            Buffer (Start + 2) := Character'Val (16#81# + Level);
         end;
      end loop;
      return Buffer;
   end Sample_Sparkline;

   procedure Put_Result_Telemetry
     (File   : Ada.Text_IO.File_Type;
      Result : Measurement;
      Style  : Console_Style)
   is
      Color : constant Boolean := Styled (Style);
      Count : constant Positive := Positive (Result.Sample_Total);
      CPU_Peak : Long_Float := 0.0;
      CPU_Average : Long_Float := 0.0;
   begin
      for Index in 1 .. Count loop
         CPU_Peak := Long_Float'Max
           (CPU_Peak, Result.Telemetry_CPU (Sample_Index (Index)));
      end loop;
      if Result.Telemetry_Wall_Total > 0.0 then
         CPU_Average := 100.0 * Result.Telemetry_CPU_Total
           / Result.Telemetry_Wall_Total;
      end if;
      Ada.Text_IO.Put_Line
        (File,
         "   " & (if Color then Magenta else "") & Pad ("cpu", 10)
         & (if Color then Reset else "") & " | "
         & (if Color then Magenta else "")
         & Sample_Sparkline (Result.Telemetry_CPU, Count)
         & (if Color then Reset else ""));
      Ada.Text_IO.Put_Line
        (File,
         "   " & Pad ("", 10) & " | average " & Image (CPU_Average, 0)
         & "%  (" & Image (CPU_Average / 100.0, 1)
         & " cores)    peak " & Image (CPU_Peak, 0) & "%  ("
         & Image (CPU_Peak / 100.0, 1) & " cores)");
      Ada.Text_IO.Put_Line
        (File,
         "   " & (if Color then Cyan else "") & Pad ("memory", 10)
         & (if Color then Reset else "") & " | "
         & (if Color then Cyan else "")
         & Sample_Sparkline (Result.Telemetry_RSS_Delta, Count)
         & (if Color then Reset else ""));
      Ada.Text_IO.Put_Line
        (File,
         "   " & Pad ("", 10) & " | RSS change across own batches "
         & (if Result.Telemetry_RSS_Change_Total >= 0.0
            then "+" else "")
         & Memory_Image (Result.Telemetry_RSS_Change_Total)
         & "    largest batch +"
         & Memory_Image (Result.Telemetry_RSS_Change_Peak));
      Ada.Text_IO.Put_Line
        (File,
         "   " & (if Color then Yellow else "") & Pad ("elapsed", 10)
         & (if Color then Reset else "") & " | "
         & Elapsed_Image
             (Interfaces.Unsigned_64
                (Long_Float'Max (0.0, Result.Telemetry_Wall_Total)))
         & " timed samples (hh:mm:ss)");
   end Put_Result_Telemetry;

   procedure Put_Telemetry_Summary
     (File  : Ada.Text_IO.File_Type;
      Style : Console_Style;
      Heading : String := "")
   is
      Color : constant Boolean := Styled (Style);
      CPU_Sum : Long_Float := 0.0;
      CPU_Peak : Long_Float := 0.0;
      RSS_Peak : Long_Float := 0.0;
   begin
      if not Telemetry_Ready or else Telemetry_Count = 0 then
         return;
      end if;
      if Heading'Length > 0 then
         Ada.Text_IO.Put_Line
           (File,
            (if Color then Magenta & Bold else "")
            & "-- " & Heading & " " & (1 .. 28 => '-')
            & (if Color then Reset else ""));
      end if;
      for Index in 1 .. Telemetry_Count loop
         CPU_Sum := CPU_Sum + CPU_History (Index);
         CPU_Peak := Long_Float'Max (CPU_Peak, CPU_History (Index));
         RSS_Peak := Long_Float'Max (RSS_Peak, RSS_History (Index));
      end loop;
      Ada.Text_IO.Put_Line
        (File,
         "   " & (if Color then Magenta else "") & Pad ("cpu", 10)
         & (if Color then Reset else "") & " | "
         & (if Color then Magenta else "")
         & Sparkline (CPU_History, Positive (Telemetry_Count))
         & (if Color then Reset else ""));
      Ada.Text_IO.Put_Line
        (File,
         "   " & Pad ("", 10) & " | average "
         & Image (CPU_Sum / Long_Float (Telemetry_Count), 0)
         & "%  (" & Image
             (CPU_Sum / Long_Float (Telemetry_Count) / 100.0, 1)
         & " cores)    peak " & Image (CPU_Peak, 0) & "%  ("
         & Image (CPU_Peak / 100.0, 1) & " cores)");
      Ada.Text_IO.Put_Line
        (File,
         "   " & (if Color then Cyan else "") & Pad ("memory", 10)
         & (if Color then Reset else "") & " | "
         & (if Color then Cyan else "")
         & Sparkline (RSS_History, Positive (Telemetry_Count))
         & (if Color then Reset else ""));
      Ada.Text_IO.Put_Line
        (File,
         "   " & Pad ("", 10) & " | start "
         & Memory_Image (RSS_History (1)) & "    final "
         & Memory_Image (RSS_History (Telemetry_Count))
         & "    peak " & Memory_Image (RSS_Peak)
         & "    growth "
         & (if RSS_History (Telemetry_Count) >= RSS_History (1)
            then "+" else "")
         & Memory_Image
             (RSS_History (Telemetry_Count) - RSS_History (1)));
      Ada.Text_IO.Put_Line
        (File,
         "   " & (if Color then Yellow else "") & Pad ("elapsed", 10)
         & (if Color then Reset else "") & " | "
         & Elapsed_Image (Total_Wall_Elapsed)
         & " wall time (hh:mm:ss)");
   end Put_Telemetry_Summary;

   function JSON_String (Value : String) return String is
      Buffer : String (1 .. Value'Length * 2 + 2);
      Last   : Natural := 1;
   begin
      Buffer (1) := '"';
      for Character of Value loop
         if Character = '"' or else Character = '\' then
            Last := Last + 1;
            Buffer (Last) := '\';
         elsif Character < ' ' then
            raise Constraint_Error with
              "benchmark names must not contain control characters";
         end if;
         Last := Last + 1;
         Buffer (Last) := Character;
      end loop;
      Last := Last + 1;
      Buffer (Last) := '"';
      return Buffer (1 .. Last);
   end JSON_String;

   function CSV_String (Value : String) return String is
      Quote : Boolean := False;
      Count : Natural := 2;
   begin
      for Character of Value loop
         if Character = '"' then
            Count := Count + 2;
            Quote := True;
         else
            Count := Count + 1;
            Quote := Quote or else Character = ',' or else Character = ASCII.LF;
         end if;
      end loop;
      if not Quote then
         return Value;
      end if;
      declare
         Buffer : String (1 .. Count);
         Last   : Natural := 1;
      begin
         Buffer (1) := '"';
         for Character of Value loop
            Last := Last + 1;
            Buffer (Last) := Character;
            if Character = '"' then
               Last := Last + 1;
               Buffer (Last) := '"';
            end if;
         end loop;
         Last := Last + 1;
         Buffer (Last) := '"';
         return Buffer (1 .. Last);
      end;
   end CSV_String;

   procedure Put_Console
     (Name   : String;
      Result : Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Style  : Console_Style := Auto;
      Include_Telemetry : Boolean := True)
   is
      Counts : constant Outlier_Counts := Outliers (Result);
      Color  : constant Boolean := Styled (Style);
      Prefix : constant String := (if Color then Cyan & Bold else "");
      Accent : constant String := (if Color then Green & Bold else "");
      Muted  : constant String := (if Color then Dim else "");
      End_Style : constant String := (if Color then Reset else "");
      Quality_Color : constant String :=
        (if not Color then ""
         elsif Coefficient_Of_Variation_Percent (Result) > 10.0
           or else Counts.Low_Severe + Counts.Low_Mild
             + Counts.High_Mild + Counts.High_Severe > 0
         then Yellow
         else Green);
   begin
      Ada.Text_IO.Put_Line
        (File,
         Prefix & "-- " & Name & " "
         & (1 .. (if Name'Length < 52 then 52 - Name'Length else 1) => '-')
         & End_Style);
      Ada.Text_IO.Put_Line
        (File,
         "   " & Accent & Pad ("latency", 10) & End_Style & " | "
         & Accent & "median " & Duration_Image (Median_Nanoseconds (Result))
         & "/op" & End_Style & "  mean "
         & Duration_Image (Mean_Nanoseconds (Result)));
      Ada.Text_IO.Put_Line
        (File,
         "   " & (if Color then Cyan else "") & Pad ("tails", 10)
         & End_Style & " | p95 "
         & Duration_Image (P95_Nanoseconds (Result))
         & "  p99 " & Duration_Image (P99_Nanoseconds (Result))
         & "  range " & Duration_Image (Minimum_Nanoseconds (Result))
         & " .. " & Duration_Image (Maximum_Nanoseconds (Result)));
      Ada.Text_IO.Put_Line
        (File,
         "   " & (if Color then Cyan else "") & Pad ("sampling", 10)
         & End_Style & " |"
         & Iterations_Per_Sample (Result)'Image & " iter/sample x"
         & Samples (Result)'Image & " samples"
         & "  median batch "
         & Duration_Image (Median_Batch_Nanoseconds (Result)));
      Ada.Text_IO.Put_Line
        (File,
         "   " & Quality_Color & Pad ("quality", 10) & End_Style & " | CV "
         & Image (Coefficient_Of_Variation_Percent (Result), 2)
         & "%  outliers"
         & Natural'Image
             (Counts.Low_Severe + Counts.Low_Mild
              + Counts.High_Mild + Counts.High_Severe)
         & "  lag-1 correlation "
         & Image (Sample_Lag_One_Correlation (Result), 2));
      Ada.Text_IO.Put_Line
        (File,
         "   " & Muted & Pad ("clock", 10) & End_Style & " | "
         & Clock_Backend (Result));
      Ada.Text_IO.Put_Line
        (File,
         "   " & Muted & Pad ("resolution", 10) & End_Style & " | nominal "
         & Duration_Image (Clock_Resolution_Nanoseconds (Result))
         & "  observed "
         & Duration_Image (Observed_Clock_Resolution_Nanoseconds (Result))
         & "  median read "
         & Duration_Image (Median_Timer_Cost_Nanoseconds (Result))
         & "  floor " & Duration_Image (Quantization_Floor_Nanoseconds (Result))
         & "/op"
         & End_Style);
      if Result.Telemetry_Available then
         Put_Result_Telemetry (File, Result, Style);
      elsif Include_Telemetry then
         Put_Telemetry_Summary (File, Style);
      end if;
   end Put_Console;

   procedure Put_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output) is
   begin
      Ada.Text_IO.Put_Line
        (File,
         "name,iterations,samples,timer_cost_ns,min_ns,median_ns,mean_ns,"
         & "mean_ci95_low_ns,mean_ci95_high_ns,p95_ns,p99_ns,max_ns,"
         & "stddev_ns,mad_ns,cv_percent,low_severe,low_mild,high_mild,"
         & "high_severe,clock_backend,clock_resolution_ns,"
         & "observed_clock_resolution_ns,median_timer_cost_ns,median_batch_ns,"
         & "quantization_floor_ns,lag_one_correlation");
   end Put_CSV_Header;

   procedure Put_CSV
     (Name   : String;
      Result : Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output)
   is
      Counts : constant Outlier_Counts := Outliers (Result);
   begin
      Ada.Text_IO.Put_Line
        (File,
         CSV_String (Name)
         & "," & Iterations_Per_Sample (Result)'Image
         & "," & Samples (Result)'Image
         & "," & JSON_Number (Timer_Cost_Nanoseconds (Result))
         & "," & JSON_Number (Minimum_Nanoseconds (Result))
         & "," & JSON_Number (Median_Nanoseconds (Result))
         & "," & JSON_Number (Mean_Nanoseconds (Result))
         & "," & JSON_Number (Mean_Confidence_Low_Nanoseconds (Result))
         & "," & JSON_Number (Mean_Confidence_High_Nanoseconds (Result))
         & "," & JSON_Number (P95_Nanoseconds (Result))
         & "," & JSON_Number (P99_Nanoseconds (Result))
         & "," & JSON_Number (Maximum_Nanoseconds (Result))
         & "," & JSON_Number (Standard_Deviation_Nanoseconds (Result))
         & "," & JSON_Number
             (Median_Absolute_Deviation_Nanoseconds (Result))
         & "," & JSON_Number (Coefficient_Of_Variation_Percent (Result))
         & "," & Counts.Low_Severe'Image
         & "," & Counts.Low_Mild'Image
         & "," & Counts.High_Mild'Image
         & "," & Counts.High_Severe'Image
         & "," & CSV_String (Clock_Backend (Result))
         & "," & JSON_Number (Clock_Resolution_Nanoseconds (Result))
         & "," & JSON_Number (Observed_Clock_Resolution_Nanoseconds (Result))
         & "," & JSON_Number (Median_Timer_Cost_Nanoseconds (Result))
         & "," & JSON_Number (Median_Batch_Nanoseconds (Result))
         & "," & JSON_Number (Quantization_Floor_Nanoseconds (Result))
         & "," & JSON_Number (Sample_Lag_One_Correlation (Result)));
   end Put_CSV;

   procedure Put_JSON
     (Name   : String;
      Result : Measurement;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output)
   is
      Counts : constant Outlier_Counts := Outliers (Result);
   begin
      Ada.Text_IO.Put_Line
        (File,
         "{""name"":" & JSON_String (Name)
         & ",""context"":{""os"":"
         & JSON_String (Flyology_Bench.Metadata.Operating_System)
         & ",""architecture"":"
         & JSON_String (Flyology_Bench.Metadata.Architecture)
         & ",""compiler"":"
         & JSON_String (Flyology_Bench.Metadata.Compiler) & "}"
         & ",""iterations"":" & Iterations_Per_Sample (Result)'Image
         & ",""samples"":" & Samples (Result)'Image
         & ",""timer_cost_ns"":" & JSON_Number (Timer_Cost_Nanoseconds (Result))
         & ",""min_ns"":" & JSON_Number (Minimum_Nanoseconds (Result))
         & ",""median_ns"":" & JSON_Number (Median_Nanoseconds (Result))
         & ",""mean_ns"":" & JSON_Number (Mean_Nanoseconds (Result))
         & ",""mean_ci95_low_ns"":"
         & JSON_Number (Mean_Confidence_Low_Nanoseconds (Result))
         & ",""mean_ci95_high_ns"":"
         & JSON_Number (Mean_Confidence_High_Nanoseconds (Result))
         & ",""p95_ns"":" & JSON_Number (P95_Nanoseconds (Result))
         & ",""p99_ns"":" & JSON_Number (P99_Nanoseconds (Result))
         & ",""max_ns"":" & JSON_Number (Maximum_Nanoseconds (Result))
         & ",""stddev_ns"":"
         & JSON_Number (Standard_Deviation_Nanoseconds (Result))
         & ",""mad_ns"":"
         & JSON_Number (Median_Absolute_Deviation_Nanoseconds (Result))
         & ",""cv_percent"":"
         & JSON_Number (Coefficient_Of_Variation_Percent (Result))
         & ",""sample_percentile_semantics"":""batch_mean"""
         & ",""clock"":{""backend"":" & JSON_String (Clock_Backend (Result))
         & ",""nominal_resolution_ns"":"
         & JSON_Number (Clock_Resolution_Nanoseconds (Result))
         & ",""observed_resolution_ns"":"
         & JSON_Number (Observed_Clock_Resolution_Nanoseconds (Result))
         & ",""minimum_read_interval_ns"":"
         & JSON_Number (Timer_Cost_Nanoseconds (Result))
         & ",""median_read_interval_ns"":"
         & JSON_Number (Median_Timer_Cost_Nanoseconds (Result)) & "}"
         & ",""median_batch_ns"":" & JSON_Number (Median_Batch_Nanoseconds (Result))
         & ",""quantization_floor_ns"":"
         & JSON_Number (Quantization_Floor_Nanoseconds (Result))
         & ",""lag_one_correlation"":"
         & JSON_Number (Sample_Lag_One_Correlation (Result))
         & ",""bootstrap"":""circular_block"""
         & ",""outliers"":{""low_severe"":" & Counts.Low_Severe'Image
         & ",""low_mild"":" & Counts.Low_Mild'Image
         & ",""high_mild"":" & Counts.High_Mild'Image
         & ",""high_severe"":" & Counts.High_Severe'Image & "}}");
   end Put_JSON;

   procedure Put_Comparison_Console
     (Reference_Name : String;
      Contender_Name : String;
      Result         : Comparison;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Style          : Console_Style := Auto)
   is
      Reference_Data : constant Measurement := Reference_Measurement (Result);
      Contender_Data : constant Measurement := Contender_Measurement (Result);
      Color : constant Boolean := Styled (Style);
      Verdict_Color : constant String :=
        (if not Color then ""
         elsif Verdict (Result) = Contender_Faster then Green & Bold
         elsif Verdict (Result) = Reference_Faster then Red & Bold
         elsif Verdict (Result) = Practically_Equivalent then Cyan & Bold
         else Yellow & Bold);
      Muted : constant String := (if Color then Dim else "");
      End_Style : constant String := (if Color then Reset else "");
   begin
      Ada.Text_IO.Put_Line
        (File,
         (if Color then Magenta & Bold else "")
         & "-- " & Contender_Name & " vs " & Reference_Name & " "
         & (1 ..
              (if Contender_Name'Length + Reference_Name'Length < 45
               then 45 - Contender_Name'Length - Reference_Name'Length
               else 1) => '-')
         & End_Style);
      Ada.Text_IO.Put_Line
        (File,
         Muted & "   " & Pad ("implementation", 22)
         & Pad ("median", 13) & Pad ("speedup", 11)
         & Pad ("elapsed time", 18) & Pad ("95% CI", 20)
         & "verdict" & End_Style);
      Ada.Text_IO.Put_Line
        (File,
         (if Color then Cyan else "") & "   " & Pad (Reference_Name, 22)
         & Pad (Duration_Image (Median_Nanoseconds (Reference_Data)), 13)
         & Pad ("1.000x", 11) & Pad ("--", 18) & Pad ("--", 20)
         & "reference" & End_Style);
      Ada.Text_IO.Put_Line
        (File,
         Verdict_Color & "   " & Pad (Contender_Name, 22)
         & Pad (Duration_Image (Median_Nanoseconds (Contender_Data)), 13)
         & Pad (Image (Geometric_Mean_Speedup (Result)) & "x", 11)
         & Pad (Time_Change_Image (Relative_Time_Change_Percent (Result)), 18)
         & Pad
             ("[" & Image (Speedup_Confidence_Low (Result)) & ", "
              & Image (Speedup_Confidence_High (Result)) & "]", 20)
         & Verdict_Name (Verdict (Result)) & End_Style);
      Ada.Text_IO.Put_Line
        (File,
         "   wins " & Natural'Image (Contender_Wins (Result))
         & "/" & Natural'Image (Samples (Reference_Data))
         & "  practical threshold +/-"
         & Image (Practical_Threshold_Percent (Result), 2) & "%"
         & "  order effect " & Image (Order_Effect_Percent (Result), 2) & "%"
         & "  lag1 " & Image (Lag_One_Correlation (Result), 2));
      if abs (Order_Effect_Percent (Result))
           > Practical_Threshold_Percent (Result)
        or else abs (Lag_One_Correlation (Result)) >= 0.30
      then
         Ada.Text_IO.Put_Line
           (File,
            "   " & (if Color then Yellow else "") & "! "
            & (if abs (Order_Effect_Percent (Result))
                    > Practical_Threshold_Percent (Result)
               then "execution-order effect detected"
               else "serial correlation detected")
            & Muted & "; repeat or inspect host stability" & End_Style);
      end if;
      Put_Telemetry_Summary (File, Style);
   end Put_Comparison_Console;

   procedure Put_Comparison_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output) is
   begin
      Ada.Text_IO.Put_Line
        (File,
         "reference,contender,reference_iterations,contender_iterations,"
         & "samples,reference_median_ns,"
         & "contender_median_ns,geometric_mean_speedup,median_speedup,"
         & "speedup_ci95_low,speedup_ci95_high,time_change_percent,"
         & "time_change_ci95_low,time_change_ci95_high,mean_difference_ns,"
         & "contender_wins,reference_wins,ties,reference_first,"
         & "contender_first,verdict,practical_threshold_percent,"
         & "order_effect_percent,lag_one_correlation");
   end Put_Comparison_CSV_Header;

   procedure Put_Comparison_CSV
     (Reference_Name : String;
      Contender_Name : String;
      Result         : Comparison;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output)
   is
      Reference_Data : constant Measurement := Reference_Measurement (Result);
      Contender_Data : constant Measurement := Contender_Measurement (Result);
   begin
      Ada.Text_IO.Put_Line
        (File,
         CSV_String (Reference_Name)
         & "," & CSV_String (Contender_Name)
         & "," & Iteration_Count'Image
             (Iterations_Per_Sample (Reference_Data))
         & "," & Iteration_Count'Image
             (Iterations_Per_Sample (Contender_Data))
         & "," & Sample_Count'Image (Samples (Reference_Data))
         & "," & JSON_Number (Median_Nanoseconds (Reference_Data))
         & "," & JSON_Number (Median_Nanoseconds (Contender_Data))
         & "," & JSON_Number (Geometric_Mean_Speedup (Result))
         & "," & JSON_Number (Median_Speedup (Result))
         & "," & JSON_Number (Speedup_Confidence_Low (Result))
         & "," & JSON_Number (Speedup_Confidence_High (Result))
         & "," & JSON_Number (Relative_Time_Change_Percent (Result))
         & "," & JSON_Number
             (Relative_Time_Change_Confidence_Low (Result))
         & "," & JSON_Number
             (Relative_Time_Change_Confidence_High (Result))
         & "," & JSON_Number (Mean_Time_Difference_Nanoseconds (Result))
         & "," & Natural'Image (Contender_Wins (Result))
         & "," & Natural'Image (Reference_Wins (Result))
         & "," & Natural'Image (Ties (Result))
         & "," & Natural'Image (Reference_First_Samples (Result))
         & "," & Natural'Image (Contender_First_Samples (Result))
         & "," & CSV_String (Verdict_Name (Verdict (Result)))
         & "," & JSON_Number (Practical_Threshold_Percent (Result))
         & "," & JSON_Number (Order_Effect_Percent (Result))
         & "," & JSON_Number (Lag_One_Correlation (Result)));
   end Put_Comparison_CSV;

   procedure Put_Comparison_JSON
     (Reference_Name : String;
      Contender_Name : String;
      Result         : Comparison;
      File           : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output)
   is
      Reference_Data : constant Measurement := Reference_Measurement (Result);
      Contender_Data : constant Measurement := Contender_Measurement (Result);
   begin
      Ada.Text_IO.Put_Line
        (File,
         "{""type"":""comparison"""
         & ",""context"":{""os"":"
         & JSON_String (Flyology_Bench.Metadata.Operating_System)
         & ",""architecture"":"
         & JSON_String (Flyology_Bench.Metadata.Architecture)
         & ",""compiler"":"
         & JSON_String (Flyology_Bench.Metadata.Compiler) & "}"
         & ",""reference"":" & JSON_String (Reference_Name)
         & ",""contender"":" & JSON_String (Contender_Name)
         & ",""reference_iterations"":" & Iteration_Count'Image
             (Iterations_Per_Sample (Reference_Data))
         & ",""contender_iterations"":" & Iteration_Count'Image
             (Iterations_Per_Sample (Contender_Data))
         & ",""samples"":" & Sample_Count'Image (Samples (Reference_Data))
         & ",""reference_median_ns"":"
         & JSON_Number (Median_Nanoseconds (Reference_Data))
         & ",""contender_median_ns"":"
         & JSON_Number (Median_Nanoseconds (Contender_Data))
         & ",""geometric_mean_speedup"":"
         & JSON_Number (Geometric_Mean_Speedup (Result))
         & ",""median_speedup"":" & JSON_Number (Median_Speedup (Result))
         & ",""speedup_ci95_low"":"
         & JSON_Number (Speedup_Confidence_Low (Result))
         & ",""speedup_ci95_high"":"
         & JSON_Number (Speedup_Confidence_High (Result))
         & ",""time_change_percent"":"
         & JSON_Number (Relative_Time_Change_Percent (Result))
         & ",""time_change_ci95_low"":"
         & JSON_Number (Relative_Time_Change_Confidence_Low (Result))
         & ",""time_change_ci95_high"":"
         & JSON_Number (Relative_Time_Change_Confidence_High (Result))
         & ",""mean_difference_ns"":"
         & JSON_Number (Mean_Time_Difference_Nanoseconds (Result))
         & ",""contender_wins"":" & Natural'Image (Contender_Wins (Result))
         & ",""reference_wins"":" & Natural'Image (Reference_Wins (Result))
         & ",""ties"":" & Natural'Image (Ties (Result))
         & ",""reference_first"":"
         & Natural'Image (Reference_First_Samples (Result))
         & ",""contender_first"":"
         & Natural'Image (Contender_First_Samples (Result))
         & ",""verdict"":" & JSON_String (Verdict_Name (Verdict (Result)))
         & ",""practical_threshold_percent"":"
         & JSON_Number (Practical_Threshold_Percent (Result))
         & ",""order_effect_percent"":"
         & JSON_Number (Order_Effect_Percent (Result))
         & ",""lag_one_correlation"":"
         & JSON_Number (Lag_One_Correlation (Result))
         & ",""bootstrap"":""circular_block""}");
   end Put_Comparison_JSON;

   procedure Put_Multi_Comparison_Console
     (Result : Multi_Comparison;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output;
      Style  : Console_Style := Auto;
      Show_Individual_Details : Boolean := False)
   is
      Count : constant Positive := Case_Id'Pos (Case_Id'Last) + 1;
      Color : constant Boolean := Styled (Style);
      End_Style : constant String := (if Color then Reset else "");
      Reference : constant Measurement := Case_Measurement (Result, 1);

      function Row_Color (Value : Comparison_Verdict) return String is
        (if not Color then ""
         elsif Value = Contender_Faster then Green & Bold
         elsif Value = Reference_Faster then Red & Bold
         elsif Value = Practically_Equivalent then Cyan
         else Yellow);
   begin
      if Count /= Positive (Cases (Result)) then
         raise Constraint_Error with
           "reporter case enumeration does not match comparison result";
      end if;
      Ada.Text_IO.Put_Line
        (File,
         (if Color then Magenta & Bold else "")
         & "-- implementations vs " & Pretty_Name (Case_Id'Image (Case_Id'First))
         & " " & (1 .. 28 => '-') & End_Style);
      Ada.Text_IO.Put_Line
        (File,
         (if Color then Dim else "")
         & "   " & Pad ("implementation", 22)
         & Pad ("median", 13)
         & Pad ("speedup", 11)
         & Pad ("elapsed time", 18)
         & Pad ("95% CI", 20)
         & "verdict" & End_Style);
      Ada.Text_IO.Put_Line
        (File,
         (if Color then Cyan else "")
         & "   " & Pad (Pretty_Name (Case_Id'Image (Case_Id'First)), 22)
         & Pad (Duration_Image (Median_Nanoseconds (Reference)), 13)
         & Pad ("1.000x", 11)
         & Pad ("--", 18)
         & Pad ("--", 20)
         & "reference" & End_Style);
      for Index in 2 .. Count loop
         declare
            Pair : constant Comparison :=
              Versus_Reference (Result, Comparison_Case_Index (Index));
            Data : constant Measurement :=
              Case_Measurement (Result, Comparison_Case_Index (Index));
            Color_Code : constant String := Row_Color (Verdict (Pair));
            Interval : constant String :=
              "[" & Image (Speedup_Confidence_Low (Pair))
              & ", " & Image (Speedup_Confidence_High (Pair)) & "]";
         begin
            Ada.Text_IO.Put_Line
              (File,
               Color_Code & "   "
               & Pad (Pretty_Name (Case_Id'Image (Case_Id'Val (Index - 1))), 22)
               & Pad (Duration_Image (Median_Nanoseconds (Data)), 13)
               & Pad (Image (Geometric_Mean_Speedup (Pair)) & "x", 11)
               & Pad
                   (Time_Change_Image (Relative_Time_Change_Percent (Pair)), 18)
               & Pad (Interval, 20)
               & Verdict_Name (Verdict (Pair)) & End_Style);
         end;
      end loop;
      Ada.Text_IO.Put_Line
        (File,
         (if Color then Dim else "")
         & (if Shootout_Schedule (Result) = Balanced_Rounds
            then "   paired circular-block confidence intervals"
            else "   sequential blocks; confidence pairs sample indices "
              & "across blocks")
         & End_Style);
      if Show_Individual_Details then
         Ada.Text_IO.New_Line (File);
         for Index in 1 .. Count loop
            Put_Console
              (Name => Pretty_Name (Case_Id'Image (Case_Id'Val (Index - 1))),
               Result => Case_Measurement
                 (Result, Comparison_Case_Index (Index)),
               File => File,
               Style => Style,
               Include_Telemetry => False);
         end loop;
      end if;
      Put_Telemetry_Summary
        (File, Style,
         "shootout total / " & Schedule_Name (Shootout_Schedule (Result)));
   end Put_Multi_Comparison_Console;

   procedure Put_Multi_Comparison_CSV_Header
     (File : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output) is
   begin
      Ada.Text_IO.Put_Line
        (File,
         "reference,contender,reference_iterations,contender_iterations,"
         & "samples,schedule,batching,reference_median_ns,"
         & "contender_median_ns,reference_mean_ns,contender_mean_ns,"
         & "geometric_mean_speedup,speedup_ci95_low,speedup_ci95_high,"
         & "time_change_percent,verdict,practical_threshold_percent,"
         & "order_effect_percent,lag_one_correlation,clock_backend,"
         & "clock_resolution_ns,quantization_floor_ns");
   end Put_Multi_Comparison_CSV_Header;

   procedure Put_Multi_Comparison_CSV
     (Result : Multi_Comparison;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output)
   is
      Count : constant Positive := Case_Id'Pos (Case_Id'Last) + 1;
      Reference : constant Measurement := Case_Measurement (Result, 1);
      Reference_Name : constant String :=
        Pretty_Name (Case_Id'Image (Case_Id'First));
   begin
      if Count /= Positive (Cases (Result)) then
         raise Constraint_Error with
           "reporter case enumeration does not match comparison result";
      end if;
      for Index in 2 .. Count loop
         declare
            Pair : constant Comparison :=
              Versus_Reference (Result, Comparison_Case_Index (Index));
            Data : constant Measurement :=
              Case_Measurement (Result, Comparison_Case_Index (Index));
         begin
            Ada.Text_IO.Put_Line
              (File,
               CSV_String (Reference_Name) & ","
               & CSV_String
                   (Pretty_Name (Case_Id'Image (Case_Id'Val (Index - 1))))
               & "," & Iterations_Per_Sample (Reference)'Image
               & "," & Iterations_Per_Sample (Data)'Image
               & "," & Samples (Data)'Image
               & "," & CSV_String (Schedule_Name (Shootout_Schedule (Result)))
               & "," & CSV_String (Batching_Name (Shootout_Batching (Result)))
               & "," & JSON_Number (Median_Nanoseconds (Reference))
               & "," & JSON_Number (Median_Nanoseconds (Data))
               & "," & JSON_Number (Mean_Nanoseconds (Reference))
               & "," & JSON_Number (Mean_Nanoseconds (Data))
               & "," & JSON_Number (Geometric_Mean_Speedup (Pair))
               & "," & JSON_Number (Speedup_Confidence_Low (Pair))
               & "," & JSON_Number (Speedup_Confidence_High (Pair))
               & "," & JSON_Number (Relative_Time_Change_Percent (Pair))
               & "," & CSV_String (Verdict_Name (Verdict (Pair)))
               & "," & JSON_Number (Practical_Threshold_Percent (Pair))
               & "," & JSON_Number (Order_Effect_Percent (Pair))
               & "," & JSON_Number (Lag_One_Correlation (Pair))
               & "," & CSV_String (Clock_Backend (Data))
               & "," & JSON_Number (Clock_Resolution_Nanoseconds (Data))
               & "," & JSON_Number (Quantization_Floor_Nanoseconds (Data)));
         end;
      end loop;
   end Put_Multi_Comparison_CSV;

   procedure Put_Multi_Comparison_JSON
     (Result : Multi_Comparison;
      File   : Ada.Text_IO.File_Type := Ada.Text_IO.Standard_Output)
   is
      Count : constant Positive := Case_Id'Pos (Case_Id'Last) + 1;
      Reference : constant Measurement := Case_Measurement (Result, 1);
   begin
      if Count /= Positive (Cases (Result)) then
         raise Constraint_Error with
           "reporter case enumeration does not match comparison result";
      end if;
      Ada.Text_IO.Put
        (File,
         "{""type"":""multi_comparison"",""context"":{""os"":"
         & JSON_String (Flyology_Bench.Metadata.Operating_System)
         & ",""architecture"":"
         & JSON_String (Flyology_Bench.Metadata.Architecture)
         & ",""compiler"":"
         & JSON_String (Flyology_Bench.Metadata.Compiler) & "},"
         & """schedule"":"
         & JSON_String (Schedule_Name (Shootout_Schedule (Result)))
         & ",""batching"":"
         & JSON_String (Batching_Name (Shootout_Batching (Result))) & ","
         & """reference"":{""name"":"
         & JSON_String (Pretty_Name (Case_Id'Image (Case_Id'First)))
         & ",""iterations"":" & Iterations_Per_Sample (Reference)'Image
         & ",""median_ns"":" & JSON_Number (Median_Nanoseconds (Reference))
         & ",""mean_ns"":" & JSON_Number (Mean_Nanoseconds (Reference))
         & "},""contenders"":[");
      for Index in 2 .. Count loop
         declare
            Pair : constant Comparison :=
              Versus_Reference (Result, Comparison_Case_Index (Index));
            Data : constant Measurement :=
              Case_Measurement (Result, Comparison_Case_Index (Index));
         begin
            if Index > 2 then
               Ada.Text_IO.Put (File, ",");
            end if;
            Ada.Text_IO.Put
              (File,
               "{""name"":"
               & JSON_String
                   (Pretty_Name (Case_Id'Image (Case_Id'Val (Index - 1))))
               & ",""iterations"":" & Iterations_Per_Sample (Data)'Image
               & ",""median_ns"":" & JSON_Number (Median_Nanoseconds (Data))
               & ",""mean_ns"":" & JSON_Number (Mean_Nanoseconds (Data))
               & ",""speedup"":" & JSON_Number (Geometric_Mean_Speedup (Pair))
               & ",""speedup_ci95_low"":"
               & JSON_Number (Speedup_Confidence_Low (Pair))
               & ",""speedup_ci95_high"":"
               & JSON_Number (Speedup_Confidence_High (Pair))
               & ",""time_change_percent"":"
               & JSON_Number (Relative_Time_Change_Percent (Pair))
               & ",""verdict"":" & JSON_String (Verdict_Name (Verdict (Pair)))
               & ",""order_effect_percent"":"
               & JSON_Number (Order_Effect_Percent (Pair))
               & ",""lag_one_correlation"":"
               & JSON_Number (Lag_One_Correlation (Pair)) & "}");
         end;
      end loop;
      Ada.Text_IO.Put_Line
        (File,
         "],""clock"":{""backend"":" & JSON_String (Clock_Backend (Reference))
         & ",""resolution_ns"":"
         & JSON_Number (Clock_Resolution_Nanoseconds (Reference))
         & "},""bootstrap"":""circular_block""}");
   end Put_Multi_Comparison_JSON;
end Flyology_Bench.Reporters;
