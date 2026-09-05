--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.OS_Lib;
with Interfaces.C;
with Interfaces.C.Strings;
with System;
with Flyology_Bench.Internal_Condition_Test_Hooks;
with Flyology_Bench.Internal_Probes;

package body Flyology_Bench.Internal_Conditions is
   package C renames Interfaces.C;
   package CS renames Interfaces.C.Strings;
   package US renames Ada.Strings.Unbounded;

   use type C.int;
   use type C.char;
   use type C.long;
   use type C.size_t;
   use type C.unsigned;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_64;
   use type Internal_Probes.Host_System;
   use type System.Address;

   Maximum_Command_Output : constant := 32 * 1_024;
   Event_Available_Flag   : constant Interfaces.Unsigned_8 := 1;
   Time_Available_Flag    : constant Interfaces.Unsigned_8 := 2;
   subtype Command_Output_Index is C.size_t range 0 .. Maximum_Command_Output - 1;
   type Command_Output is array (Command_Output_Index) of aliased C.char with Convention => C;
   type Discard_Output is array (C.size_t range 0 .. 511) of aliased C.char with Convention => C;
   type Chars_Ptr_Array is array (C.size_t range <>) of CS.chars_ptr with Convention => C;
   subtype Condition_Text_Index is C.size_t range 0 .. 127;
   type Condition_Text is array (Condition_Text_Index) of aliased C.char with Convention => C;

   Capture_EINTR       : C.int
   with Import, Convention => C, External_Name => "flyology_bench_capture_eintr";
   Capture_EAGAIN      : C.int
   with Import, Convention => C, External_Name => "flyology_bench_capture_eagain";
   Capture_EWOULDBLOCK : C.int
   with Import, Convention => C, External_Name => "flyology_bench_capture_ewouldblock";
   Capture_WNOHANG     : C.int
   with Import, Convention => C, External_Name => "flyology_bench_capture_wnohang";
   Capture_SIGKILL     : C.int
   with Import, Convention => C, External_Name => "flyology_bench_capture_sigkill";

   function C_Capture_Start
     (Path : CS.chars_ptr; Arguments : System.Address; Descriptor : access C.int; Child_PID : access C.int)
      return C.int
   with Import, Convention => C, External_Name => "flyology_bench_capture_start";

   function C_Capture_Poll (Descriptor : C.int; Timeout_MS : C.int; Ready : access C.int) return C.int
   with Import, Convention => C, External_Name => "flyology_bench_capture_poll";

   function C_Read (Descriptor : C.int; Output : System.Address; Capacity : C.size_t) return C.long
   with Import, Convention => C, External_Name => "read";

   function C_Waitpid (Child_PID : C.int; Wait_Status : access C.int; Options : C.int) return C.int
   with Import, Convention => C, External_Name => "waitpid";

   function C_Kill (PID : C.int; Signal : C.int) return C.int
   with Import, Convention => C, External_Name => "kill";

   function C_Close (Descriptor : C.int) return C.int
   with Import, Convention => C, External_Name => "close";

   function C_Capture_Exit_Status (Wait_Status : C.int) return C.int
   with Import, Convention => C, External_Name => "flyology_bench_capture_exit_status";

   function C_Darwin_Process_Conditions
     (Thermal_Available   : access C.int;
      Thermal_State       : access C.int;
      Low_Power_Available : access C.int;
      Low_Power           : access C.int;
      Profile_Available   : access C.int;
      Default_Profile     : access C.int;
      Sustained_Profile   : access C.int) return C.int
   with Import, Convention => C, External_Name => "flyology_bench_darwin_process_conditions";

   function C_Linux_PPD_Open (Bus : access System.Address) return C.int
   with Import, Convention => C, External_Name => "flyology_bench_linux_ppd_open";

   function C_Linux_PPD_Set_Timeout (Bus : System.Address; Timeout_US : Interfaces.Unsigned_64) return C.int
   with Import, Convention => C, External_Name => "flyology_bench_linux_ppd_set_timeout";

   function C_Linux_PPD_Get_Name_Credentials
     (Bus : System.Address; Destination : CS.chars_ptr; Credentials : access System.Address) return C.int
   with Import, Convention => C, External_Name => "flyology_bench_linux_ppd_get_name_credentials";

   function C_Linux_PPD_Copy_Unique_Name
     (Credentials : System.Address; Target : System.Address; Capacity : C.size_t) return C.int
   with Import, Convention => C, External_Name => "flyology_bench_linux_ppd_copy_unique_name";

   function C_Linux_PPD_Get_Property
     (Bus            : System.Address;
      Destination    : CS.chars_ptr;
      Path           : CS.chars_ptr;
      Interface_Name : CS.chars_ptr;
      Property       : CS.chars_ptr;
      Target         : System.Address;
      Capacity       : C.size_t) return C.int
   with Import, Convention => C, External_Name => "flyology_bench_linux_ppd_get_property";

   procedure C_Linux_PPD_Credentials_Unref (Credentials : System.Address)
   with Import, Convention => C, External_Name => "flyology_bench_linux_ppd_credentials_unref";

   procedure C_Linux_PPD_Bus_Unref (Bus : System.Address)
   with Import, Convention => C, External_Name => "flyology_bench_linux_ppd_bus_unref";

   type Argument_List is array (Positive range <>) of US.Unbounded_String;

   function Capture
     (Command : String; Arguments : Argument_List; Timeout_MS : C.unsigned; Success : out Boolean)
      return US.Unbounded_String
   is
      Native_Arguments : Chars_Ptr_Array (0 .. C.size_t (Arguments'Length + 1)) := (others => CS.Null_Ptr);
      Path             : CS.chars_ptr := CS.Null_Ptr;
      Output           : aliased Command_Output := (others => C.nul);
      Discard          : aliased Discard_Output := (others => C.nul);
      Used             : C.size_t := 0;
      Count            : aliased C.long := 0;
      Descriptor       : aliased C.int := -1;
      Child_PID        : aliased C.int := -1;
      Wait_Status      : aliased C.int := 0;
      Result_PID       : aliased C.int := 0;
      Ready            : aliased C.int := 0;
      Exit_Status      : aliased C.int := -1;
      Error            : C.int;
      Pipe_EOF         : Boolean := False;
      Child_Exited     : Boolean := False;
      Failed           : Boolean := False;
      Overflowed       : Boolean := False;
      Started          : Interfaces.Unsigned_64;
      Deadline         : Interfaces.Unsigned_64;

      procedure Release_Arguments is
      begin
         CS.Free (Path);
         for Item of Native_Arguments loop
            CS.Free (Item);
         end loop;
      end Release_Arguments;

      procedure Cleanup_Process is
         Ignored : C.int;
      begin
         if Descriptor >= 0 then
            Ignored := C_Close (Descriptor);
            Descriptor := -1;
         end if;
         if Child_PID > 0 then
            if Failed or else Overflowed then
               Ignored := C_Kill (-Child_PID, Capture_SIGKILL);
            end if;
            if not Child_Exited then
               loop
                  Result_PID := C_Waitpid (Child_PID, Wait_Status'Access, 0);
                  Error := (if Result_PID < 0 then C.int (GNAT.OS_Lib.Errno) else 0);
                  exit when Error /= Capture_EINTR;
               end loop;
            end if;
         end if;
         Child_PID := -1;
      end Cleanup_Process;
   begin
      if Timeout_MS = 0 then
         Success := False;
         return US.Null_Unbounded_String;
      end if;
      Path := CS.New_String (Command);
      Native_Arguments (0) := CS.New_String (Command);
      for Index in Arguments'Range loop
         Native_Arguments (C.size_t (Index - Arguments'First + 1)) :=
           CS.New_String (US.To_String (Arguments (Index)));
      end loop;
      Error := C_Capture_Start (Path, Native_Arguments'Address, Descriptor'Access, Child_PID'Access);
      if Error /= 0 then
         Release_Arguments;
         Success := False;
         return US.Null_Unbounded_String;
      end if;
      Started := Internal_Probes.Clock_Now;
      Deadline := Started + Interfaces.Unsigned_64 (Timeout_MS) * 1_000_000;
      while not Pipe_EOF or else not Child_Exited loop
         if not Pipe_EOF then
            if Used < C.size_t (Maximum_Command_Output) then
               Count :=
                 C_Read
                   (Descriptor,
                    Output (Command_Output_Index (Used))'Address,
                    C.size_t (Maximum_Command_Output) - Used);
            else
               Count := C_Read (Descriptor, Discard'Address, Discard'Length);
            end if;
            Error := (if Count < 0 then C.int (GNAT.OS_Lib.Errno) else 0);
            if Error = 0 then
               if Count = 0 then
                  Pipe_EOF := True;
               elsif Count > 0 then
                  if Used < C.size_t (Maximum_Command_Output) then
                     Used := Used + C.size_t (Count);
                  else
                     Overflowed := True;
                  end if;
               end if;
            elsif Error /= Capture_EINTR
              and then Error /= Capture_EAGAIN
              and then Error /= Capture_EWOULDBLOCK
            then
               Failed := True;
               exit;
            end if;
         end if;
         if not Child_Exited then
            Result_PID := C_Waitpid (Child_PID, Wait_Status'Access, Capture_WNOHANG);
            Error := (if Result_PID < 0 then C.int (GNAT.OS_Lib.Errno) else 0);
            if Error = 0 and then Result_PID = Child_PID then
               Child_Exited := True;
            elsif Error /= 0 and then Error /= Capture_EINTR then
               Failed := True;
               exit;
            end if;
         end if;
         if not Pipe_EOF or else not Child_Exited then
            declare
               Now          : constant Interfaces.Unsigned_64 := Internal_Probes.Clock_Now;
               Remaining_NS : Interfaces.Unsigned_64;
               Milliseconds : Interfaces.Unsigned_64;
               Poll_MS      : C.int;
            begin
               if Now >= Deadline then
                  Failed := True;
                  exit;
               end if;
               Remaining_NS := Deadline - Now;
               Milliseconds := Remaining_NS / 1_000_000 + (if Remaining_NS mod 1_000_000 = 0 then 0 else 1);
               Poll_MS := C.int (Interfaces.Unsigned_64'Min (50, Milliseconds));
               if Pipe_EOF then
                  delay Duration (Poll_MS) / 1_000.0;
               else
                  Error := C_Capture_Poll (Descriptor, 0, Ready'Access);
                  if Error /= 0 and then Error /= Capture_EINTR then
                     Failed := True;
                     exit;
                  elsif Ready = 0 then
                     delay Duration (Poll_MS) / 1_000.0;
                  end if;
               end if;
            end;
         end if;
      end loop;
      if Child_Exited then
         Exit_Status := C_Capture_Exit_Status (Wait_Status);
      end if;
      Success := not Failed and then not Overflowed and then Exit_Status = 0;
      declare
         Result : US.Unbounded_String;
      begin
         if Success and then Used > 0 then
            for Index in 0 .. Used - 1 loop
               US.Append (Result, Character'Val (C.char'Pos (Output (Index))));
            end loop;
         end if;
         Cleanup_Process;
         Release_Arguments;
         return Result;
      end;
   exception
      when others =>
         Cleanup_Process;
         Release_Arguments;
         Success := False;
         return US.Null_Unbounded_String;
   end Capture;

   function Remaining_Timeout (Deadline : Interfaces.Unsigned_64) return C.unsigned is
      Now          : Interfaces.Unsigned_64;
      Remaining    : Interfaces.Unsigned_64;
      Milliseconds : Interfaces.Unsigned_64;
   begin
      if Deadline = Interfaces.Unsigned_64'Last then
         return 2_000;
      end if;
      Now := Internal_Probes.Clock_Now;
      if Now >= Deadline then
         return 0;
      end if;
      Remaining := Deadline - Now;
      Milliseconds := Remaining / 1_000_000 + (if Remaining mod 1_000_000 = 0 then 0 else 1);
      return (if Milliseconds >= 2_000 then 2_000 else C.unsigned (Milliseconds));
   end Remaining_Timeout;

   function Lower (Value : String) return String
   is (Ada.Characters.Handling.To_Lower (Value));

   function Trim (Value : String) return String
   is (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

   function Text_Value (Value : Condition_Text) return String is
      Result : US.Unbounded_String;
   begin
      for Item of Value loop
         exit when Item = C.nul;
         US.Append (Result, Character'Val (C.char'Pos (Item)));
      end loop;
      return US.To_String (Result);
   end Text_Value;

   function First_Line (Path : String; Success : out Boolean) return String is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      declare
         Value : constant String := Ada.Text_IO.Get_Line (File);
      begin
         Ada.Text_IO.Close (File);
         Success := True;
         return Trim (Value);
      end;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         Success := False;
         return "";
   end First_Line;

   function Parse_Profile (Value : String) return Performance_Profile is
      Normalized : constant String := Lower (Trim (Value));
   begin
      if Normalized = "power-saver"
        or else Normalized = "low-power"
        or else Normalized = "cool"
        or else Normalized = "quiet"
      then
         return Profile_Reduced;
      elsif Normalized = "balanced" or else Normalized = "balanced-performance" then
         return Profile_Balanced;
      elsif Normalized = "performance" or else Normalized = "high-performance" then
         return Profile_Performance;
      else
         return Profile_Unknown;
      end if;
   end Parse_Profile;

   procedure Read_Darwin_Profile (Value : in out Snapshot; Deadline : Interfaces.Unsigned_64) is
      Batt_OK        : Boolean;
      Custom_OK      : Boolean;
      Batt_After_OK  : Boolean;
      Batt           : constant String :=
        US.To_String
          (Capture
             ("/usr/bin/pmset",
              [1 => US.To_Unbounded_String ("-g"), 2 => US.To_Unbounded_String ("batt")],
              Remaining_Timeout (Deadline),
              Batt_OK));
      Custom         : constant String :=
        US.To_String
          (Capture
             ("/usr/bin/pmset",
              [1 => US.To_Unbounded_String ("-g"), 2 => US.To_Unbounded_String ("custom")],
              Remaining_Timeout (Deadline),
              Custom_OK));
      Batt_After     : constant String :=
        US.To_String
          (Capture
             ("/usr/bin/pmset",
              [1 => US.To_Unbounded_String ("-g"), 2 => US.To_Unbounded_String ("batt")],
              Remaining_Timeout (Deadline),
              Batt_After_OK));
      Active_AC      : constant Boolean :=
        Ada.Strings.Fixed.Index (Lower (Batt), "now drawing from 'ac power'") > 0;
      Active_Battery : constant Boolean :=
        Ada.Strings.Fixed.Index (Lower (Batt), "now drawing from 'battery power'") > 0;
      Active_UPS     : constant Boolean :=
        Ada.Strings.Fixed.Index (Lower (Batt), "now drawing from 'ups power'") > 0;
      After_AC       : constant Boolean :=
        Ada.Strings.Fixed.Index (Lower (Batt_After), "now drawing from 'ac power'") > 0;
      After_Battery  : constant Boolean :=
        Ada.Strings.Fixed.Index (Lower (Batt_After), "now drawing from 'battery power'") > 0;
      After_UPS      : constant Boolean :=
        Ada.Strings.Fixed.Index (Lower (Batt_After), "now drawing from 'ups power'") > 0;
      In_Section     : Boolean := False;
      Cursor         : Positive := Custom'First;
      Low_Seen       : Boolean := False;
      Low_Set        : Boolean := False;
      High_Seen      : Boolean := False;
      High_Set       : Boolean := False;
   begin
      if not Batt_OK
        or else not Custom_OK
        or else not Batt_After_OK
        or else (if Active_AC then 1 else 0)
                + (if Active_Battery then 1 else 0)
                + (if Active_UPS then 1 else 0)
                /= 1
        or else (if After_AC then 1 else 0) + (if After_Battery then 1 else 0) + (if After_UPS then 1 else 0)
                /= 1
        or else Active_AC /= After_AC
        or else Active_Battery /= After_Battery
        or else Active_UPS /= After_UPS
      then
         return;
      end if;
      Value.Power_Source := (if Active_Battery then Battery_Power else External_Power);
      while Cursor <= Custom'Last loop
         declare
            Last : Natural := Ada.Strings.Fixed.Index (Custom, String'(1 => ASCII.LF), Cursor);
         begin
            if Last = 0 then
               Last := Custom'Last + 1;
            end if;
            declare
               Line       : constant String := Trim (Custom (Cursor .. Last - 1));
               Normalized : constant String := Lower (Line);
            begin
               if Ada.Strings.Fixed.Index (Normalized, "power:") > 0 then
                  In_Section :=
                    (Active_AC and then Ada.Strings.Fixed.Index (Normalized, "ac power:") > 0)
                    or else (Active_Battery
                             and then Ada.Strings.Fixed.Index (Normalized, "battery power:") > 0)
                    or else (Active_UPS and then Ada.Strings.Fixed.Index (Normalized, "ups power:") > 0);
               elsif In_Section and then Ada.Strings.Fixed.Index (Normalized, "powermode") = 1 then
                  declare
                     Setting : constant String := Trim (Normalized (10 .. Normalized'Last));
                  begin
                     if Setting = "0" then
                        Value.Profile := Profile_Balanced;
                     elsif Setting = "1" then
                        Value.Profile := Profile_Reduced;
                     elsif Setting = "2" then
                        Value.Profile := Profile_Performance;
                     else
                        return;
                     end if;
                     Value.Profile_Availability := Condition_Available;
                     Value.Profile_Detector := Darwin_PMSet;
                     return;
                  end;
               elsif In_Section and then Ada.Strings.Fixed.Index (Normalized, "lowpowermode") = 1 then
                  declare
                     Setting : constant String :=
                       (if Normalized'Length >= 13 then Trim (Normalized (13 .. Normalized'Last)) else "");
                  begin
                     if Setting /= "0" and then Setting /= "1" then
                        return;
                     end if;
                     Low_Seen := True;
                     Low_Set := Setting = "1";
                  end;
               elsif In_Section and then Ada.Strings.Fixed.Index (Normalized, "highpowermode") = 1 then
                  declare
                     Setting : constant String :=
                       (if Normalized'Length >= 14 then Trim (Normalized (14 .. Normalized'Last)) else "");
                  begin
                     if Setting /= "0" and then Setting /= "1" then
                        return;
                     end if;
                     High_Seen := True;
                     High_Set := Setting = "1";
                  end;
               end if;
            end;
            exit when Last > Custom'Last;
            Cursor := Last + 1;
         end;
      end loop;
      if Low_Seen or else High_Seen then
         if Low_Set and High_Set then
            return;
         elsif Low_Set then
            Value.Profile := Profile_Reduced;
         elsif High_Set then
            Value.Profile := Profile_Performance;
         else
            Value.Profile := Profile_Balanced;
         end if;
         Value.Profile_Availability := Condition_Available;
         Value.Profile_Detector := Darwin_PMSet;
      end if;
   end Read_Darwin_Profile;

   procedure Read_Darwin_Live (Value : in out Snapshot) is
      Thermal_Available   : aliased C.int := 0;
      Thermal_State       : aliased C.int := 0;
      Low_Power_Available : aliased C.int := 0;
      Low_Power           : aliased C.int := 0;
      Profile_Available   : aliased C.int := 0;
      Default_Profile     : aliased C.int := 0;
      Sustained_Profile   : aliased C.int := 0;
      Status              : C.int;
   begin
      Status :=
        C_Darwin_Process_Conditions
          (Thermal_Available'Access,
           Thermal_State'Access,
           Low_Power_Available'Access,
           Low_Power'Access,
           Profile_Available'Access,
           Default_Profile'Access,
           Sustained_Profile'Access);
      if Status /= 0 then
         return;
      end if;
      if Thermal_Available /= 0 and then Thermal_State in 0 .. 3 then
         Value.Thermal_Availability := Condition_Available;
         Value.Thermal_Detector := Darwin_Process_Info;
         Value.Thermal_State :=
           Host_Thermal_State'Val (Host_Thermal_State'Pos (Thermal_State_Nominal) + Integer (Thermal_State));
      end if;
      if Low_Power_Available /= 0 and then Low_Power in 0 .. 1 then
         Value.Low_Power_Availability := Condition_Available;
         Value.Low_Power_Detector := Darwin_Process_Info;
         Value.Low_Power_Mode := (if Low_Power = 0 then Low_Power_Mode_Disabled else Low_Power_Mode_Enabled);
      end if;
      if Profile_Available /= 0 and then Default_Profile + Sustained_Profile = 1 then
         Value.Process_Profile_Avail := Condition_Available;
         Value.Process_Profile_Detector := Darwin_Process_Info;
         Value.Process_Profile :=
           (if Default_Profile /= 0 then Process_Profile_Default else Process_Profile_Sustained);
      end if;
   end Read_Darwin_Live;

   function Read_U64 (Path : String; Success : out Boolean) return Interfaces.Unsigned_64 is
      Line : constant String := First_Line (Path, Success);
   begin
      if not Success then
         return 0;
      end if;
      return Interfaces.Unsigned_64'Value (Line);
   exception
      when others =>
         Success := False;
         return 0;
   end Read_U64;

   procedure Observe_Throttle_Source
     (Continuity          : in out Throttle_Continuity;
      Position            : Throttle_Source_Index;
      Key                 : Interfaces.Unsigned_16;
      Event_Available     : Boolean;
      Event_Total         : Interfaces.Unsigned_64;
      Time_Available      : Boolean;
      Time_Total_MS       : Interfaces.Unsigned_64;
      Event_Discontinuous : in out Boolean;
      Time_Discontinuous  : in out Boolean)
   is
      Flags : constant Interfaces.Unsigned_8 :=
        (if Event_Available then Event_Available_Flag else 0)
        + (if Time_Available then Time_Available_Flag else 0);
   begin
      if Continuity.Initialized then
         if Position > Continuity.Count or else Continuity.Keys (Position) /= Key then
            Event_Discontinuous := True;
            Time_Discontinuous := True;
         else
            if (Continuity.Flags (Position) and Event_Available_Flag) /= (Flags and Event_Available_Flag)
              or else (Event_Available and then Event_Total < Continuity.Events (Position))
            then
               Event_Discontinuous := True;
            end if;
            if (Continuity.Flags (Position) and Time_Available_Flag) /= (Flags and Time_Available_Flag)
              or else (Time_Available and then Time_Total_MS < Continuity.Times_MS (Position))
            then
               Time_Discontinuous := True;
            end if;
         end if;
      end if;
      Continuity.Keys (Position) := Key;
      Continuity.Flags (Position) := Flags;
      Continuity.Events (Position) := Event_Total;
      Continuity.Times_MS (Position) := Time_Total_MS;
   end Observe_Throttle_Source;

   procedure Complete_Throttle_Observation
     (Continuity          : in out Throttle_Continuity;
      Count               : Natural;
      Event_Discontinuous : in out Boolean;
      Time_Discontinuous  : in out Boolean) is
   begin
      if Continuity.Initialized and then Count /= Continuity.Count then
         Event_Discontinuous := True;
         Time_Discontinuous := True;
      end if;
      Continuity.Count := Count;
      Continuity.Initialized := True;
   end Complete_Throttle_Observation;

   function Linux_Sysfs_Path (Suffix : String) return String is
   begin
      if Internal_Condition_Test_Hooks.Enabled then
         if Internal_Condition_Test_Hooks.Linux_Fixture_Enabled then
            return Internal_Condition_Test_Hooks.Linux_Sysfs_Root & Suffix;
         end if;
      end if;
      return "/sys" & Suffix;
   end Linux_Sysfs_Path;

   procedure Read_Linux_Throttle (Value : in out Snapshot; Continuity : in out Throttle_Continuity) is
      Present_OK     : Boolean;
      Present        : constant String :=
        First_Line (Linux_Sysfs_Path ("/devices/system/cpu/online"), Present_OK);
      Cursor         : Positive := (if Present'Length = 0 then 1 else Present'First);
      Any            : Boolean := False;
      Any_Time       : Boolean := False;
      Total          : Interfaces.Unsigned_64 := 0;
      Total_Time     : Interfaces.Unsigned_64 := 0;
      Event_Overflow : Boolean := False;
      Time_Overflow  : Boolean := False;
      Current_Count  : Natural range 0 .. Maximum_Throttle_Sources := 0;

      type Core_Key is record
         Package_Id : Interfaces.Unsigned_64;
         Core_Id    : Interfaces.Unsigned_64;
      end record;
      type Core_Key_Array is array (Positive range <>) of Core_Key;
      type Package_Key_Array is array (Positive range <>) of Interfaces.Unsigned_64;
      Core_Keys     : Core_Key_Array (1 .. Internal_Probes.Maximum_Host_CPUs);
      Package_Keys  : Package_Key_Array (1 .. Internal_Probes.Maximum_Host_CPUs);
      Core_Count    : Natural := 0;
      Package_Count : Natural := 0;

      function Core_Seen (Package_Id, Core_Id : Interfaces.Unsigned_64) return Boolean is
      begin
         for Index in 1 .. Core_Count loop
            if Core_Keys (Index) = (Package_Id => Package_Id, Core_Id => Core_Id) then
               return True;
            end if;
         end loop;
         return False;
      end Core_Seen;

      function Package_Seen (Package_Id : Interfaces.Unsigned_64) return Boolean is
      begin
         for Index in 1 .. Package_Count loop
            if Package_Keys (Index) = Package_Id then
               return True;
            end if;
         end loop;
         return False;
      end Package_Seen;

      procedure Register_Source
        (CPU            : Natural;
         Package_Source : Boolean;
         Event_OK       : Boolean;
         Event_Total    : Interfaces.Unsigned_64;
         Time_OK        : Boolean;
         Time_Total_MS  : Interfaces.Unsigned_64)
      is
         Key   : constant Interfaces.Unsigned_16 :=
           Interfaces.Unsigned_16 (CPU + (if Package_Source then Internal_Probes.Maximum_Host_CPUs else 0));
         Index : Throttle_Source_Index;
      begin
         if not Event_OK and then not Time_OK then
            return;
         end if;
         Current_Count := Current_Count + 1;
         Index := Current_Count;
         Observe_Throttle_Source
           (Continuity,
            Index,
            Key,
            Event_OK,
            Event_Total,
            Time_OK,
            Time_Total_MS,
            Value.Throttle_Discontinuous,
            Value.Throttle_Time_Discontinuous);
         if Event_OK then
            if Total > Interfaces.Unsigned_64'Last - Event_Total then
               Event_Overflow := True;
            else
               Total := Total + Event_Total;
               Any := True;
            end if;
         end if;
         if Time_OK then
            if Total_Time > Interfaces.Unsigned_64'Last - Time_Total_MS then
               Time_Overflow := True;
            else
               Total_Time := Total_Time + Time_Total_MS;
               Any_Time := True;
            end if;
         end if;
      end Register_Source;

      procedure Add_CPU (CPU : Natural) is
         Core_OK         : Boolean;
         Core_Time_OK    : Boolean;
         Package_OK      : Boolean;
         Package_Time_OK : Boolean;
         Package_Id_OK   : Boolean;
         Core_Id_OK      : Boolean;
         Prefix          : constant String :=
           Linux_Sysfs_Path ("/devices/system/cpu/cpu" & Trim (Natural'Image (CPU)) & "/thermal_throttle/");
         Topology_Prefix : constant String :=
           Linux_Sysfs_Path ("/devices/system/cpu/cpu" & Trim (Natural'Image (CPU)) & "/topology/");
         Package_Id      : constant Interfaces.Unsigned_64 :=
           Read_U64 (Topology_Prefix & "physical_package_id", Package_Id_OK);
         Core_Id         : constant Interfaces.Unsigned_64 :=
           Read_U64 (Topology_Prefix & "core_id", Core_Id_OK);
      begin
         if Package_Id_OK and then Core_Id_OK then
            if not Core_Seen (Package_Id, Core_Id) then
               declare
                  Core      : constant Interfaces.Unsigned_64 :=
                    Read_U64 (Prefix & "core_throttle_count", Core_OK);
                  Core_Time : constant Interfaces.Unsigned_64 :=
                    Read_U64 (Prefix & "core_throttle_total_time_ms", Core_Time_OK);
               begin
                  if Core_OK or else Core_Time_OK then
                     Core_Count := Core_Count + 1;
                     Core_Keys (Core_Count) := (Package_Id => Package_Id, Core_Id => Core_Id);
                  end if;
                  Register_Source (CPU, False, Core_OK, Core, Core_Time_OK, Core_Time);
               end;
            end if;
            if not Package_Seen (Package_Id) then
               declare
                  Count        : constant Interfaces.Unsigned_64 :=
                    Read_U64 (Prefix & "package_throttle_count", Package_OK);
                  Package_Time : constant Interfaces.Unsigned_64 :=
                    Read_U64 (Prefix & "package_throttle_total_time_ms", Package_Time_OK);
               begin
                  if Package_OK or else Package_Time_OK then
                     Package_Count := Package_Count + 1;
                     Package_Keys (Package_Count) := Package_Id;
                  end if;
                  Register_Source (CPU, True, Package_OK, Count, Package_Time_OK, Package_Time);
               end;
            end if;
         else
            --  Very old kernels may expose counters without topology. Keep a
            --  conservative per-logical-CPU core sum and one package value.
            declare
               Core         : constant Interfaces.Unsigned_64 :=
                 Read_U64 (Prefix & "core_throttle_count", Core_OK);
               Count        : constant Interfaces.Unsigned_64 :=
                 Read_U64 (Prefix & "package_throttle_count", Package_OK);
               Core_Time    : constant Interfaces.Unsigned_64 :=
                 Read_U64 (Prefix & "core_throttle_total_time_ms", Core_Time_OK);
               Package_Time : constant Interfaces.Unsigned_64 :=
                 Read_U64 (Prefix & "package_throttle_total_time_ms", Package_Time_OK);
            begin
               Register_Source (CPU, False, Core_OK, Core, Core_Time_OK, Core_Time);
               if CPU = 0 then
                  Register_Source (CPU, True, Package_OK, Count, Package_Time_OK, Package_Time);
               end if;
            end;
         end if;
      end Add_CPU;

      procedure Mark_Unavailable is
      begin
         if Continuity.Initialized and then Continuity.Count > 0 then
            Value.Throttle_Discontinuous := True;
            Value.Throttle_Time_Discontinuous := True;
         end if;
      end Mark_Unavailable;
   begin
      if not Present_OK then
         Mark_Unavailable;
         return;
      end if;
      while Cursor <= Present'Last loop
         declare
            Separator : constant Natural := Ada.Strings.Fixed.Index (Present, ",", Cursor);
            Last      : constant Natural := (if Separator = 0 then Present'Last else Separator - 1);
            Dash      : constant Natural := Ada.Strings.Fixed.Index (Present (Cursor .. Last), "-");
            First_CPU : Natural;
            Last_CPU  : Natural;
         begin
            if Dash = 0 then
               First_CPU := Natural'Value (Present (Cursor .. Last));
               Last_CPU := First_CPU;
            else
               First_CPU := Natural'Value (Present (Cursor .. Dash - 1));
               Last_CPU := Natural'Value (Present (Dash + 1 .. Last));
            end if;
            if Last_CPU < First_CPU or else Last_CPU >= Internal_Probes.Maximum_Host_CPUs then
               Mark_Unavailable;
               return;
            end if;
            for CPU in First_CPU .. Last_CPU loop
               Add_CPU (CPU);
            end loop;
            exit when Separator = 0;
            Cursor := Separator + 1;
         exception
            when others =>
               Mark_Unavailable;
               return;
         end;
      end loop;
      Complete_Throttle_Observation
        (Continuity, Current_Count, Value.Throttle_Discontinuous, Value.Throttle_Time_Discontinuous);
      if Event_Overflow then
         Value.Throttle_Discontinuous := True;
      end if;
      if Time_Overflow then
         Value.Throttle_Time_Discontinuous := True;
      end if;
      if Any and then not Event_Overflow then
         Value.Throttle_Availability := Condition_Available;
         Value.Throttle_Detector := Linux_CPU_Thermal_Throttle;
         Value.Throttle_Total := Total;
      end if;
      if Any_Time and then not Time_Overflow then
         Value.Throttle_Time_Avail := Condition_Available;
         Value.Throttle_Detector := Linux_CPU_Thermal_Throttle;
         Value.Throttle_Time_Total_MS := Total_Time;
      end if;
   end Read_Linux_Throttle;

   procedure Apply_Linux_PPD
     (Value                 : in out Snapshot;
      Profile_Text          : String;
      Profile_Available     : Boolean;
      Degradation_Text      : String;
      Degradation_Available : Boolean)
   is
      Parsed   : constant Performance_Profile := Parse_Profile (Profile_Text);
      Degraded : constant String := Lower (Trim (Degradation_Text));
   begin
      if Profile_Available and then Parsed /= Profile_Unknown then
         Value.Profile_Availability := Condition_Available;
         Value.Profile_Detector := Linux_Power_Profiles_Daemon;
         Value.Profile := Parsed;
      end if;
      if Degradation_Available then
         Value.Degradation_Availability := Condition_Available;
         if Degraded = "" then
            Value.Degradation := Not_Degraded;
         elsif Degraded = "high-operating-temperature" then
            Value.Degradation := High_Operating_Temperature;
         elsif Degraded = "lap-detected" then
            Value.Degradation := Lap_Detected;
         else
            Value.Degradation := Other_Degradation;
         end if;
      end if;
   end Apply_Linux_PPD;

   procedure Read_Linux_Profile (Value : in out Snapshot; Deadline : Interfaces.Unsigned_64) is
      Profile_Buffer     : aliased Condition_Text := (others => C.nul);
      Degradation_Buffer : aliased Condition_Text := (others => C.nul);
      Owner_Buffer       : aliased Condition_Text := (others => C.nul);
      Bus                : aliased System.Address := System.Null_Address;
      Status             : C.int;
      Sysfs_OK           : Boolean;
      Selected_Path      : US.Unbounded_String;
      Selected_Interface : US.Unbounded_String;
      Query_Live_PPD     : Boolean := True;

      function Refresh_Timeout return Boolean is
         Now        : Interfaces.Unsigned_64;
         Remaining  : Interfaces.Unsigned_64;
         Timeout_US : Interfaces.Unsigned_64;
      begin
         if Deadline = Interfaces.Unsigned_64'Last then
            Timeout_US := 250_000;
         else
            Now := Internal_Probes.Clock_Now;
            if Now >= Deadline then
               return False;
            end if;
            Remaining := Deadline - Now;
            Timeout_US := Remaining / 1_000 + (if Remaining mod 1_000 = 0 then 0 else 1);
            Timeout_US := Interfaces.Unsigned_64'Min (250_000, Timeout_US);
         end if;
         return C_Linux_PPD_Set_Timeout (Bus, Timeout_US) >= 0;
      end Refresh_Timeout;

      function Resolve (Destination : String; Path : String; Interface_Name : String) return Boolean is
         Name        : CS.chars_ptr := CS.New_String (Destination);
         Credentials : aliased System.Address := System.Null_Address;
         Result      : Boolean := False;
      begin
         if not Refresh_Timeout then
            CS.Free (Name);
            return False;
         end if;
         Status := C_Linux_PPD_Get_Name_Credentials (Bus, Name, Credentials'Access);
         if Status >= 0 and then Credentials /= System.Null_Address then
            Status :=
              C_Linux_PPD_Copy_Unique_Name
                (Credentials, Owner_Buffer'Address, C.size_t (Owner_Buffer'Length));
            Result := Status >= 0;
         end if;
         if Credentials /= System.Null_Address then
            C_Linux_PPD_Credentials_Unref (Credentials);
         end if;
         CS.Free (Name);
         if Result then
            Selected_Path := US.To_Unbounded_String (Path);
            Selected_Interface := US.To_Unbounded_String (Interface_Name);
         end if;
         return Result;
      exception
         when others =>
            if Credentials /= System.Null_Address then
               C_Linux_PPD_Credentials_Unref (Credentials);
            end if;
            CS.Free (Name);
            return False;
      end Resolve;

      function Read_Property (Name : String; Buffer : in out Condition_Text) return Boolean is
         Destination    : CS.chars_ptr := CS.New_String (Text_Value (Owner_Buffer));
         Path           : CS.chars_ptr := CS.New_String (US.To_String (Selected_Path));
         Interface_Name : CS.chars_ptr := CS.New_String (US.To_String (Selected_Interface));
         Property       : CS.chars_ptr := CS.New_String (Name);
         Result         : Boolean;
      begin
         if not Refresh_Timeout then
            CS.Free (Destination);
            CS.Free (Path);
            CS.Free (Interface_Name);
            CS.Free (Property);
            return False;
         end if;
         Result :=
           C_Linux_PPD_Get_Property
             (Bus, Destination, Path, Interface_Name, Property, Buffer'Address, C.size_t (Buffer'Length))
           >= 0;
         CS.Free (Destination);
         CS.Free (Path);
         CS.Free (Interface_Name);
         CS.Free (Property);
         return Result;
      exception
         when others =>
            CS.Free (Destination);
            CS.Free (Path);
            CS.Free (Interface_Name);
            CS.Free (Property);
            return False;
      end Read_Property;

      function Read_Class_Profile return Boolean is
         Search      : Ada.Directories.Search_Type;
         Search_Open : Boolean := False;
         Item        : Ada.Directories.Directory_Entry_Type;
         Present     : Boolean := False;
         Found       : Boolean := False;
         Ambiguous   : Boolean := False;
         Candidate   : Performance_Profile := Profile_Unknown;
      begin
         Ada.Directories.Start_Search
           (Search,
            Linux_Sysfs_Path ("/class/platform-profile"),
            "platform-profile-*",
            (Ada.Directories.Directory => True, others => False));
         Search_Open := True;
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Item);
            Present := True;
            declare
               OK     : Boolean;
               Text   : constant String := First_Line (Ada.Directories.Full_Name (Item) & "/profile", OK);
               Parsed : constant Performance_Profile := Parse_Profile (Text);
            begin
               if OK then
                  if Parsed = Profile_Unknown then
                     Ambiguous := True;
                  elsif not Found then
                     Candidate := Parsed;
                     Found := True;
                  elsif Parsed /= Candidate then
                     Ambiguous := True;
                  end if;
               else
                  Ambiguous := True;
               end if;
            end;
         end loop;
         Ada.Directories.End_Search (Search);
         Search_Open := False;
         if Present and then Found and then not Ambiguous then
            Value.Profile_Availability := Condition_Available;
            Value.Profile_Detector := Linux_Platform_Profile;
            Value.Profile := Candidate;
         end if;
         return Present;
      exception
         when others =>
            if Search_Open then
               begin
                  Ada.Directories.End_Search (Search);
               exception
                  when others =>
                     null;
               end;
            end if;
            return Present;
      end Read_Class_Profile;
   begin
      Status := -1;
      if Internal_Condition_Test_Hooks.Enabled then
         if Internal_Condition_Test_Hooks.Linux_Fixture_Enabled then
            Query_Live_PPD := False;
            Apply_Linux_PPD
              (Value,
               Internal_Condition_Test_Hooks.Linux_PPD_Profile,
               Internal_Condition_Test_Hooks.Linux_PPD_Profile_Available,
               Internal_Condition_Test_Hooks.Linux_PPD_Degradation,
               Internal_Condition_Test_Hooks.Linux_PPD_Degradation_Available);
         end if;
      end if;
      if Query_Live_PPD then
         --  Opening the system bus is a synchronous libsystemd operation. Do
         --  not begin it after the caller's absolute budget has expired.
         Status :=
           (if Deadline /= Interfaces.Unsigned_64'Last and then Internal_Probes.Clock_Now >= Deadline
            then -1
            else C_Linux_PPD_Open (Bus'Access));
      end if;
      if Status >= 0 and then Bus /= System.Null_Address then
         if (Resolve
               ("org.freedesktop.UPower.PowerProfiles",
                "/org/freedesktop/UPower/PowerProfiles",
                "org.freedesktop.UPower.PowerProfiles")
             or else Resolve
                       ("net.hadess.PowerProfiles", "/net/hadess/PowerProfiles", "net.hadess.PowerProfiles"))
         then
            declare
               Profile_OK     : constant Boolean := Read_Property ("ActiveProfile", Profile_Buffer);
               Degradation_OK : constant Boolean := Read_Property ("PerformanceDegraded", Degradation_Buffer);
            begin
               Apply_Linux_PPD
                 (Value,
                  Text_Value (Profile_Buffer),
                  Profile_OK,
                  Text_Value (Degradation_Buffer),
                  Degradation_OK);
            end;
         end if;
         C_Linux_PPD_Bus_Unref (Bus);
         Bus := System.Null_Address;
      end if;
      if Value.Profile_Availability = Condition_Available then
         return;
      end if;
      if Read_Class_Profile then
         return;
      end if;
      declare
         Sysfs_Profile : constant String :=
           First_Line (Linux_Sysfs_Path ("/firmware/acpi/platform_profile"), Sysfs_OK);
         Parsed        : constant Performance_Profile := Parse_Profile (Sysfs_Profile);
      begin
         if Sysfs_OK and then Parsed /= Profile_Unknown then
            Value.Profile_Availability := Condition_Available;
            Value.Profile_Detector := Linux_Platform_Profile;
            Value.Profile := Parsed;
         end if;
      end;
   exception
      when others =>
         if Bus /= System.Null_Address then
            C_Linux_PPD_Bus_Unref (Bus);
         end if;
   end Read_Linux_Profile;

   procedure Read
     (Value           : out Snapshot;
      Continuity      : in out Throttle_Continuity;
      Include_Profile : Boolean := True;
      Deadline        : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last)
   is
      Effective_Deadline : Interfaces.Unsigned_64 := Deadline;
      Now                : Interfaces.Unsigned_64;
   begin
      if Internal_Condition_Test_Hooks.Enabled then
         declare
            Supplied : Boolean;
         begin
            if Internal_Condition_Test_Hooks.Capture_Test_Enabled then
               declare
                  Success : Boolean;
                  Result  : constant US.Unbounded_String :=
                    Capture
                      (Internal_Condition_Test_Hooks.Capture_Test_Command,
                       [1 => US.To_Unbounded_String (Internal_Condition_Test_Hooks.Capture_Test_Argument)],
                       C.unsigned (Internal_Condition_Test_Hooks.Capture_Test_Timeout_MS),
                       Success);
               begin
                  Internal_Condition_Test_Hooks.Record_Capture_Test_Result (Success, US.Length (Result));
                  Value := (others => <>);
                  return;
               end;
            end if;
            Internal_Condition_Test_Hooks.Supply (Value, Include_Profile, Supplied);
            if Supplied then
               return;
            end if;
            if Internal_Condition_Test_Hooks.Linux_Fixture_Enabled then
               Value := (others => <>);
               Read_Linux_Throttle (Value, Continuity);
               if Include_Profile then
                  Read_Linux_Profile (Value, Effective_Deadline);
               end if;
               return;
            end if;
         end;
      end if;
      Value := (others => <>);
      if Effective_Deadline = Interfaces.Unsigned_64'Last then
         Now := Internal_Probes.Clock_Now;
         Effective_Deadline :=
           (if Now > Interfaces.Unsigned_64'Last - 2_000_000_000
            then Interfaces.Unsigned_64'Last
            else Now + 2_000_000_000);
      end if;
      case Internal_Probes.Operating_System is
         when Internal_Probes.Darwin         =>
            Read_Darwin_Live (Value);
            if Include_Profile then
               Read_Darwin_Profile (Value, Effective_Deadline);
            end if;

         when Internal_Probes.Linux          =>
            Read_Linux_Throttle (Value, Continuity);
            --  The PPD read is passive, bounded, and is also the only common
            --  live thermal-degradation signal on AMD64 and AArch64.
            if Include_Profile then
               Read_Linux_Profile (Value, Effective_Deadline);
            end if;

         when Internal_Probes.Unknown_System =>
            null;
      end case;
   end Read;

end Flyology_Bench.Internal_Conditions;
