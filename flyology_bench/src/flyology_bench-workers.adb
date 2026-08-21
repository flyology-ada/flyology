--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Finalization;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Unchecked_Conversion;
with GNAT.OS_Lib;
with Interfaces.C.Strings;
with System;

package body Flyology_Bench.Workers is
   package C renames Interfaces.C;
   package CS renames Interfaces.C.Strings;
   package US renames Ada.Strings.Unbounded;

   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_32;
   use type Ada.Containers.Count_Type;
   use type Ada.Directories.File_Kind;
   use type C.int;
   use type C.long;
   use type CS.chars_ptr;

   Worker_Marker : constant String := "--flyology-bench-worker=1";
   Result_FD     : constant C.int := 3;
   Maximum_Protocol_Bytes : constant := 4 * 1_024 * 1_024;
   Maximum_Drain_Bytes_Per_Pass : constant := 64 * 1_024;
   Frame_Magic : constant String := "FLYBWRK1";
   Ready_Frame : constant Interfaces.Unsigned_32 := 1;
   Result_Frame : constant Interfaces.Unsigned_32 := 2;
   Completion_Marker : constant Interfaces.Unsigned_64 :=
     16#C0DE_F17E_BA5E_0001#;

   subtype Buffer is US.Unbounded_String;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   function Float_To_Bits is new Ada.Unchecked_Conversion
     (Long_Float, U64);
   function Bits_To_Float is new Ada.Unchecked_Conversion
     (U64, Long_Float);

   pragma Compile_Time_Error
     (Long_Float'Size /= 64,
      "fresh-process worker protocol requires 64-bit Long_Float");

   type Descriptor_Array is array (Natural range 0 .. 2) of aliased C.int
     with Convention => C;
   type Chars_Ptr_Array is array (Natural range <>) of aliased CS.chars_ptr
     with Convention => C;

   function C_Spawn
     (Pid                 : access C.int;
      Parent_Descriptors  : System.Address;
      Executable          : CS.chars_ptr;
      Arguments           : System.Address;
      Environment         : System.Address;
      Working_Directory   : CS.chars_ptr) return C.int;
   pragma Import (C, C_Spawn, "flyology_bench_worker_spawn");

   function C_Set_Nonblocking (Descriptor : C.int) return C.int;
   pragma Import
     (C, C_Set_Nonblocking, "flyology_bench_worker_set_nonblocking");

   function C_Observe_Exit (Pid : C.int) return C.int;
   pragma Import
     (C, C_Observe_Exit, "flyology_bench_worker_observe_exit");

   function C_Read
     (Descriptor : C.int;
      Data       : System.Address;
      Length     : C.size_t) return C.long;
   pragma Import (C, C_Read, "read");

   function C_Write
     (Descriptor : C.int;
      Data       : System.Address;
      Length     : C.size_t) return C.long;
   pragma Import (C, C_Write, "write");

   function C_Close (Descriptor : C.int) return C.int;
   pragma Import (C, C_Close, "close");

   function C_Kill (Pid, Signal : C.int) return C.int;
   pragma Import (C, C_Kill, "kill");

   function C_Waitpid
     (Pid : C.int; Status : access C.int; Options : C.int) return C.int;
   pragma Import (C, C_Waitpid, "waitpid");

   function C_Signal_Terminate return C.int;
   pragma Import
     (C, C_Signal_Terminate,
      "flyology_bench_worker_signal_terminate");
   function C_Signal_Kill return C.int;
   pragma Import
     (C, C_Signal_Kill, "flyology_bench_worker_signal_kill");
   function C_Errno_Interrupted return C.int;
   pragma Import
     (C, C_Errno_Interrupted,
      "flyology_bench_worker_errno_interrupted");
   function C_Errno_Would_Block return C.int;
   pragma Import
     (C, C_Errno_Would_Block,
      "flyology_bench_worker_errno_would_block");
   function C_Errno_No_Process return C.int;
   pragma Import
     (C, C_Errno_No_Process,
      "flyology_bench_worker_errno_no_process");
   function C_Errno_Permission return C.int;
   pragma Import
     (C, C_Errno_Permission,
      "flyology_bench_worker_errno_permission");
   function C_Status_Exited (Status : C.int) return C.int;
   pragma Import
     (C, C_Status_Exited, "flyology_bench_worker_status_exited");
   function C_Status_Exit_Code (Status : C.int) return C.int;
   pragma Import
     (C, C_Status_Exit_Code,
      "flyology_bench_worker_status_exit_code");
   function C_Status_Signaled (Status : C.int) return C.int;
   pragma Import
     (C, C_Status_Signaled, "flyology_bench_worker_status_signaled");
   function C_Status_Signal (Status : C.int) return C.int;
   pragma Import
     (C, C_Status_Signal, "flyology_bench_worker_status_signal");

   Interrupted_Error : constant C.int := C_Errno_Interrupted;
   Would_Block_Error : constant C.int := C_Errno_Would_Block;
   No_Process_Error  : constant C.int := C_Errno_No_Process;
   Permission_Error  : constant C.int := C_Errno_Permission;

   procedure Put_U8 (Target : in out Buffer; Value : Natural) is
   begin
      US.Append (Target, Character'Val (Value mod 256));
   end Put_U8;

   procedure Put_U32 (Target : in out Buffer; Value : U32) is
   begin
      for Shift in reverse 0 .. 3 loop
         Put_U8
           (Target,
            Natural
              (Interfaces.Shift_Right (Value, Shift * 8) and 16#FF#));
      end loop;
   end Put_U32;

   procedure Put_U64 (Target : in out Buffer; Value : U64) is
   begin
      for Shift in reverse 0 .. 7 loop
         Put_U8
           (Target,
            Natural
              (Interfaces.Shift_Right (Value, Shift * 8) and 16#FF#));
      end loop;
   end Put_U64;

   procedure Put_Natural (Target : in out Buffer; Value : Natural) is
   begin
      Put_U64 (Target, U64 (Value));
   end Put_Natural;

   procedure Put_Integer
     (Target : in out Buffer; Value : Long_Long_Integer) is
   begin
      if Value >= 0 then
         Put_U64 (Target, U64 (Value));
      else
         Put_U64 (Target, U64'Last - U64 (-(Value + 1)));
      end if;
   end Put_Integer;

   procedure Put_Boolean (Target : in out Buffer; Value : Boolean) is
   begin
      Put_U8 (Target, (if Value then 1 else 0));
   end Put_Boolean;

   function Valid_Number (Value : Long_Float) return Boolean is
     (Value = Value
      and then Value >= -Long_Float'Last
      and then Value <= Long_Float'Last);

   procedure Put_Float (Target : in out Buffer; Value : Long_Float) is
   begin
      if not Valid_Number (Value) then
         raise Protocol_Error with "worker result contains a non-finite number";
      end if;
      Put_U64 (Target, Float_To_Bits (Value));
   end Put_Float;

   procedure Put_String (Target : in out Buffer; Value : String) is
   begin
      if Value'Length > Maximum_Protocol_Bytes then
         raise Protocol_Error with "worker protocol string is oversized";
      end if;
      Put_U32 (Target, U32 (Value'Length));
      US.Append (Target, Value);
   end Put_String;

   function Get_U8 (Data : String; Cursor : aliased in out Natural) return Natural is
   begin
      if Cursor not in Data'Range then
         raise Protocol_Error with "truncated worker envelope";
      end if;
      declare
         Result : constant Natural := Character'Pos (Data (Cursor));
      begin
         Cursor := Cursor + 1;
         return Result;
      end;
   end Get_U8;

   function Get_U32 (Data : String; Cursor : aliased in out Natural) return U32 is
      Result : U32 := 0;
   begin
      for Index in 1 .. 4 loop
         Result := Interfaces.Shift_Left (Result, 8) or U32 (Get_U8 (Data, Cursor));
      end loop;
      return Result;
   end Get_U32;

   procedure Read_U64
     (Data : String; Cursor : aliased in out Natural; Result : out U64) is
   begin
      Result := 0;
      for Index in 1 .. 8 loop
         Result := Interfaces.Shift_Left (Result, 8) or U64 (Get_U8 (Data, Cursor));
      end loop;
   end Read_U64;

   function Get_U64 (Data : String; Cursor : aliased in out Natural) return U64 is
      Result : U64 := 0;
   begin
      for Index in 1 .. 8 loop
         Result := Interfaces.Shift_Left (Result, 8)
           or U64 (Get_U8 (Data, Cursor));
      end loop;
      return Result;
   end Get_U64;

   function Get_Natural (Data : String; Cursor : aliased in out Natural) return Natural is
      Value : constant U64 := Get_U64 (Data, Cursor);
   begin
      if Value > U64 (Natural'Last) then
         raise Protocol_Error with "worker natural value is out of range";
      end if;
      return Natural (Value);
   end Get_Natural;

   function To_Integer (Value : U64) return Long_Long_Integer is
   begin
      if Value <= U64 (Long_Long_Integer'Last) then
         return Long_Long_Integer (Value);
      end if;
      return -Long_Long_Integer (U64'Last - Value) - 1;
   end To_Integer;

   function Get_Boolean
     (Data : String; Cursor : aliased in out Natural) return Boolean
   is
      Value : constant Natural := Get_U8 (Data, Cursor);
   begin
      if Value > 1 then
         raise Protocol_Error with
           "invalid worker boolean at byte"
           & Natural'Image (Cursor - 1) & ", value" & Natural'Image (Value);
      end if;
      return Value = 1;
   end Get_Boolean;

   function Get_Float
     (Data : String; Cursor : aliased in out Natural) return Long_Float
   is
      Result : constant Long_Float := Bits_To_Float (Get_U64 (Data, Cursor));
   begin
      if not Valid_Number (Result) then
         raise Protocol_Error with "invalid worker numeric value";
      end if;
      return Result;
   end Get_Float;

   function Get_String
     (Data : String; Cursor : aliased in out Natural; Maximum : Natural)
      return String
   is
      Length : constant Natural := Natural (Get_U32 (Data, Cursor));
   begin
      if Length > Maximum
        or else Cursor > Data'Last + 1
        or else Length > Data'Last - Cursor + 1
      then
         raise Protocol_Error with "invalid worker string length";
      end if;
      declare
         Result : constant String :=
           (if Length = 0 then "" else Data (Cursor .. Cursor + Length - 1));
      begin
         Cursor := Cursor + Length;
         return Result;
      end;
   end Get_String;

   function Contains_NUL (Value : String) return Boolean is
   begin
      for Element of Value loop
         if Element = Character'Val (0) then
            return True;
         end if;
      end loop;
      return False;
   end Contains_NUL;

   function Valid_Environment_Name (Name : String) return Boolean is
   begin
      if Name'Length = 0
        or else Name'Length > Maximum_Environment_Name_Length
        or else Contains_NUL (Name)
      then
         return False;
      end if;
      for Element of Name loop
         if Element = '=' then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Environment_Name;

   function Create_Environment
     (Mode     : Environment_Mode := Strict_Mode;
      Locale   : Locale_Policy := Clear_Locale;
      Timezone : Timezone_Policy := Clear_Timezone) return Environment is
     ((Selected_Mode     => Mode,
       Selected_Locale   => Locale,
       Selected_Timezone => Timezone,
       others            => <>));

   procedure Add
     (Item : in out Environment;
      Name : String;
      Value : String) is
   begin
      if not Valid_Environment_Name (Name)
        or else Value'Length > Maximum_Environment_Value_Length
        or else Contains_NUL (Value)
      then
         raise Configuration_Error with "invalid worker environment addition";
      end if;
      for Existing of Item.Additions loop
         if US.To_String (Existing.Name) = Name then
            raise Configuration_Error with
              "duplicate worker environment addition: " & Name;
         end if;
      end loop;
      for Existing of Item.Removals loop
         if Existing = Name then
            raise Configuration_Error with
              "worker environment name is both added and removed: " & Name;
         end if;
      end loop;
      if Natural (Item.Additions.Length) >= Maximum_Environment_Entries then
         raise Configuration_Error with "too many worker environment additions";
      end if;
      Item.Additions.Append
        (Environment_Entry'
           (Name  => US.To_Unbounded_String (Name),
            Value => US.To_Unbounded_String (Value)));
   end Add;

   procedure Remove (Item : in out Environment; Name : String) is
   begin
      if not Valid_Environment_Name (Name) then
         raise Configuration_Error with "invalid worker environment removal";
      end if;
      for Existing of Item.Removals loop
         if Existing = Name then
            raise Configuration_Error with
              "duplicate worker environment removal: " & Name;
         end if;
      end loop;
      for Existing of Item.Additions loop
         if US.To_String (Existing.Name) = Name then
            raise Configuration_Error with
              "worker environment name is both added and removed: " & Name;
         end if;
      end loop;
      if Natural (Item.Removals.Length) >= Maximum_Environment_Entries then
         raise Configuration_Error with "too many worker environment removals";
      end if;
      Item.Removals.Append (Name);
   end Remove;

   function Mode (Item : Environment) return Environment_Mode is
     (Item.Selected_Mode);
   function Locale (Item : Environment) return Locale_Policy is
     (Item.Selected_Locale);
   function Timezone (Item : Environment) return Timezone_Policy is
     (Item.Selected_Timezone);

   function Hash (Value : String) return U64 is
      Result : U64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for Element of Value loop
         Result := (Result xor U64 (Character'Pos (Element)))
           * 16#0000_0100_0000_01B3#;
      end loop;
      return Result;
   end Hash;

   function Hex (Value : U64) return String is
      Hex_Chars : constant String := "0123456789abcdef";
      Result : String (1 .. 16);
      Work   : U64 := Value;
   begin
      for Index in reverse Result'Range loop
         Result (Index) := Hex_Chars (Natural (Work and 16#F#) + 1);
         Work := Interfaces.Shift_Right (Work, 4);
      end loop;
      return Result;
   end Hex;

   function Hex_Encode (Value : String) return String is
      Hex_Chars : constant String := "0123456789abcdef";
      Result : String (1 .. Value'Length * 2);
      Cursor : Natural := 1;
      Byte   : Natural;
   begin
      for Element of Value loop
         Byte := Character'Pos (Element);
         Result (Cursor) := Hex_Chars (Byte / 16 + 1);
         Result (Cursor + 1) := Hex_Chars (Byte mod 16 + 1);
         Cursor := Cursor + 2;
      end loop;
      return Result;
   end Hex_Encode;

   function Hex_Value (Element : Character) return Natural is
   begin
      case Element is
         when '0' .. '9' => return Character'Pos (Element) - Character'Pos ('0');
         when 'a' .. 'f' => return Character'Pos (Element) - Character'Pos ('a') + 10;
         when others => raise Protocol_Error with "invalid worker hexadecimal value";
      end case;
   end Hex_Value;

   function Hex_Decode (Value : String; Maximum : Natural) return String is
   begin
      if Value'Length mod 2 /= 0 or else Value'Length / 2 > Maximum then
         raise Protocol_Error with "invalid worker hexadecimal length";
      end if;
      declare
         Result : String (1 .. Value'Length / 2);
         Source : Natural := Value'First;
      begin
         for Index in Result'Range loop
            Result (Index) := Character'Val
              (Hex_Value (Value (Source)) * 16 + Hex_Value (Value (Source + 1)));
            Source := Source + 2;
         end loop;
         return Result;
      end;
   end Hex_Decode;

   function Parse_Hex_U64 (Value : String) return U64 is
      Result : U64 := 0;
   begin
      if Value'Length /= 16 then
         raise Protocol_Error with "invalid worker hash length";
      end if;
      for Element of Value loop
         Result := Interfaces.Shift_Left (Result, 4) or U64 (Hex_Value (Element));
      end loop;
      return Result;
   end Parse_Hex_U64;

   function Derive_Seed
     (Parent_Seed : Long_Long_Integer;
      Repetition : Positive) return Long_Long_Integer
   is
      Parent_Bits : constant U64 :=
        (if Parent_Seed >= 0 then U64 (Parent_Seed)
         else U64'Last - U64 (-(Parent_Seed + 1)));
      Value : U64 := Parent_Bits
        xor (U64 (Repetition) * 16#9E37_79B9_7F4A_7C15#);
   begin
      Value := (Value xor Interfaces.Shift_Right (Value, 30))
        * 16#BF58_476D_1CE4_E5B9#;
      Value := (Value xor Interfaces.Shift_Right (Value, 27))
        * 16#94D0_49BB_1331_11EB#;
      Value := Value xor Interfaces.Shift_Right (Value, 31);
      return Long_Long_Integer
        ((Value mod U64 (Long_Long_Integer'Last - 1)) + 1);
   end Derive_Seed;

   function Encode_Configuration (Config : Configuration) return String is
      Data : Buffer;
   begin
      Put_Float (Data, Long_Float (Config.Warmup_Time));
      Put_Float (Data, Long_Float (Config.Measurement_Time));
      Put_Float (Data, Long_Float (Config.Maximum_Sampling_Time));
      Put_Natural (Data, Config.Samples);
      Put_Float (Data, Long_Float (Config.Minimum_Sample_Time));
      Put_U64 (Data, U64 (Config.Maximum_Iterations));
      Put_Natural
        (Data, Comparison_Batch_Policy'Pos (Config.Comparison_Batching));
      Put_Natural
        (Data, Shootout_Schedule_Policy'Pos (Config.Shootout_Scheduling));
      Put_Boolean (Data, Config.Subtract_Timer_Cost);
      Put_Float (Data, Config.Practical_Threshold_Percent);
      Put_Integer (Data, Config.Random_Seed);
      for Axis in Metric_Axis loop
         Put_Boolean (Data, Config.Metrics (Axis));
      end loop;

      Put_Boolean (Data, Config.CPU_Quiescence.Enabled);
      if Config.CPU_Quiescence.Enabled then
         Put_Float
           (Data, Config.CPU_Quiescence.Maximum_Average_CPU_Percent);
         Put_Float
           (Data, Config.CPU_Quiescence.Maximum_Core_CPU_Percent);
         Put_Float
           (Data, Long_Float (Config.CPU_Quiescence.Stable_Time));
         Put_Float
           (Data, Long_Float (Config.CPU_Quiescence.Poll_Interval));
         Put_Float
           (Data, Long_Float (Config.CPU_Quiescence.Timeout));
      end if;

      Put_Boolean (Data, Config.Interference.Enabled);
      Put_Natural
        (Data, Interference_Response'Pos (Config.Interference.Response));
      if Config.Interference.Enabled then
         Put_Float
           (Data, Config.Interference.Maximum_Foreign_CPU_Percent);
         Put_Float (Data, Long_Float (Config.Interference.Window));
         Put_Natural (Data, Config.Interference.Maximum_Retakes);
         if Config.Interference.Response = Pause then
            Put_Float
              (Data, Long_Float (Config.Interference.Settle_Time));
            Put_Float
              (Data, Long_Float (Config.Interference.Maximum_Pause_Time));
            Put_Float
              (Data, Long_Float (Config.Interference.Rewarm_Time));
         end if;
      end if;

      Put_Boolean (Data, Config.Placement.Enabled);
      if Config.Placement.Enabled then
         Put_Natural (Data, Config.Placement.CPU);
         Put_Boolean (Data, Config.Placement.Include_Siblings);
         Put_Boolean (Data, Config.Placement.Require_Strict);
      end if;

      Put_Boolean (Data, Config.Host_Lock.Enabled);
      if Config.Host_Lock.Enabled then
         Put_String (Data, US.To_String (Config.Host_Lock.Path));
         Put_Float (Data, Long_Float (Config.Host_Lock.Timeout));
         Put_Float (Data, Long_Float (Config.Host_Lock.Poll_Interval));
         Put_Boolean (Data, Config.Host_Lock.Require_Machine_Scope);
      end if;
      Put_Boolean (Data, Config.Collect_Process_Telemetry);
      Put_String (Data, US.To_String (Config.Progress_Name));
      return US.To_String (Data);
   end Encode_Configuration;

   function Decode_Configuration
     (Data     : String;
      Template : Configuration) return Configuration
   is
      Cursor : aliased Natural := Data'First;
      Result : Configuration := Default_Configuration;
      Quiescence_Enabled : Boolean;
      Interference_Enabled : Boolean;
      Interference_Mode : Interference_Response;
      Placement_Enabled : Boolean;
      Lock_Enabled : Boolean;
   begin
      Result.Warmup_Time := Nonnegative_Duration (Get_Float (Data, Cursor));
      Result.Measurement_Time := Positive_Duration (Get_Float (Data, Cursor));
      Result.Maximum_Sampling_Time :=
        Nonnegative_Duration (Get_Float (Data, Cursor));
      Result.Samples := Sample_Count (Get_Natural (Data, Cursor));
      Result.Minimum_Sample_Time :=
        Positive_Duration (Get_Float (Data, Cursor));
      Result.Maximum_Iterations :=
        Positive_Iteration_Count (Get_U64 (Data, Cursor));
      Result.Comparison_Batching := Comparison_Batch_Policy'Val
        (Get_Natural (Data, Cursor));
      Result.Shootout_Scheduling := Shootout_Schedule_Policy'Val
        (Get_Natural (Data, Cursor));
      Result.Subtract_Timer_Cost := Get_Boolean (Data, Cursor);
      Result.Practical_Threshold_Percent :=
        Threshold_Percentage (Get_Float (Data, Cursor));
      declare
         Seed_Bits : U64;
      begin
         Read_U64 (Data, Cursor, Seed_Bits);
         Result.Random_Seed := To_Integer (Seed_Bits);
      end;
      for Axis in Metric_Axis loop
         Result.Metrics (Axis) := Get_Boolean (Data, Cursor);
      end loop;

      Quiescence_Enabled := Get_Boolean (Data, Cursor);
      if Quiescence_Enabled then
         declare
            Average : constant Percentage := Percentage (Get_Float (Data, Cursor));
            Core : constant Percentage := Percentage (Get_Float (Data, Cursor));
            Stable : constant Positive_Duration := Positive_Duration (Get_Float (Data, Cursor));
            Poll : constant Positive_Duration := Positive_Duration (Get_Float (Data, Cursor));
            Timeout : constant Positive_Duration := Positive_Duration (Get_Float (Data, Cursor));
         begin
            Result.CPU_Quiescence :=
              (Enabled                     => True,
               Maximum_Average_CPU_Percent => Average,
               Maximum_Core_CPU_Percent    => Core,
               Stable_Time                 => Stable,
               Poll_Interval               => Poll,
               Timeout                     => Timeout);
         end;
      else
         Result.CPU_Quiescence := (Enabled => False);
      end if;

      Interference_Enabled := Get_Boolean (Data, Cursor);
      Interference_Mode := Interference_Response'Val
        (Get_Natural (Data, Cursor));
      if not Interference_Enabled then
         Result.Interference :=
           (Enabled => False, Response => Interference_Mode);
      elsif Interference_Mode = Pause then
         declare
            Maximum : constant Percentage := Percentage (Get_Float (Data, Cursor));
            Window : constant Positive_Duration := Positive_Duration (Get_Float (Data, Cursor));
            Retakes : constant Natural := Get_Natural (Data, Cursor);
            Settle : constant Positive_Duration := Positive_Duration (Get_Float (Data, Cursor));
            Pause_Maximum : constant Positive_Duration := Positive_Duration (Get_Float (Data, Cursor));
            Rewarm : constant Nonnegative_Duration := Nonnegative_Duration (Get_Float (Data, Cursor));
         begin
            Result.Interference :=
              (Enabled                     => True,
               Response                    => Pause,
               Maximum_Foreign_CPU_Percent => Maximum,
               Window                      => Window,
               Maximum_Retakes             => Retakes,
               Settle_Time                 => Settle,
               Maximum_Pause_Time          => Pause_Maximum,
               Rewarm_Time                 => Rewarm);
         end;
      else
         declare
            Maximum : constant Percentage := Percentage (Get_Float (Data, Cursor));
            Window : constant Positive_Duration := Positive_Duration (Get_Float (Data, Cursor));
            Retakes : constant Natural := Get_Natural (Data, Cursor);
         begin
            case Interference_Mode is
               when Observe =>
                  Result.Interference :=
                    (Enabled => True, Response => Observe,
                     Maximum_Foreign_CPU_Percent => Maximum,
                     Window => Window, Maximum_Retakes => Retakes);
               when Retake =>
                  Result.Interference :=
                    (Enabled => True, Response => Retake,
                     Maximum_Foreign_CPU_Percent => Maximum,
                     Window => Window, Maximum_Retakes => Retakes);
               when Pause =>
                  raise Program_Error;
            end case;
         end;
      end if;

      Placement_Enabled := Get_Boolean (Data, Cursor);
      if Placement_Enabled then
         declare
            CPU : constant Natural := Get_Natural (Data, Cursor);
            Siblings : constant Boolean := Get_Boolean (Data, Cursor);
            Strict : constant Boolean := Get_Boolean (Data, Cursor);
         begin
            Result.Placement :=
              (Enabled => True, CPU => CPU, Include_Siblings => Siblings,
               Require_Strict => Strict);
         end;
      else
         Result.Placement := (Enabled => False);
      end if;

      Lock_Enabled := Get_Boolean (Data, Cursor);
      if Lock_Enabled then
         declare
            Path : constant US.Unbounded_String := US.To_Unbounded_String
              (Get_String (Data, Cursor, Maximum_Host_Lock_Path_Length));
            Timeout : constant Nonnegative_Duration :=
              Nonnegative_Duration (Get_Float (Data, Cursor));
            Poll : constant Positive_Duration :=
              Positive_Duration (Get_Float (Data, Cursor));
            Required : constant Boolean := Get_Boolean (Data, Cursor);
         begin
            Result.Host_Lock :=
              (Enabled => True, Path => Path, Timeout => Timeout,
               Poll_Interval => Poll, Require_Machine_Scope => Required);
         end;
      else
         Result.Host_Lock := (Enabled => False);
      end if;
      Result.Collect_Process_Telemetry := Get_Boolean (Data, Cursor);
      Result.Progress_Name := US.To_Unbounded_String
        (Get_String (Data, Cursor, Maximum_Progress_Name_Length));
      if Cursor /= Data'Last + 1 then
         raise Protocol_Error with "trailing worker configuration data";
      end if;

      --  Access values are meaningful only when constructed in this process.
      Result.Scheduler_Probe := Template.Scheduler_Probe;
      Result.Progress := Template.Progress;
      return Result;
   exception
      when Constraint_Error =>
         raise Protocol_Error with "worker configuration value is out of range";
   end Decode_Configuration;

   procedure Set_Entry
     (Entries : in out Environment_Vectors.Vector;
      Name    : String;
      Value   : String) is
   begin
      for Index in Entries.First_Index .. Entries.Last_Index loop
         if US.To_String (Entries (Index).Name) = Name then
            Entries.Replace_Element
              (Index,
               (Name  => US.To_Unbounded_String (Name),
                Value => US.To_Unbounded_String (Value)));
            return;
         end if;
      end loop;
      if Natural (Entries.Length) >= Maximum_Environment_Entries then
         raise Configuration_Error with "worker environment has too many entries";
      end if;
      Entries.Append
        (Environment_Entry'
           (Name  => US.To_Unbounded_String (Name),
            Value => US.To_Unbounded_String (Value)));
   end Set_Entry;

   procedure Delete_Entry
     (Entries : in out Environment_Vectors.Vector;
      Name    : String) is
   begin
      for Index in Entries.First_Index .. Entries.Last_Index loop
         if US.To_String (Entries (Index).Name) = Name then
            Entries.Delete (Index);
            return;
         end if;
      end loop;
   end Delete_Entry;

   procedure Sort_Entries (Entries : in out Environment_Vectors.Vector) is
   begin
      if Entries.Length < 2 then
         return;
      end if;
      for Left in Entries.First_Index .. Entries.Last_Index - 1 loop
         for Right in Left + 1 .. Entries.Last_Index loop
            if US.To_String (Entries (Right).Name)
              < US.To_String (Entries (Left).Name)
            then
               Entries.Swap (Left, Right);
            end if;
         end loop;
      end loop;
   end Sort_Entries;

   function Is_Strict_Base_Name
     (Name     : String;
      Item     : Environment) return Boolean is
   begin
      if Name = "PATH" or else Name = "TMPDIR"
        or else Name = "TMP" or else Name = "TEMP"
      then
         return True;
      elsif Item.Selected_Locale = Preserve_Locale
        and then (Name = "LANG"
                  or else (Name'Length > 3
                           and then Name (Name'First .. Name'First + 2) = "LC_"))
      then
         return True;
      else
         return Item.Selected_Timezone = Preserve_Timezone and then Name = "TZ";
      end if;
   end Is_Strict_Base_Name;

   function Effective_Environment
     (Item : Environment) return Environment_Vectors.Vector
   is
      Result : Environment_Vectors.Vector;

      procedure Consider (Name, Value : String) is
      begin
         if Item.Selected_Mode = Inherit_Mode
           or else Is_Strict_Base_Name (Name, Item)
         then
            if not Valid_Environment_Name (Name)
              or else Value'Length > Maximum_Environment_Value_Length
              or else Contains_NUL (Value)
            then
               raise Configuration_Error with
                 "inherited worker environment exceeds supported bounds";
            end if;
            Set_Entry (Result, Name, Value);
         end if;
      end Consider;
   begin
      Ada.Environment_Variables.Iterate (Consider'Access);
      for Variable of Item.Additions loop
         Set_Entry
           (Result, US.To_String (Variable.Name), US.To_String (Variable.Value));
      end loop;
      for Name of Item.Removals loop
         Delete_Entry (Result, Name);
      end loop;
      Sort_Entries (Result);
      declare
         Total : Natural := 1;
      begin
         for Variable of Result loop
            declare
               Size : constant Natural :=
                 US.Length (Variable.Name) + 1 + US.Length (Variable.Value) + 1;
            begin
               if Size > Maximum_Environment_Bytes - Total then
                  raise Configuration_Error with
                    "worker environment exceeds byte limit";
               end if;
               Total := Total + Size;
            end;
         end loop;
      end;
      return Result;
   end Effective_Environment;

   function Current_Environment return Environment_Vectors.Vector is
      Result : Environment_Vectors.Vector;
      procedure Include (Name, Value : String) is
      begin
         if not Valid_Environment_Name (Name)
           or else Value'Length > Maximum_Environment_Value_Length
           or else Contains_NUL (Value)
         then
            raise Protocol_Error with "worker inherited an invalid environment";
         end if;
         Set_Entry (Result, Name, Value);
      end Include;
   begin
      Ada.Environment_Variables.Iterate (Include'Access);
      Sort_Entries (Result);
      return Result;
   end Current_Environment;

   function Fingerprint
     (Entries : Environment_Vectors.Vector) return U64
   is
      Data : Buffer;
   begin
      for Variable of Entries loop
         US.Append (Data, US.To_String (Variable.Name));
         Put_U8 (Data, 0);
         US.Append (Data, US.To_String (Variable.Value));
         Put_U8 (Data, 0);
      end loop;
      return Hash (US.To_String (Data));
   end Fingerprint;

   procedure Put_Metric_Summary
     (Data : in out Buffer; Value : Metric_Summary) is
   begin
      Put_Boolean (Data, Value.Available);
      Put_Natural (Data, Value.Samples);
      Put_Float (Data, Value.Minimum);
      Put_Float (Data, Value.Maximum);
      Put_Float (Data, Value.Mean);
      Put_Float (Data, Value.Median);
      Put_Float (Data, Value.P95);
      Put_Float (Data, Value.P99);
      Put_Float (Data, Value.Confidence_Low);
      Put_Float (Data, Value.Confidence_High);
   end Put_Metric_Summary;

   function Get_Metric_Summary
     (Data : String; Cursor : aliased in out Natural) return Metric_Summary
   is
      Result : Metric_Summary;
   begin
      Result.Available := Get_Boolean (Data, Cursor);
      Result.Samples := Get_Natural (Data, Cursor);
      Result.Minimum := Get_Float (Data, Cursor);
      Result.Maximum := Get_Float (Data, Cursor);
      Result.Mean := Get_Float (Data, Cursor);
      Result.Median := Get_Float (Data, Cursor);
      Result.P95 := Get_Float (Data, Cursor);
      Result.P99 := Get_Float (Data, Cursor);
      Result.Confidence_Low := Get_Float (Data, Cursor);
      Result.Confidence_High := Get_Float (Data, Cursor);
      return Result;
   end Get_Metric_Summary;

   procedure Put_Metric_Comparison
     (Data : in out Buffer; Value : Metric_Comparison_Result) is
   begin
      Put_Boolean (Data, Value.Available);
      Put_Natural (Data, Metric_Comparison_Method'Pos (Value.Method));
      Put_Float (Data, Value.Reference_Median);
      Put_Float (Data, Value.Contender_Median);
      Put_Float (Data, Value.Change);
      Put_Float (Data, Value.Confidence_Low);
      Put_Float (Data, Value.Confidence_High);
      Put_Natural (Data, Metric_Verdict'Pos (Value.Verdict));
   end Put_Metric_Comparison;

   function Get_Metric_Comparison
     (Data : String; Cursor : aliased in out Natural)
      return Metric_Comparison_Result
   is
      Result : Metric_Comparison_Result;
   begin
      Result.Available := Get_Boolean (Data, Cursor);
      Result.Method := Metric_Comparison_Method'Val (Get_Natural (Data, Cursor));
      Result.Reference_Median := Get_Float (Data, Cursor);
      Result.Contender_Median := Get_Float (Data, Cursor);
      Result.Change := Get_Float (Data, Cursor);
      Result.Confidence_Low := Get_Float (Data, Cursor);
      Result.Confidence_High := Get_Float (Data, Cursor);
      Result.Verdict := Metric_Verdict'Val (Get_Natural (Data, Cursor));
      return Result;
   end Get_Metric_Comparison;

   procedure Put_Environment_Report
     (Data : in out Buffer; Value : Environment_Report) is
   begin
      Put_Boolean (Data, Value.Watched);
      Put_Natural (Data, Interference_Source'Pos (Value.Attribution));
      Put_Natural (Data, Value.Windows);
      Put_Natural (Data, Value.Observed_Samples);
      Put_Float (Data, Value.Mean_Foreign_CPU_Percent);
      Put_Float (Data, Value.Peak_Foreign_CPU_Percent);
      Put_Natural (Data, Value.Contaminated_Samples);
      Put_Natural (Data, Value.Retaken_Samples);
      Put_Natural (Data, Value.Pauses);
      Put_Float (Data, Value.Paused_Nanoseconds);
      Put_Boolean (Data, Value.Budget_Exhausted);
      Put_Natural (Data, Placement_Outcome'Pos (Value.Placement));
      Put_Natural (Data, Value.Watched_CPUs);
      Put_Boolean (Data, Value.Attribution_Diluted);
      Put_Natural (Data, Host_Lock_Outcome'Pos (Value.Host_Lock));
   end Put_Environment_Report;

   function Get_Environment_Report
     (Data : String; Cursor : aliased in out Natural) return Environment_Report
   is
      Result : Environment_Report;
   begin
      Result.Watched := Get_Boolean (Data, Cursor);
      Result.Attribution := Interference_Source'Val (Get_Natural (Data, Cursor));
      Result.Windows := Get_Natural (Data, Cursor);
      Result.Observed_Samples := Get_Natural (Data, Cursor);
      Result.Mean_Foreign_CPU_Percent := Get_Float (Data, Cursor);
      Result.Peak_Foreign_CPU_Percent := Get_Float (Data, Cursor);
      Result.Contaminated_Samples := Get_Natural (Data, Cursor);
      Result.Retaken_Samples := Get_Natural (Data, Cursor);
      Result.Pauses := Get_Natural (Data, Cursor);
      Result.Paused_Nanoseconds := Get_Float (Data, Cursor);
      Result.Budget_Exhausted := Get_Boolean (Data, Cursor);
      Result.Placement := Placement_Outcome'Val (Get_Natural (Data, Cursor));
      Result.Watched_CPUs := Get_Natural (Data, Cursor);
      Result.Attribution_Diluted := Get_Boolean (Data, Cursor);
      Result.Host_Lock := Host_Lock_Outcome'Val (Get_Natural (Data, Cursor));
      return Result;
   end Get_Environment_Report;

   procedure Put_Measurement
     (Data : in out Buffer; Value : Measurement) is
      Metrics : constant Metric_Store_Access := Value.Metric_Data.Data;
   begin
      Put_Natural (Data, Value.Sample_Total);
      Put_U64 (Data, U64 (Value.Iterations));
      Put_Float (Data, Value.Timer_Cost);
      Put_Float (Data, Value.Median_Timer_Cost);
      Put_Float (Data, Value.Clock_Resolution);
      Put_Float (Data, Value.Observed_Resolution);
      Put_Natural (Data, Value.Clock_Backend_Id);
      Put_Float (Data, Value.Median_Batch);
      Put_Float (Data, Value.Minimum);
      Put_Float (Data, Value.Maximum);
      Put_Float (Data, Value.Mean);
      Put_Float (Data, Value.Median);
      Put_Float (Data, Value.Standard_Deviation);
      Put_Float (Data, Value.MAD);
      Put_Float (Data, Value.P95);
      Put_Float (Data, Value.P99);
      Put_Float (Data, Value.Confidence_Low);
      Put_Float (Data, Value.Confidence_High);
      Put_Float (Data, Value.CV_Percent);
      Put_Natural (Data, Value.Outlier_Total.Low_Severe);
      Put_Natural (Data, Value.Outlier_Total.Low_Mild);
      Put_Natural (Data, Value.Outlier_Total.High_Mild);
      Put_Natural (Data, Value.Outlier_Total.High_Severe);
      Put_Float (Data, Value.Lag_One);
      Put_Integer (Data, Value.Random_Seed_Value);
      Put_Boolean (Data, Value.Telemetry_Available);
      Put_Float (Data, Value.Telemetry_CPU_Total);
      Put_Float (Data, Value.Telemetry_Wall_Total);
      Put_Float (Data, Value.Telemetry_RSS_Start);
      Put_Float (Data, Value.Telemetry_RSS_Final);
      Put_Float (Data, Value.Telemetry_RSS_Peak);
      Put_Float (Data, Value.Telemetry_RSS_Change_Total);
      Put_Float (Data, Value.Telemetry_RSS_Change_Peak);
      Put_Environment_Report (Data, Value.Environment_Data);
      for Index in Sample_Index range 1 .. Value.Sample_Total loop
         Put_Float (Data, Value.Values (Index));
         Put_Float (Data, Value.Telemetry_CPU (Index));
         Put_Float (Data, Value.Telemetry_RSS (Index));
         Put_Float (Data, Value.Telemetry_RSS_Delta (Index));
         Put_Float (Data, Value.Foreign_CPU (Index));
      end loop;

      Put_Boolean (Data, Metrics /= null);
      if Metrics /= null then
         for Axis in Metric_Axis loop
            Put_Boolean (Data, Metrics.Requested (Axis));
            Put_Boolean (Data, Metrics.Available (Axis));
            Put_Natural
              (Data, Metric_Availability'Pos (Metrics.Status (Axis)));
            Put_Metric_Summary (Data, Metrics.Summaries (Axis));
            for Index in Sample_Index range 1 .. Value.Sample_Total loop
               Put_Float (Data, Metrics.Values (Axis, Index));
            end loop;
         end loop;
      end if;
   end Put_Measurement;

   function Get_Measurement
     (Data : String; Cursor : aliased in out Natural) return Measurement
   is
      Result : Measurement;
      Count  : constant Sample_Count :=
        Sample_Count (Get_Natural (Data, Cursor));
      Has_Metrics : Boolean;
   begin
      Result.Sample_Total := Count;
      Result.Iterations := Iteration_Count (Get_U64 (Data, Cursor));
      Result.Timer_Cost := Get_Float (Data, Cursor);
      Result.Median_Timer_Cost := Get_Float (Data, Cursor);
      Result.Clock_Resolution := Get_Float (Data, Cursor);
      Result.Observed_Resolution := Get_Float (Data, Cursor);
      Result.Clock_Backend_Id := Get_Natural (Data, Cursor);
      if Result.Clock_Backend_Id not in 1 .. 2 then
         raise Protocol_Error with "invalid worker clock backend";
      end if;
      Result.Median_Batch := Get_Float (Data, Cursor);
      Result.Minimum := Get_Float (Data, Cursor);
      Result.Maximum := Get_Float (Data, Cursor);
      Result.Mean := Get_Float (Data, Cursor);
      Result.Median := Get_Float (Data, Cursor);
      Result.Standard_Deviation := Get_Float (Data, Cursor);
      Result.MAD := Get_Float (Data, Cursor);
      Result.P95 := Get_Float (Data, Cursor);
      Result.P99 := Get_Float (Data, Cursor);
      Result.Confidence_Low := Get_Float (Data, Cursor);
      Result.Confidence_High := Get_Float (Data, Cursor);
      Result.CV_Percent := Get_Float (Data, Cursor);
      Result.Outlier_Total.Low_Severe := Get_Natural (Data, Cursor);
      Result.Outlier_Total.Low_Mild := Get_Natural (Data, Cursor);
      Result.Outlier_Total.High_Mild := Get_Natural (Data, Cursor);
      Result.Outlier_Total.High_Severe := Get_Natural (Data, Cursor);
      Result.Lag_One := Get_Float (Data, Cursor);
      Result.Random_Seed_Value := To_Integer (Get_U64 (Data, Cursor));
      Result.Telemetry_Available := Get_Boolean (Data, Cursor);
      Result.Telemetry_CPU_Total := Get_Float (Data, Cursor);
      Result.Telemetry_Wall_Total := Get_Float (Data, Cursor);
      Result.Telemetry_RSS_Start := Get_Float (Data, Cursor);
      Result.Telemetry_RSS_Final := Get_Float (Data, Cursor);
      Result.Telemetry_RSS_Peak := Get_Float (Data, Cursor);
      Result.Telemetry_RSS_Change_Total := Get_Float (Data, Cursor);
      Result.Telemetry_RSS_Change_Peak := Get_Float (Data, Cursor);
      Result.Environment_Data := Get_Environment_Report (Data, Cursor);
      for Index in Sample_Index range 1 .. Count loop
         Result.Values (Index) := Get_Float (Data, Cursor);
         Result.Telemetry_CPU (Index) := Get_Float (Data, Cursor);
         Result.Telemetry_RSS (Index) := Get_Float (Data, Cursor);
         Result.Telemetry_RSS_Delta (Index) := Get_Float (Data, Cursor);
         Result.Foreign_CPU (Index) := Get_Float (Data, Cursor);
      end loop;
      Has_Metrics := Get_Boolean (Data, Cursor);
      if Has_Metrics then
         Result.Metric_Data.Data := new Metric_Store;
         for Axis in Metric_Axis loop
            Result.Metric_Data.Data.Requested (Axis) :=
              Get_Boolean (Data, Cursor);
            Result.Metric_Data.Data.Available (Axis) :=
              Get_Boolean (Data, Cursor);
            Result.Metric_Data.Data.Status (Axis) := Metric_Availability'Val
              (Get_Natural (Data, Cursor));
            Result.Metric_Data.Data.Summaries (Axis) :=
              Get_Metric_Summary (Data, Cursor);
            for Index in Sample_Index range 1 .. Count loop
               Result.Metric_Data.Data.Values (Axis, Index) :=
                 Get_Float (Data, Cursor);
            end loop;
         end loop;
      end if;
      return Result;
   exception
      when Constraint_Error =>
         raise Protocol_Error with "worker measurement value is out of range";
   end Get_Measurement;

   procedure Put_Comparison
     (Data : in out Buffer; Value : Comparison) is
   begin
      Put_Measurement (Data, Value.Reference_Data);
      Put_Measurement (Data, Value.Contender_Data);
      Put_Float (Data, Value.Geometric_Speedup);
      Put_Float (Data, Value.Median_Speedup_Value);
      Put_Float (Data, Value.Speedup_CI_Low);
      Put_Float (Data, Value.Speedup_CI_High);
      Put_Float (Data, Value.Mean_Time_Difference);
      Put_Natural (Data, Value.Contender_Win_Total);
      Put_Natural (Data, Value.Reference_Win_Total);
      Put_Natural (Data, Value.Tie_Total);
      Put_Natural (Data, Value.Reference_First);
      Put_Natural (Data, Value.Contender_First);
      Put_Float (Data, Value.Order_Effect);
      Put_Float (Data, Value.Lag_One);
      Put_Float (Data, Value.Practical_Threshold);
      Put_Integer (Data, Value.Random_Seed_Value);
      Put_Natural (Data, Comparison_Verdict'Pos (Value.Verdict_Value));
      for Index in Sample_Index range 1 .. Value.Reference_Data.Sample_Total loop
         Put_Float (Data, Value.Speedup_Values (Index));
         Put_Boolean (Data, Value.Reference_First_Order (Index));
      end loop;
      for Axis in Metric_Axis loop
         Put_Metric_Comparison (Data, Value.Metric_Comparisons (Axis));
      end loop;
   end Put_Comparison;

   function Get_Comparison
     (Data : String; Cursor : aliased in out Natural) return Comparison
   is
      Result : Comparison;
   begin
      Result.Reference_Data := Get_Measurement (Data, Cursor);
      Result.Contender_Data := Get_Measurement (Data, Cursor);
      if Result.Reference_Data.Sample_Total
        /= Result.Contender_Data.Sample_Total
      then
         raise Protocol_Error with "worker comparison sample counts differ";
      end if;
      Result.Geometric_Speedup := Get_Float (Data, Cursor);
      Result.Median_Speedup_Value := Get_Float (Data, Cursor);
      Result.Speedup_CI_Low := Get_Float (Data, Cursor);
      Result.Speedup_CI_High := Get_Float (Data, Cursor);
      Result.Mean_Time_Difference := Get_Float (Data, Cursor);
      Result.Contender_Win_Total := Get_Natural (Data, Cursor);
      Result.Reference_Win_Total := Get_Natural (Data, Cursor);
      Result.Tie_Total := Get_Natural (Data, Cursor);
      Result.Reference_First := Get_Natural (Data, Cursor);
      Result.Contender_First := Get_Natural (Data, Cursor);
      Result.Order_Effect := Get_Float (Data, Cursor);
      Result.Lag_One := Get_Float (Data, Cursor);
      Result.Practical_Threshold := Get_Float (Data, Cursor);
      Result.Random_Seed_Value := To_Integer (Get_U64 (Data, Cursor));
      Result.Verdict_Value := Comparison_Verdict'Val
        (Get_Natural (Data, Cursor));
      for Index in Sample_Index range 1 .. Result.Reference_Data.Sample_Total loop
         Result.Speedup_Values (Index) := Get_Float (Data, Cursor);
         Result.Reference_First_Order (Index) := Get_Boolean (Data, Cursor);
      end loop;
      for Axis in Metric_Axis loop
         Result.Metric_Comparisons (Axis) :=
           Get_Metric_Comparison (Data, Cursor);
      end loop;
      return Result;
   exception
      when Constraint_Error =>
         raise Protocol_Error with "worker comparison value is out of range";
   end Get_Comparison;

   procedure Validate_Measurement_Result
     (Value         : Measurement;
      Expected_Seed : Long_Long_Integer)
   is
      Count : constant Natural := Natural (Value.Sample_Total);
      Classified : Natural := 0;

      procedure Add_Classified (Amount : Natural) is
      begin
         if Amount > Count - Classified then
            raise Protocol_Error with
              "worker measurement outlier counts exceed its samples";
         end if;
         Classified := Classified + Amount;
      end Add_Classified;
   begin
      if Value.Random_Seed_Value /= Expected_Seed then
         raise Protocol_Error with "worker measurement seed mismatch";
      end if;
      Add_Classified (Value.Outlier_Total.Low_Severe);
      Add_Classified (Value.Outlier_Total.Low_Mild);
      Add_Classified (Value.Outlier_Total.High_Mild);
      Add_Classified (Value.Outlier_Total.High_Severe);
      if Value.Metric_Data.Data /= null then
         for Axis in Metric_Axis loop
            if Value.Metric_Data.Data.Summaries (Axis).Samples > Count then
               raise Protocol_Error with
                 "worker metric summary count exceeds measurement samples";
            end if;
         end loop;
      end if;
   end Validate_Measurement_Result;

   procedure Validate_Comparison_Result
     (Value         : Comparison;
      Expected_Seed : Long_Long_Integer)
   is
      Count : constant Natural := Natural (Value.Reference_Data.Sample_Total);
      Outcomes : Natural := 0;
      Orders : Natural := 0;
      Observed_Reference_First : Natural := 0;

      procedure Add_Bounded
        (Amount : Natural;
         Total  : in out Natural;
         Label  : String) is
      begin
         if Amount > Count - Total then
            raise Protocol_Error with Label;
         end if;
         Total := Total + Amount;
      end Add_Bounded;
   begin
      Validate_Measurement_Result (Value.Reference_Data, Expected_Seed);
      Validate_Measurement_Result (Value.Contender_Data, Expected_Seed);
      if Value.Random_Seed_Value /= Expected_Seed then
         raise Protocol_Error with "worker comparison seed mismatch";
      end if;
      Add_Bounded
        (Value.Contender_Win_Total, Outcomes,
         "worker comparison outcome counts exceed its samples");
      Add_Bounded
        (Value.Reference_Win_Total, Outcomes,
         "worker comparison outcome counts exceed its samples");
      Add_Bounded
        (Value.Tie_Total, Outcomes,
         "worker comparison outcome counts exceed its samples");
      if Outcomes /= Count then
         raise Protocol_Error with
           "worker comparison outcome counts do not cover its samples";
      end if;
      Add_Bounded
        (Value.Reference_First, Orders,
         "worker comparison order counts exceed its samples");
      Add_Bounded
        (Value.Contender_First, Orders,
         "worker comparison order counts exceed its samples");
      if Orders /= Count then
         raise Protocol_Error with
           "worker comparison order counts do not cover its samples";
      end if;
      for Index in Sample_Index range 1 .. Value.Reference_Data.Sample_Total loop
         if Value.Reference_First_Order (Index) then
            Observed_Reference_First := Observed_Reference_First + 1;
         end if;
      end loop;
      if Observed_Reference_First /= Value.Reference_First then
         raise Protocol_Error with
           "worker comparison order flags disagree with its counts";
      end if;
   end Validate_Comparison_Result;

   procedure Write_All (Data : String) is
      Offset : Natural := 0;
      Wrote  : C.long;
   begin
      while Offset < Data'Length loop
         Wrote := C_Write
           (Result_FD,
            Data (Data'First + Offset)'Address,
            C.size_t (Data'Length - Offset));
         if Wrote > 0 then
            Offset := Offset + Natural (Wrote);
         elsif Wrote < 0
           and then C.int (GNAT.OS_Lib.Errno) = Interrupted_Error
         then
            null;
         else
            raise Protocol_Error with "cannot write worker result envelope";
         end if;
      end loop;
   end Write_All;

   procedure Put_Common
     (Frame_Body : in out Buffer;
      Request : Worker_Request) is
   begin
      Put_String (Frame_Body, US.To_String (Request.Identity_Value));
      Put_Natural (Frame_Body, Result_Kind'Pos (Request.Kind_Value));
      Put_Natural (Frame_Body, Request.Repetition_Value);
      Put_Integer (Frame_Body, Request.Seed_Value);
      Put_U64 (Frame_Body, Request.Environment_Hash);
      Put_U64 (Frame_Body, Request.Configuration_Hash);
      Put_Natural (Frame_Body, Environment_Mode'Pos (Request.Policy_Value));
   end Put_Common;

   procedure Write_Frame (Frame : U32; Frame_Body : Buffer) is
      Envelope : Buffer;
   begin
      if US.Length (Frame_Body) > Maximum_Protocol_Bytes then
         raise Protocol_Error with "worker result envelope is oversized";
      end if;
      US.Append (Envelope, Frame_Magic);
      Put_U32 (Envelope, U32 (Protocol_Version));
      Put_U32 (Envelope, Frame);
      Put_U32 (Envelope, U32 (US.Length (Frame_Body)));
      US.Append (Envelope, US.To_String (Frame_Body));
      Write_All (US.To_String (Envelope));
   end Write_Frame;

   function Prefix_Value (Argument, Prefix : String) return String is
   begin
      if Argument'Length < Prefix'Length
        or else Argument
          (Argument'First .. Argument'First + Prefix'Length - 1) /= Prefix
      then
         raise Protocol_Error with "invalid internal worker argument";
      end if;
      return Argument
        (Argument'First + Prefix'Length .. Argument'Last);
   end Prefix_Value;

   function Parse_Positive (Value : String) return Positive is
      Result : Natural := 0;
   begin
      if Value'Length = 0 then
         raise Protocol_Error with "empty internal worker integer";
      end if;
      for Element of Value loop
         if Element not in '0' .. '9'
           or else Result > (Natural'Last -
             (Character'Pos (Element) - Character'Pos ('0'))) / 10
         then
            raise Protocol_Error with "invalid internal worker integer";
         end if;
         Result := Result * 10
           + Character'Pos (Element) - Character'Pos ('0');
      end loop;
      if Result = 0 then
         raise Protocol_Error with "internal worker integer must be positive";
      end if;
      return Positive (Result);
   end Parse_Positive;

   function Parse_Integer (Value : String) return Long_Long_Integer is
      Negative : Boolean := False;
      Cursor   : Natural := Value'First;
      Result   : Long_Long_Integer := 0;
      Digit    : Natural;
   begin
      if Value'Length = 0 then
         raise Protocol_Error with "empty internal worker seed";
      end if;
      if Value (Cursor) = '-' then
         Negative := True;
         Cursor := Cursor + 1;
      elsif Value (Cursor) = '+' then
         raise Protocol_Error with "noncanonical internal worker seed";
      end if;
      if Cursor > Value'Last then
         raise Protocol_Error with "invalid internal worker seed";
      end if;
      while Cursor <= Value'Last loop
         if Value (Cursor) not in '0' .. '9' then
            raise Protocol_Error with "invalid internal worker seed";
         end if;
         Digit := Character'Pos (Value (Cursor)) - Character'Pos ('0');
         if Result > (Long_Long_Integer'Last - Long_Long_Integer (Digit)) / 10 then
            raise Protocol_Error with "internal worker seed is out of range";
         end if;
         Result := Result * 10 + Long_Long_Integer (Digit);
         Cursor := Cursor + 1;
      end loop;
      if Negative then
         return -Result;
      end if;
      return Result;
   end Parse_Integer;

   function Worker_Mode return Boolean is
     (Ada.Command_Line.Argument_Count > 0
      and then Ada.Command_Line.Argument (1) = Worker_Marker);

   function Current_Request return Worker_Request is
      Result : Worker_Request;
      Version : Positive;
   begin
      if not Worker_Mode or else Ada.Command_Line.Argument_Count /= 8 then
         raise Protocol_Error with "invalid internal worker invocation";
      end if;
      Version := Parse_Positive
        (Prefix_Value (Ada.Command_Line.Argument (1),
                       "--flyology-bench-worker="));
      if Version /= Protocol_Version then
         raise Protocol_Error with "unsupported worker protocol version";
      end if;
      declare
         Config_Bytes : constant String := Hex_Decode
           (Prefix_Value (Ada.Command_Line.Argument (7), "--config="),
            Maximum_Configuration_Bytes);
         Identity_Bytes : constant String := Hex_Decode
           (Prefix_Value (Ada.Command_Line.Argument (2), "--identity="),
            Maximum_Identity_Length);
      begin
         if Identity_Bytes'Length = 0 or else Contains_NUL (Identity_Bytes) then
            raise Protocol_Error with "invalid worker identity";
         end if;
         Result.Identity_Value := US.To_Unbounded_String (Identity_Bytes);
         Result.Kind_Value := Result_Kind'Val
           (Parse_Positive
              (Prefix_Value (Ada.Command_Line.Argument (3), "--kind=")) - 1);
         Result.Repetition_Value := Parse_Positive
           (Prefix_Value (Ada.Command_Line.Argument (4), "--repetition="));
         Result.Seed_Value := Parse_Integer
           (Prefix_Value (Ada.Command_Line.Argument (5), "--seed="));
         Result.Environment_Hash := Parse_Hex_U64
           (Prefix_Value (Ada.Command_Line.Argument (6), "--environment="));
         Result.Config_Value := Decode_Configuration
           (Config_Bytes, Default_Configuration);
         Result.Config_Value.Random_Seed := Result.Seed_Value;
         Result.Configuration_Hash := Hash (Config_Bytes);
         Result.Policy_Value := Environment_Mode'Val
           (Parse_Positive
              (Prefix_Value
                 (Ada.Command_Line.Argument (8), "--environment-policy=")) - 1);
      end;
      if Fingerprint (Current_Environment) /= Result.Environment_Hash then
         raise Protocol_Error with "worker environment fingerprint mismatch";
      end if;
      return Result;
   exception
      when Constraint_Error =>
         raise Protocol_Error with "internal worker argument is out of range";
   end Current_Request;

   function Requested_Identity (Request : Worker_Request) return String is
     (US.To_String (Request.Identity_Value));
   function Requested_Kind (Request : Worker_Request) return Result_Kind is
     (Request.Kind_Value);
   function Requested_Repetition (Request : Worker_Request) return Positive is
     (Request.Repetition_Value);
   function Requested_Seed
     (Request : Worker_Request) return Long_Long_Integer is
     (Request.Seed_Value);

   function Requested_Configuration
     (Request  : Worker_Request;
      Template : Configuration := Default_Configuration)
      return Configuration
   is
      Result : Configuration := Request.Config_Value;
   begin
      Result.Scheduler_Probe := Template.Scheduler_Probe;
      Result.Progress := Template.Progress;
      return Result;
   end Requested_Configuration;

   procedure Announce_Ready (Request : Worker_Request) is
      Frame_Body : Buffer;
   begin
      Put_Common (Frame_Body, Request);
      Put_U64 (Frame_Body, Completion_Marker);
      Write_Frame (Ready_Frame, Frame_Body);
   end Announce_Ready;

   type Envelope_Status is
     (Envelope_Normal, Envelope_Exception, Envelope_Invalid);

   procedure Return_Envelope
     (Request : Worker_Request;
      Status  : Envelope_Status;
      Kind    : Result_Kind;
      Payload : Buffer) is
      Frame_Body : Buffer;
   begin
      Put_Common (Frame_Body, Request);
      Put_Natural (Frame_Body, Envelope_Status'Pos (Status));
      Put_Natural (Frame_Body, Result_Kind'Pos (Kind));
      Put_Natural (Frame_Body, US.Length (Payload));
      US.Append (Frame_Body, US.To_String (Payload));
      Put_U64 (Frame_Body, Completion_Marker);
      Write_Frame (Result_Frame, Frame_Body);
   end Return_Envelope;

   procedure Return_Result
     (Request : Worker_Request;
      Result  : Measurement) is
      Payload : Buffer;
   begin
      if Request.Kind_Value /= Ordinary_Measurement then
         raise Protocol_Error with "worker returned the wrong result kind";
      end if;
      Put_Measurement (Payload, Result);
      Return_Envelope
        (Request, Envelope_Normal, Ordinary_Measurement, Payload);
   end Return_Result;

   procedure Return_Result
     (Request : Worker_Request;
      Result  : Comparison) is
      Payload : Buffer;
   begin
      if Request.Kind_Value /= Paired_Comparison then
         raise Protocol_Error with "worker returned the wrong result kind";
      end if;
      Put_Comparison (Payload, Result);
      Return_Envelope (Request, Envelope_Normal, Paired_Comparison, Payload);
   end Return_Result;

   procedure Return_Benchmark_Exception
     (Request : Worker_Request;
      Name    : String;
      Message : String) is
      Payload : Buffer;

      function Bounded (Value : String; Maximum : Positive) return String is
        (if Value'Length <= Maximum then Value
         else Value (Value'First .. Value'First + Maximum - 1));
   begin
      Put_String (Payload, Bounded (Name, Maximum_Exception_Name_Length));
      Put_String (Payload, Bounded (Message, Maximum_Result_Message_Length));
      Return_Envelope
        (Request, Envelope_Exception, Request.Kind_Value, Payload);
   end Return_Benchmark_Exception;

   procedure Return_Invalid_Configuration
     (Request : Worker_Request;
      Message : String) is
      Payload : Buffer;

      function Bounded (Value : String; Maximum : Positive) return String is
        (if Value'Length <= Maximum then Value
         else Value (Value'First .. Value'First + Maximum - 1));
   begin
      Put_String (Payload, Bounded (Message, Maximum_Result_Message_Length));
      Return_Envelope
        (Request, Envelope_Invalid, Request.Kind_Value, Payload);
   end Return_Invalid_Configuration;

   type Process_Guard is new Ada.Finalization.Limited_Controlled with record
      Pid : aliased C.int := -1;
      Descriptors : Descriptor_Array := (others => -1);
   end record;

   overriding procedure Finalize (Process : in out Process_Guard);

   --  A protected action is abort-deferred.  A successful posix_spawn return
   --  therefore publishes the PID and every parent endpoint into the
   --  controlled guard before a pending caller abort can take effect.
   protected type Spawn_Adopter is
      procedure Start
        (Process             : in out Process_Guard;
         Executable          : CS.chars_ptr;
         Arguments           : System.Address;
         Environment         : System.Address;
         Working_Directory   : CS.chars_ptr;
         Result              : out C.int);
   end Spawn_Adopter;

   protected body Spawn_Adopter is
      procedure Start
        (Process             : in out Process_Guard;
         Executable          : CS.chars_ptr;
         Arguments           : System.Address;
         Environment         : System.Address;
         Working_Directory   : CS.chars_ptr;
         Result              : out C.int) is
      begin
         Process.Pid := -1;
         Process.Descriptors := (others => -1);
         Result := C_Spawn
           (Process.Pid'Access, Process.Descriptors'Address, Executable,
            Arguments, Environment, Working_Directory);
         if Result /= 0 then
            Process.Pid := -1;
            Process.Descriptors := (others => -1);
         end if;
      end Start;
   end Spawn_Adopter;

   procedure Close_Descriptor (Descriptor : in out C.int) is
      Ignored : C.int;
   begin
      if Descriptor >= 0 then
         Ignored := C_Close (Descriptor);
         Descriptor := -1;
      end if;
   end Close_Descriptor;

   procedure Reap (Process : in out Process_Guard; Raw_Status : out C.int) is
      Result : C.int;
      Status : aliased C.int := 0;
   begin
      Raw_Status := 0;
      if Process.Pid <= 0 then
         return;
      end if;
      loop
         Result := C_Waitpid (Process.Pid, Status'Access, 0);
         exit when Result = Process.Pid;
         if Result < 0
           and then C.int (GNAT.OS_Lib.Errno) = Interrupted_Error
         then
            null;
         else
            exit;
         end if;
      end loop;
      Raw_Status := Status;
      Process.Pid := -1;
   end Reap;

   overriding procedure Finalize (Process : in out Process_Guard) is
      Ignored : C.int;
      Raw     : aliased C.int;
   begin
      if Process.Pid > 0 then
         Ignored := C_Kill (-Process.Pid, C_Signal_Kill);
         Reap (Process, Raw);
      end if;
      for Descriptor of Process.Descriptors loop
         Close_Descriptor (Descriptor);
      end loop;
   exception
      when others => null;
   end Finalize;

   procedure Free_C_Strings (Items : in out Chars_Ptr_Array) is
   begin
      for Item of Items loop
         if Item /= CS.Null_Ptr then
            CS.Free (Item);
         end if;
      end loop;
   end Free_C_Strings;

   function Elapsed_Nanoseconds
     (Started, Finished : Ada.Real_Time.Time) return Long_Float is
     (Long_Float (Ada.Real_Time.To_Duration (Finished - Started))
      * 1_000_000_000.0);

   procedure Drain
     (Descriptor : in out C.int;
      Data       : in out Buffer;
      Capacity   : Natural;
      Omitted    : in out Natural;
      EOF        : out Boolean;
      Failed     : in out Boolean) is
      Chunk : aliased String (1 .. 8_192);
      Count : C.long;
      Keep  : Natural;
      Remaining : Natural := Maximum_Drain_Bytes_Per_Pass;
   begin
      EOF := Descriptor < 0;
      if EOF then
         return;
      end if;
      while Remaining > 0 loop
         Count := C_Read
           (Descriptor, Chunk'Address,
            C.size_t (Natural'Min (Chunk'Length, Remaining)));
         if Count > 0 then
            Remaining := Remaining - Natural (Count);
            Keep := Natural'Min
              (Natural (Count), Capacity - Natural'Min (Capacity, US.Length (Data)));
            if Keep > 0 then
               US.Append (Data, Chunk (1 .. Keep));
            end if;
            if Natural (Count) > Keep then
               if Omitted > Natural'Last - (Natural (Count) - Keep) then
                  Omitted := Natural'Last;
               else
                  Omitted := Omitted + Natural (Count) - Keep;
               end if;
            end if;
         elsif Count = 0 then
            Close_Descriptor (Descriptor);
            EOF := True;
            return;
         elsif C.int (GNAT.OS_Lib.Errno) = Interrupted_Error then
            --  Return to the orchestration loop so a signal storm cannot
            --  postpone deadline and process-state checks.
            return;
         elsif C.int (GNAT.OS_Lib.Errno) = Would_Block_Error then
            return;
         else
            Failed := True;
            Close_Descriptor (Descriptor);
            EOF := True;
            return;
         end if;
      end loop;
   end Drain;

   procedure Get_Common
     (Data              : String;
      Cursor            : aliased in out Natural;
      Expected_Identity : String;
      Expected_Kind     : Result_Kind;
      Expected_Rep      : Positive;
      Expected_Seed     : Long_Long_Integer;
      Expected_Env      : U64;
      Expected_Config   : U64;
      Expected_Policy   : Environment_Mode) is
      Found_Identity : constant String :=
        Get_String (Data, Cursor, Maximum_Identity_Length);
      Found_Kind : constant Result_Kind := Result_Kind'Val
        (Get_Natural (Data, Cursor));
      Found_Rep : constant Positive := Positive (Get_Natural (Data, Cursor));
      Found_Seed : constant Long_Long_Integer :=
        To_Integer (Get_U64 (Data, Cursor));
      Found_Env : constant U64 := Get_U64 (Data, Cursor);
      Found_Config : constant U64 := Get_U64 (Data, Cursor);
      Found_Policy : constant Environment_Mode := Environment_Mode'Val
        (Get_Natural (Data, Cursor));
   begin
      if Found_Identity /= Expected_Identity
        or else Found_Kind /= Expected_Kind
        or else Found_Rep /= Expected_Rep
        or else Found_Seed /= Expected_Seed
        or else Found_Env /= Expected_Env
        or else Found_Config /= Expected_Config
        or else Found_Policy /= Expected_Policy
      then
         raise Protocol_Error with "worker result identity or metadata mismatch";
      end if;
   exception
      when Constraint_Error =>
         raise Protocol_Error with "worker common metadata is out of range";
   end Get_Common;

   procedure Get_Frame
     (Data       : String;
      Cursor     : aliased in out Natural;
      Frame      : out U32;
      Body_First : out Natural;
      Body_Last  : out Natural) is
      Version : U32;
      Length  : Natural;
   begin
      if Cursor > Data'Last
        or else Data'Last - Cursor + 1 < Frame_Magic'Length + 12
      then
         raise Protocol_Error with "truncated worker frame header";
      end if;
      if Data (Cursor .. Cursor + Frame_Magic'Length - 1) /= Frame_Magic then
         raise Protocol_Error with "invalid worker frame magic";
      end if;
      Cursor := Cursor + Frame_Magic'Length;
      Version := Get_U32 (Data, Cursor);
      if Version /= U32 (Protocol_Version) then
         raise Protocol_Error with "unsupported worker frame version";
      end if;
      Frame := Get_U32 (Data, Cursor);
      Length := Natural (Get_U32 (Data, Cursor));
      if Length > Maximum_Protocol_Bytes
        or else Length > Data'Last - Cursor + 1
      then
         raise Protocol_Error with "truncated or oversized worker frame";
      end if;
      Body_First := Cursor;
      Body_Last := Cursor + Length - 1;
      Cursor := Cursor + Length;
   end Get_Frame;

   procedure Validate_Ready
     (Data              : String;
      Expected_Identity : String;
      Expected_Kind     : Result_Kind;
      Expected_Rep      : Positive;
      Expected_Seed     : Long_Long_Integer;
      Expected_Env      : U64;
      Expected_Config   : U64;
      Expected_Policy   : Environment_Mode;
      Complete          : out Boolean) is
      Cursor : aliased Natural := Data'First;
      Frame : U32;
      First, Last : Natural;
      Body_Cursor : aliased Natural;
   begin
      Complete := False;
      if Data'Length < Frame_Magic'Length + 12 then
         return;
      end if;
      declare
         Header_Cursor : aliased Natural := Data'First + Frame_Magic'Length + 8;
         Length : U32;
      begin
         if Data (Data'First .. Data'First + Frame_Magic'Length - 1)
           /= Frame_Magic
         then
            raise Protocol_Error with "invalid worker startup frame magic";
         end if;
         Length := Get_U32 (Data, Header_Cursor);
         if Natural (Length) > Maximum_Protocol_Bytes then
            raise Protocol_Error with "oversized worker startup frame";
         end if;
         if Data'Length < Frame_Magic'Length + 12 + Natural (Length) then
            return;
         end if;
      end;
      Get_Frame (Data, Cursor, Frame, First, Last);
      if Frame /= Ready_Frame then
         raise Protocol_Error with "worker did not begin with a ready frame";
      end if;
      Body_Cursor := First;
      Get_Common
        (Data, Body_Cursor, Expected_Identity, Expected_Kind, Expected_Rep,
         Expected_Seed, Expected_Env, Expected_Config, Expected_Policy);
      if Get_U64 (Data, Body_Cursor) /= Completion_Marker
        or else Body_Cursor /= Last + 1
      then
         raise Protocol_Error with "invalid worker ready completion marker";
      end if;
      Complete := True;
   end Validate_Ready;

   procedure Decode_Result_Stream
     (Data              : String;
      Expected_Identity : String;
      Expected_Kind     : Result_Kind;
      Expected_Rep      : Positive;
      Expected_Seed     : Long_Long_Integer;
      Expected_Env      : U64;
      Expected_Config   : U64;
      Expected_Policy   : Environment_Mode;
      Target            : in out Worker_Result) is
      Cursor : aliased Natural := Data'First;
      Frame : U32;
      First, Last : Natural;
      Body_Cursor : aliased Natural;
      Status : Envelope_Status;
      Found_Kind : Result_Kind;
      Payload_Length : Natural;
      Payload_First, Payload_Last : Natural;
      Payload_Cursor : aliased Natural;
   begin
      Get_Frame (Data, Cursor, Frame, First, Last);
      if Frame /= Ready_Frame then
         raise Protocol_Error with "worker ready frame is absent";
      end if;
      Body_Cursor := First;
      Get_Common
        (Data, Body_Cursor, Expected_Identity, Expected_Kind, Expected_Rep,
         Expected_Seed, Expected_Env, Expected_Config, Expected_Policy);
      if Get_U64 (Data, Body_Cursor) /= Completion_Marker
        or else Body_Cursor /= Last + 1
      then
         raise Protocol_Error with "invalid worker ready frame";
      end if;

      Get_Frame (Data, Cursor, Frame, First, Last);
      if Frame /= Result_Frame then
         raise Protocol_Error with "worker result frame is absent";
      end if;
      Body_Cursor := First;
      Get_Common
        (Data, Body_Cursor, Expected_Identity, Expected_Kind, Expected_Rep,
         Expected_Seed, Expected_Env, Expected_Config, Expected_Policy);
      Status := Envelope_Status'Val (Get_Natural (Data, Body_Cursor));
      Found_Kind := Result_Kind'Val (Get_Natural (Data, Body_Cursor));
      if Found_Kind /= Expected_Kind then
         raise Protocol_Error with "worker result kind mismatch";
      end if;
      Payload_Length := Get_Natural (Data, Body_Cursor);
      if Payload_Length > Maximum_Protocol_Bytes
        or else Payload_Length > Last - Body_Cursor
      then
         raise Protocol_Error with "invalid worker payload length";
      end if;
      Payload_First := Body_Cursor;
      Payload_Last := Body_Cursor + Payload_Length - 1;
      Body_Cursor := Body_Cursor + Payload_Length;
      if Get_U64 (Data, Body_Cursor) /= Completion_Marker
        or else Body_Cursor /= Last + 1
        or else Cursor /= Data'Last + 1
      then
         raise Protocol_Error with "invalid completion marker or trailing data";
      end if;

      Payload_Cursor := Payload_First;
      case Status is
         when Envelope_Normal =>
            if Expected_Kind = Ordinary_Measurement then
               Target.Measurement_Data := Get_Measurement (Data, Payload_Cursor);
               Validate_Measurement_Result
                 (Target.Measurement_Data, Expected_Seed);
            else
               Target.Comparison_Data := Get_Comparison (Data, Payload_Cursor);
               Validate_Comparison_Result
                 (Target.Comparison_Data, Expected_Seed);
            end if;
            Target.Outcome_Value := Normal_Result;
         when Envelope_Exception =>
            declare
               Name : constant String :=
                 Get_String
                   (Data, Payload_Cursor, Maximum_Exception_Name_Length);
               Message : constant String :=
                 Get_String
                   (Data, Payload_Cursor, Maximum_Result_Message_Length);
            begin
               Target.Outcome_Value := Benchmark_Exception;
               Target.Reason_Value := US.To_Unbounded_String
                 (Name & (if Message'Length = 0 then "" else ": " & Message));
            end;
         when Envelope_Invalid =>
            Target.Outcome_Value := Invalid_Worker_Configuration;
            Target.Reason_Value := US.To_Unbounded_String
              (Get_String
                 (Data, Payload_Cursor, Maximum_Result_Message_Length));
      end case;
      if Payload_Length = 0 then
         if Status /= Envelope_Normal then
            raise Protocol_Error with "empty worker failure payload";
         end if;
      elsif Payload_Cursor /= Payload_Last + 1 then
         raise Protocol_Error with "trailing worker payload data";
      end if;
   exception
      when Constraint_Error =>
         raise Protocol_Error with "worker result value is out of range";
   end Decode_Result_Stream;

   procedure Run_Repetition
     (Executable_Path : String;
      Working_Path    : String;
      Has_Directory   : Boolean;
      Identity_Value  : String;
      Expected_Kind   : Result_Kind;
      Benchmark_Config : Configuration;
      Launch          : Launch_Configuration;
      Environment_List : Environment_Vectors.Vector;
      Environment_Hash : U64;
      Environment_Policy_Value : Environment_Mode;
      Rep             : Positive;
      Target          : out Worker_Result)
   is
      Process : Process_Guard;
      Adopter : Spawn_Adopter;
      Raw_Status : aliased C.int := 0;
      Config_Value : Configuration := Benchmark_Config;
      Seed_Value : constant Long_Long_Integer :=
        Derive_Seed (Benchmark_Config.Random_Seed, Rep);
      Config_Bytes : Buffer;
      Config_Hash : U64;
      Result_Data, Output_Data, Error_Data : Buffer;
      Result_Omitted, Output_Omitted, Error_Omitted : Natural := 0;
      Result_EOF, Output_EOF, Error_EOF : Boolean := False;
      IO_Failed : Boolean := False;
      Ready : Boolean := False;
      Ready_Time : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Spawn_Start, Spawn_End, Now : Ada.Real_Time.Time;
      Startup_Deadline, Total_Deadline, Grace_Deadline : Ada.Real_Time.Time;
      Exit_Observed : Boolean := False;
      Timed_Out : Boolean := False;
      Startup_Expired : Boolean := False;
      Term_Sent : Boolean := False;
      Hard_Sent : Boolean := False;
      Protocol_Failed : Boolean := False;
      Protocol_Reason : US.Unbounded_String;
      Spawn_Result : C.int;
      Ignored : C.int;
   begin
      Target := (others => <>);
      Target.Kind_Value := Expected_Kind;
      Target.Identity_Value := US.To_Unbounded_String (Identity_Value);
      Target.Repetition_Value := Rep;
      Target.Seed_Value := Seed_Value;
      Target.Environment_Hash := Environment_Hash;
      Target.Policy_Value := Environment_Policy_Value;
      Config_Value.Random_Seed := Seed_Value;
      Config_Bytes := US.To_Unbounded_String
        (Encode_Configuration (Config_Value));
      Config_Hash := Hash (US.To_String (Config_Bytes));

      declare
         Environment_Count : constant Natural :=
           Natural (Environment_List.Length);
         Arguments : Chars_Ptr_Array (0 .. 9) := (others => CS.Null_Ptr);
         Variables : Chars_Ptr_Array (0 .. Environment_Count) :=
           (others => CS.Null_Ptr);
         Executable_C : CS.chars_ptr := CS.New_String (Executable_Path);
         Directory_C : CS.chars_ptr := CS.Null_Ptr;
      begin
         Arguments (0) := CS.New_String (Executable_Path);
         Arguments (1) := CS.New_String (Worker_Marker);
         Arguments (2) := CS.New_String
           ("--identity=" & Hex_Encode (Identity_Value));
         Arguments (3) := CS.New_String
           ("--kind=" & Ada.Strings.Fixed.Trim
              (Positive'Image (Result_Kind'Pos (Expected_Kind) + 1),
               Ada.Strings.Both));
         Arguments (4) := CS.New_String
           ("--repetition=" & Ada.Strings.Fixed.Trim
              (Positive'Image (Rep), Ada.Strings.Both));
         Arguments (5) := CS.New_String
           ("--seed=" & Ada.Strings.Fixed.Trim
              (Long_Long_Integer'Image (Seed_Value), Ada.Strings.Both));
         Arguments (6) := CS.New_String
           ("--environment=" & Hex (Environment_Hash));
         Arguments (7) := CS.New_String
           ("--config=" & Hex_Encode (US.To_String (Config_Bytes)));
         Arguments (8) := CS.New_String
           ("--environment-policy=" & Ada.Strings.Fixed.Trim
              (Positive'Image
                 (Environment_Mode'Pos (Environment_Policy_Value) + 1),
               Ada.Strings.Both));
         for Index in 1 .. Environment_Count loop
            declare
               Variable : constant Environment_Entry :=
                 Environment_List.Element (Positive (Index));
            begin
               Variables (Index - 1) := CS.New_String
                 (US.To_String (Variable.Name) & "=" & US.To_String (Variable.Value));
            end;
         end loop;
         if Has_Directory then
            Directory_C := CS.New_String (Working_Path);
         end if;

         Spawn_Start := Ada.Real_Time.Clock;
         Adopter.Start
           (Process, Executable_C, Arguments'Address, Variables'Address,
            Directory_C, Spawn_Result);
         Spawn_End := Ada.Real_Time.Clock;
         CS.Free (Directory_C);
         CS.Free (Executable_C);
         Free_C_Strings (Variables);
         Free_C_Strings (Arguments);
      exception
         when others =>
            CS.Free (Directory_C);
            CS.Free (Executable_C);
            Free_C_Strings (Variables);
            Free_C_Strings (Arguments);
            raise;
      end;

      Target.Spawn_Time := Elapsed_Nanoseconds (Spawn_Start, Spawn_End);
      if Spawn_Result /= 0 then
         Target.Outcome_Value := Spawn_Failure;
         Target.Reason_Value := US.To_Unbounded_String
           ("posix_spawn failed, error=" & Ada.Strings.Fixed.Trim
              (C.int'Image (Spawn_Result), Ada.Strings.Both));
         return;
      end if;

      Target.Pid_Value := Process.Pid;
      for Descriptor of Process.Descriptors loop
         if C_Set_Nonblocking (Descriptor) /= 0 then
            Target.Outcome_Value := Parent_IO_Failure;
            Target.Reason_Value := US.To_Unbounded_String
              ("cannot make worker capture endpoint nonblocking, errno="
               & Ada.Strings.Fixed.Trim
                 (GNAT.OS_Lib.Errno'Image, Ada.Strings.Both));
            return;
         end if;
      end loop;
      Startup_Deadline := Spawn_Start
        + Ada.Real_Time.To_Time_Span (Duration (Launch.Startup_Timeout));
      Total_Deadline := Spawn_Start
        + Ada.Real_Time.To_Time_Span (Duration (Launch.Total_Timeout));

      loop
         Drain
           (Process.Descriptors (0), Result_Data, Maximum_Protocol_Bytes,
            Result_Omitted, Result_EOF, IO_Failed);
         Drain
           (Process.Descriptors (1), Output_Data, Launch.Diagnostic_Capacity,
            Output_Omitted, Output_EOF, IO_Failed);
         Drain
           (Process.Descriptors (2), Error_Data, Launch.Diagnostic_Capacity,
            Error_Omitted, Error_EOF, IO_Failed);

         if not Ready and then not Protocol_Failed then
            begin
               Validate_Ready
                 (US.To_String (Result_Data), Identity_Value, Expected_Kind,
                  Rep, Seed_Value, Environment_Hash, Config_Hash,
                  Environment_Policy_Value, Ready);
               if Ready then
                  Ready_Time := Ada.Real_Time.Clock;
                  Target.Setup_Time :=
                    Elapsed_Nanoseconds (Spawn_End, Ready_Time);
                  if Ready_Time >= Startup_Deadline then
                     Timed_Out := True;
                     Startup_Expired := True;
                  end if;
               end if;
            exception
               when Error : Protocol_Error =>
                  Protocol_Failed := True;
                  Protocol_Reason := US.To_Unbounded_String
                    (Ada.Exceptions.Exception_Message (Error));
            end;
         end if;

         declare
            Observation : constant C.int := C_Observe_Exit (Process.Pid);
         begin
            if Observation = 1 then
               Exit_Observed := True;
            elsif Observation < 0
              and then C.int (GNAT.OS_Lib.Errno) /= Interrupted_Error
            then
               IO_Failed := True;
            end if;
         end;

         Now := Ada.Real_Time.Clock;
         if not Term_Sent then
            if Protocol_Failed or else IO_Failed then
               if not Exit_Observed then
                  Ignored := C_Kill (-Process.Pid, C_Signal_Kill);
                  Hard_Sent := True;
                  Term_Sent := True;
                  Grace_Deadline := Now;
               end if;
            elsif Startup_Expired
              or else (not Ready and then Now >= Startup_Deadline)
            then
               Timed_Out := True;
               Startup_Expired := True;
               if not Exit_Observed then
                  Ignored := C_Kill (-Process.Pid, C_Signal_Terminate);
                  Term_Sent := True;
                  Grace_Deadline := Now
                    + Ada.Real_Time.To_Time_Span
                      (Duration (Launch.Termination_Grace));
               end if;
            elsif Now >= Total_Deadline then
               Timed_Out := True;
               if not Exit_Observed then
                  Ignored := C_Kill (-Process.Pid, C_Signal_Terminate);
                  Term_Sent := True;
                  Grace_Deadline := Now
                    + Ada.Real_Time.To_Time_Span
                      (Duration (Launch.Termination_Grace));
               end if;
            end if;
         elsif not Exit_Observed and then Term_Sent
           and then not Hard_Sent and then Now >= Grace_Deadline
         then
            Ignored := C_Kill (-Process.Pid, C_Signal_Kill);
            Hard_Sent := True;
         end if;

         exit when Exit_Observed;
         delay 0.002;
      end loop;

      --  The unreaped root still anchors the process-group identity here, so
      --  this cannot target a reused PID.  Remove descendants before reaping.
      Ignored := C_Kill (-Process.Pid, C_Signal_Kill);
      if Ignored /= 0
        and then C.int (GNAT.OS_Lib.Errno) /= No_Process_Error
        and then C.int (GNAT.OS_Lib.Errno) /= Permission_Error
      then
         IO_Failed := True;
      end if;
      Reap (Process, Raw_Status);

      declare
         Drain_Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (0.100);
      begin
         loop
            Drain
              (Process.Descriptors (0), Result_Data, Maximum_Protocol_Bytes,
               Result_Omitted, Result_EOF, IO_Failed);
            Drain
              (Process.Descriptors (1), Output_Data, Launch.Diagnostic_Capacity,
               Output_Omitted, Output_EOF, IO_Failed);
            Drain
              (Process.Descriptors (2), Error_Data, Launch.Diagnostic_Capacity,
               Error_Omitted, Error_EOF, IO_Failed);
            exit when (Result_EOF and Output_EOF and Error_EOF)
              or else Ada.Real_Time.Clock >= Drain_Deadline;
            delay 0.001;
         end loop;
      end;
      for Descriptor of Process.Descriptors loop
         Close_Descriptor (Descriptor);
      end loop;

      Target.Output_Value := Output_Data;
      Target.Error_Value := Error_Data;
      Target.Output_Omitted := Output_Omitted;
      Target.Error_Omitted := Error_Omitted;
      Target.Forced_Value := Hard_Sent and then Timed_Out;

      if Timed_Out then
         Target.Outcome_Value :=
           (if Startup_Expired then Startup_Timeout else Execution_Timeout);
         Target.Reason_Value := US.To_Unbounded_String
           ((if Startup_Expired then "worker startup timed out"
             else "worker execution timed out"));
      elsif IO_Failed then
         Target.Outcome_Value := Parent_IO_Failure;
         Target.Reason_Value := US.To_Unbounded_String
           ("parent worker I/O or process observation failed, errno="
            & Ada.Strings.Fixed.Trim
              (GNAT.OS_Lib.Errno'Image, Ada.Strings.Both));
      elsif Protocol_Failed or else Result_Omitted > 0 then
         Target.Outcome_Value := Malformed_Protocol;
         Target.Reason_Value :=
           (if Protocol_Failed then Protocol_Reason
            else US.To_Unbounded_String ("worker result envelope is oversized"));
      elsif C_Status_Signaled (Raw_Status) /= 0 then
         Target.Outcome_Value := Crashed_By_Signal;
         Target.Signal_Value := Natural (C_Status_Signal (Raw_Status));
         Target.Reason_Value := US.To_Unbounded_String
           ("worker terminated by signal");
      elsif C_Status_Exited (Raw_Status) = 0 then
         Target.Outcome_Value := Parent_IO_Failure;
         Target.Reason_Value := US.To_Unbounded_String
           ("worker returned an unrecognized wait status");
      elsif C_Status_Exit_Code (Raw_Status) /= 0 then
         Target.Outcome_Value := Nonzero_Exit;
         Target.Exit_Code_Value := Natural (C_Status_Exit_Code (Raw_Status));
         Target.Reason_Value := US.To_Unbounded_String
           ("worker exited with a nonzero status");
      else
         begin
            Decode_Result_Stream
              (US.To_String (Result_Data), Identity_Value, Expected_Kind,
               Rep, Seed_Value, Environment_Hash, Config_Hash,
               Environment_Policy_Value, Target);
         exception
            when Error : Protocol_Error =>
               Target.Outcome_Value := Malformed_Protocol;
               Target.Reason_Value := US.To_Unbounded_String
                 (Ada.Exceptions.Exception_Message (Error));
         end;
      end if;
   exception
      when Error : others =>
         Target.Outcome_Value := Parent_IO_Failure;
         Target.Reason_Value := US.To_Unbounded_String
           (Ada.Exceptions.Exception_Name (Error) & ": "
            & Ada.Exceptions.Exception_Message (Error));
   end Run_Repetition;

   procedure Run
     (Executable : String;
      Identity   : String;
      Kind       : Result_Kind;
      Config     : Configuration;
      Launch     : Launch_Configuration;
      Env        : Environment;
      Results    : out Worker_Result_Array)
   is
      Full_Executable : US.Unbounded_String;
      Full_Directory : US.Unbounded_String;
      Has_Directory : constant Boolean := Launch.Directory = Use_Directory;
      Entries : Environment_Vectors.Vector;
      Env_Hash : U64;
   begin
      if Results'Length /= Launch.Repetitions then
         raise Configuration_Error with
           "worker result array length differs from repetition count";
      end if;
      if Executable'Length = 0 or else Contains_NUL (Executable)
        or else Ada.Strings.Fixed.Index (Executable, "/") = 0
      then
         raise Configuration_Error with
           "worker executable must be a direct path";
      end if;
      if Identity'Length = 0
        or else Identity'Length > Maximum_Identity_Length
        or else Contains_NUL (Identity)
      then
         raise Configuration_Error with "invalid worker benchmark identity";
      end if;
      if Config.Host_Lock.Enabled
        and then US.Length (Config.Host_Lock.Path)
          > Maximum_Host_Lock_Path_Length
      then
         raise Configuration_Error with
           "worker host-lock path exceeds the protocol limit";
      end if;
      if US.Length (Config.Progress_Name) > Maximum_Progress_Name_Length then
         raise Configuration_Error with
           "worker progress name exceeds the protocol limit";
      end if;
      begin
         if Encode_Configuration (Config)'Length
           > Maximum_Configuration_Bytes
         then
            raise Configuration_Error with
              "worker configuration exceeds the protocol limit";
         end if;
      exception
         when Protocol_Error | Constraint_Error =>
            raise Configuration_Error with
              "worker configuration cannot be encoded";
      end;
      begin
         Full_Executable := US.To_Unbounded_String
           (Ada.Directories.Full_Name (Executable));
         if not Ada.Directories.Exists (US.To_String (Full_Executable))
           or else Ada.Directories.Kind (US.To_String (Full_Executable))
             /= Ada.Directories.Ordinary_File
         then
            raise Configuration_Error with
              "worker executable is not an ordinary file";
         end if;
      exception
         when Configuration_Error => raise;
         when others =>
            raise Configuration_Error with "worker executable cannot be resolved";
      end;
      if Has_Directory then
         if US.Length (Launch.Working_Directory) = 0
           or else Contains_NUL (US.To_String (Launch.Working_Directory))
         then
            raise Configuration_Error with "invalid worker working directory";
         end if;
         begin
            Full_Directory := US.To_Unbounded_String
              (Ada.Directories.Full_Name
                 (US.To_String (Launch.Working_Directory)));
            if not Ada.Directories.Exists (US.To_String (Full_Directory))
              or else Ada.Directories.Kind (US.To_String (Full_Directory))
                /= Ada.Directories.Directory
            then
               raise Configuration_Error with
                 "worker working directory is not a directory";
            end if;
         exception
            when Configuration_Error => raise;
            when others =>
               raise Configuration_Error with
                 "worker working directory cannot be resolved";
         end;
      elsif US.Length (Launch.Working_Directory) /= 0 then
         raise Configuration_Error with
           "inherited directory policy carries an explicit path";
      end if;

      Entries := Effective_Environment (Env);
      Env_Hash := Fingerprint (Entries);
      for Offset in 0 .. Results'Length - 1 loop
         Run_Repetition
           (US.To_String (Full_Executable), US.To_String (Full_Directory),
            Has_Directory, Identity, Kind, Config, Launch, Entries, Env_Hash,
            Env.Selected_Mode, Offset + 1, Results (Results'First + Offset));
      end loop;
   end Run;

   function Outcome (Result : Worker_Result) return Worker_Outcome is
     (Result.Outcome_Value);
   function Kind (Result : Worker_Result) return Result_Kind is
     (Result.Kind_Value);
   function Identity (Result : Worker_Result) return String is
     (US.To_String (Result.Identity_Value));
   function Repetition (Result : Worker_Result) return Positive is
     (Result.Repetition_Value);
   function Seed (Result : Worker_Result) return Long_Long_Integer is
     (Result.Seed_Value);
   function Process_Id (Result : Worker_Result) return Interfaces.C.int is
     (Result.Pid_Value);
   function Spawn_Nanoseconds (Result : Worker_Result) return Long_Float is
     (Result.Spawn_Time);
   function Setup_Nanoseconds (Result : Worker_Result) return Long_Float is
     (Result.Setup_Time);
   function Environment_Fingerprint (Result : Worker_Result) return String is
     (Hex (Result.Environment_Hash));
   function Environment_Policy (Result : Worker_Result) return Environment_Mode is
     (Result.Policy_Value);
   function Exit_Code (Result : Worker_Result) return Natural is
     (Result.Exit_Code_Value);
   function Terminating_Signal (Result : Worker_Result) return Natural is
     (Result.Signal_Value);
   function Forced_Termination (Result : Worker_Result) return Boolean is
     (Result.Forced_Value);
   function Reason (Result : Worker_Result) return String is
     (US.To_String (Result.Reason_Value));
   function Standard_Output (Result : Worker_Result) return String is
     (US.To_String (Result.Output_Value));
   function Standard_Error (Result : Worker_Result) return String is
     (US.To_String (Result.Error_Value));
   function Standard_Output_Omitted (Result : Worker_Result) return Natural is
     (Result.Output_Omitted);
   function Standard_Error_Omitted (Result : Worker_Result) return Natural is
     (Result.Error_Omitted);

   function Measurement_Value (Result : Worker_Result) return Measurement is
   begin
      if Result.Outcome_Value /= Normal_Result
        or else Result.Kind_Value /= Ordinary_Measurement
      then
         raise Program_Error with "worker result is not an ordinary measurement";
      end if;
      return Result.Measurement_Data;
   end Measurement_Value;

   function Comparison_Value (Result : Worker_Result) return Comparison is
   begin
      if Result.Outcome_Value /= Normal_Result
        or else Result.Kind_Value /= Paired_Comparison
      then
         raise Program_Error with "worker result is not a paired comparison";
      end if;
      return Result.Comparison_Data;
   end Comparison_Value;

end Flyology_Bench.Workers;
