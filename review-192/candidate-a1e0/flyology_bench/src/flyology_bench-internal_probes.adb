--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  System.OS_Constants is generated from this host's own headers by the
--  compiler, which makes it the platform specification for the values used
--  below. The crate already requires GNAT, so the warning about depending
--  on an implementation unit does not apply.
pragma Warnings (Off, "*internal GNAT unit*");
pragma Warnings (Off, "*non-portable and version-dependent*");

with Ada.Text_IO;
with Interfaces.C;
with System.Machine_Code;
with System.OS_Constants;

package body Flyology_Bench.Internal_Probes is
   package C renames Interfaces.C;
   package OSC renames System.OS_Constants;

   use type C.int;
   use type C.long;
   use type C.size_t;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Nanoseconds_Per_Second      : constant := 1_000_000_000;
   Nanoseconds_Per_Microsecond : constant := 1_000;

   ---------------------------------------------------------------------
   --  Values the platform headers define                              --
   ---------------------------------------------------------------------

   Native_OS : constant C.int;
   pragma Import (C, Native_OS, "flyology_bench_platform_os");

   Native_Architecture : constant C.int;
   pragma Import (C, Native_Architecture, "flyology_bench_platform_architecture");

   Native_Monotonic_Clock : constant C.int;
   pragma Import (C, Native_Monotonic_Clock, "flyology_bench_monotonic_clock");

   Native_CPU_Limit : constant C.int;
   pragma Import (C, Native_CPU_Limit, "flyology_bench_cpu_limit");

   Native_Pagesize_Name : constant C.int;
   pragma Import (C, Native_Pagesize_Name, "flyology_bench_sc_pagesize");

   Native_Timeval_Bytes : constant C.size_t;
   pragma Import (C, Native_Timeval_Bytes, "flyology_bench_timeval_bytes");

   Native_Timespec_Bytes : constant C.size_t;
   pragma Import (C, Native_Timespec_Bytes, "flyology_bench_timespec_bytes");

   Native_Rusage_Bytes : constant C.size_t;
   pragma Import (C, Native_Rusage_Bytes, "flyology_bench_rusage_bytes");

   Native_Rusage_Counters_Offset : constant C.size_t;
   pragma Import (C, Native_Rusage_Counters_Offset, "flyology_bench_rusage_counters_offset");

   ---------------------------------------------------------------------
   --  Entry points that exist on one platform only                    --
   ---------------------------------------------------------------------

   function Mach_Ticks return Interfaces.Unsigned_64;
   pragma Import (C, Mach_Ticks, "flyology_bench_mach_ticks");

   function Mach_Timebase
     (Numerator : access Interfaces.Unsigned_32; Denominator : access Interfaces.Unsigned_32) return C.int;
   pragma Import (C, Mach_Timebase, "flyology_bench_mach_timebase");

   function Mach_Resident_Bytes (Bytes : access Interfaces.Unsigned_64) return C.int;
   pragma Import (C, Mach_Resident_Bytes, "flyology_bench_mach_resident_bytes");

   function Mach_Disk_IO
     (Read_Bytes : access Interfaces.Unsigned_64; Written_Bytes : access Interfaces.Unsigned_64) return C.int;
   pragma Import (C, Mach_Disk_IO, "flyology_bench_mach_disk_io");

   function Mach_CPU_Ticks
     (Busy_Ticks  : System.Address;
      Total_Ticks : System.Address;
      Capacity    : C.size_t;
      CPU_Count   : access C.size_t) return C.int;
   pragma Import (C, Mach_CPU_Ticks, "flyology_bench_mach_cpu_ticks");

   function Native_Thread_Identifier return Interfaces.Unsigned_64;
   pragma Import (C, Native_Thread_Identifier, "flyology_bench_native_thread_id");

   function Native_Bind_Thread (CPU : C.unsigned) return C.int;
   pragma Import (C, Native_Bind_Thread, "flyology_bench_bind_thread");

   ---------------------------------------------------------------------
   --  Ordinary libc entry points                                      --
   ---------------------------------------------------------------------

   --  The compiler-generated platform specification records the timeval
   --  field widths. GCC 13 through 15 do not expose SIZEOF_tv_nsec, so use
   --  C long for that field; the native bridge checks its header type at
   --  compile time, and the elaboration check below verifies the total layout.
   Seconds_Bits      : constant := OSC.SIZEOF_tv_sec * 8;
   Microseconds_Bits : constant := OSC.SIZEOF_tv_usec * 8;
   Nanoseconds_Bits  : constant := C.long'Size;

   type Seconds_Field is range -(2**(Seconds_Bits - 1)) .. 2**(Seconds_Bits - 1) - 1;
   for Seconds_Field'Size use Seconds_Bits;

   type Microseconds_Field is range -(2**(Microseconds_Bits - 1)) .. 2**(Microseconds_Bits - 1) - 1;
   for Microseconds_Field'Size use Microseconds_Bits;

   type Nanoseconds_Field is range -(2**(Nanoseconds_Bits - 1)) .. 2**(Nanoseconds_Bits - 1) - 1;
   for Nanoseconds_Field'Size use Nanoseconds_Bits;

   type Timeval is record
      Seconds      : Seconds_Field := 0;
      Microseconds : Microseconds_Field := 0;
   end record
   with Convention => C;

   type Timespec is record
      Seconds     : Seconds_Field := 0;
      Nanoseconds : Nanoseconds_Field := 0;
   end record
   with Convention => C;

   --  struct rusage carries two time values and then fourteen longs on both
   --  supported platforms. tests/flyology_bench_abi_probe.c checks this
   --  layout against the headers.
   type Resource_Usage is record
      User_Time            : Timeval;
      System_Time          : Timeval;
      Maximum_Resident     : C.long := 0;
      Shared_Text          : C.long := 0;
      Unshared_Data        : C.long := 0;
      Unshared_Stack       : C.long := 0;
      Minor_Faults         : C.long := 0;
      Major_Faults         : C.long := 0;
      Swaps                : C.long := 0;
      Block_Input          : C.long := 0;
      Block_Output         : C.long := 0;
      Messages_Sent        : C.long := 0;
      Messages_Received    : C.long := 0;
      Signals              : C.long := 0;
      Voluntary_Switches   : C.long := 0;
      Involuntary_Switches : C.long := 0;
   end record
   with Convention => C;

   Rusage_Self : constant C.int := 0;

   function Get_Resource_Usage (Who : C.int; Usage : access Resource_Usage) return C.int;
   pragma Import (C, Get_Resource_Usage, "getrusage");

   function Clock_Gettime (Clock : C.int; Value : access Timespec) return C.int;
   pragma Import (C, Clock_Gettime, "clock_gettime");

   function Clock_Getres (Clock : C.int; Value : access Timespec) return C.int;
   pragma Import (C, Clock_Getres, "clock_getres");

   function Sysconf (Name : C.int) return C.long;
   pragma Import (C, Sysconf, "sysconf");

   ---------------------------------------------------------------------
   --  Cached platform facts                                           --
   ---------------------------------------------------------------------

   Timebase_Numerator   : Interfaces.Unsigned_32 := 0;
   Timebase_Denominator : Interfaces.Unsigned_32 := 0;
   Timebase_Known       : Boolean := False;

   Page_Bytes : Interfaces.Unsigned_64 := 0;

   ---------------------------------------------------------------------
   --  Host identity                                                   --
   ---------------------------------------------------------------------

   function Operating_System return Host_System is
   begin
      case Native_OS is
         when 1      =>
            return Darwin;

         when 2      =>
            return Linux;

         when others =>
            return Unknown_System;
      end case;
   end Operating_System;

   function Architecture return Host_Architecture is
   begin
      case Native_Architecture is
         when 1      =>
            return AArch64;

         when 2      =>
            return X86_64;

         when others =>
            return Unknown_Architecture;
      end case;
   end Architecture;

   function Clock_Backend return Natural
   is (if Operating_System = Darwin then Mach_Clock_Backend else Monotonic_Raw_Backend);

   ---------------------------------------------------------------------
   --  Bit masks                                                       --
   ---------------------------------------------------------------------

   function Mask_Bit (Bit : Natural) return Interfaces.Unsigned_64
   is (Interfaces.Shift_Left (Interfaces.Unsigned_64'(1), Bit));

   function Mask_Has (Mask : Interfaces.Unsigned_64; Bit : Natural) return Boolean
   is ((Mask and Mask_Bit (Bit)) /= 0);

   procedure Mark (Mask : in out Interfaces.Unsigned_64; Bit : Natural) is
   begin
      Mask := Mask or Mask_Bit (Bit);
   end Mark;

   ---------------------------------------------------------------------
   --  Conversions                                                     --
   ---------------------------------------------------------------------

   --  A kernel counter is never negative. Reporting zero rather than
   --  wrapping keeps one implausible field from becoming an enormous one.
   function Counted (Value : C.long) return Interfaces.Unsigned_64
   is (if Value <= 0 then 0 else Interfaces.Unsigned_64 (Value));

   function Nanoseconds_Of (Value : Timeval) return Interfaces.Unsigned_64 is
      Seconds      : constant Interfaces.Unsigned_64 :=
        (if Value.Seconds <= 0 then 0 else Interfaces.Unsigned_64 (Value.Seconds));
      Microseconds : constant Interfaces.Unsigned_64 :=
        (if Value.Microseconds <= 0 then 0 else Interfaces.Unsigned_64 (Value.Microseconds));
   begin
      return Seconds * Nanoseconds_Per_Second + Microseconds * Nanoseconds_Per_Microsecond;
   end Nanoseconds_Of;

   function Nanoseconds_Of (Value : Timespec) return Interfaces.Unsigned_64 is
      Seconds     : constant Interfaces.Unsigned_64 :=
        (if Value.Seconds <= 0 then 0 else Interfaces.Unsigned_64 (Value.Seconds));
      Nanoseconds : constant Interfaces.Unsigned_64 :=
        (if Value.Nanoseconds <= 0 then 0 else Interfaces.Unsigned_64 (Value.Nanoseconds));
   begin
      return Seconds * Nanoseconds_Per_Second + Nanoseconds;
   end Nanoseconds_Of;

   ---------------------------------------------------------------------
   --  Monotonic clock                                                 --
   ---------------------------------------------------------------------

   --  Mach ticks scale by a rational factor. Splitting the tick count at
   --  the denominator keeps the exact product within 64 bits for every
   --  timebase a host can report, so no wider arithmetic is needed.
   procedure Scaled_Ticks
     (Ticks : Interfaces.Unsigned_64; Nanoseconds : out Interfaces.Unsigned_64; Fits : out Boolean)
   is
      Numerator   : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Timebase_Numerator);
      Denominator : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Timebase_Denominator);
      Whole       : Interfaces.Unsigned_64;
      Remainder   : Interfaces.Unsigned_64;
   begin
      Nanoseconds := 0;
      Fits := False;
      if not Timebase_Known then
         return;
      end if;
      Whole := Ticks / Denominator;
      Remainder := Ticks mod Denominator;
      if Whole > Interfaces.Unsigned_64'Last / Numerator then
         return;
      end if;
      Whole := Whole * Numerator;
      Remainder := Remainder * Numerator / Denominator;
      if Whole > Interfaces.Unsigned_64'Last - Remainder then
         return;
      end if;
      Nanoseconds := Whole + Remainder;
      Fits := True;
   end Scaled_Ticks;

   procedure Read_Clock (Nanoseconds : out Interfaces.Unsigned_64; Available : out Boolean) is
      Sample : aliased Timespec;
   begin
      if Operating_System = Darwin then
         Scaled_Ticks (Mach_Ticks, Nanoseconds, Available);
         return;
      end if;
      Nanoseconds := 0;
      Available := Clock_Gettime (Native_Monotonic_Clock, Sample'Access) = 0;
      if Available then
         Nanoseconds := Nanoseconds_Of (Sample);
      end if;
   end Read_Clock;

   function Clock_Now return Interfaces.Unsigned_64 is
      Value     : Interfaces.Unsigned_64;
      Available : Boolean;
   begin
      Read_Clock (Value, Available);
      if not Available then
         raise Program_Error with "platform monotonic clock read failed";
      end if;
      return Value;
   end Clock_Now;

   procedure Read_Clock_Resolution (Nanoseconds : out Interfaces.Unsigned_64; Available : out Boolean) is
      Sample : aliased Timespec;
   begin
      Nanoseconds := 0;
      Available := False;
      if Operating_System = Darwin then
         if not Timebase_Known then
            return;
         end if;
         --  One tick rounded up to whole nanoseconds, and never zero: a
         --  sub-nanosecond tick still resolves to at least one nanosecond.
         Nanoseconds :=
           (Interfaces.Unsigned_64 (Timebase_Numerator) + Interfaces.Unsigned_64 (Timebase_Denominator) - 1)
           / Interfaces.Unsigned_64 (Timebase_Denominator);
         if Nanoseconds = 0 then
            Nanoseconds := 1;
         end if;
         Available := True;
         return;
      end if;
      Available := Clock_Getres (Native_Monotonic_Clock, Sample'Access) = 0;
      if Available then
         Nanoseconds := Nanoseconds_Of (Sample);
      end if;
   end Read_Clock_Resolution;

   ---------------------------------------------------------------------
   --  Threads                                                         --
   ---------------------------------------------------------------------

   function Native_Thread_Id return Interfaces.Unsigned_64
   is (Native_Thread_Identifier);

   function Place_Current_Thread (CPU : Natural) return Placement_Outcome is
   begin
      if C.int (CPU) >= Native_CPU_Limit then
         return Placement_Refused;
      elsif Native_Bind_Thread (C.unsigned (CPU)) /= 0 then
         return Placement_Refused;
      end if;
      --  A Darwin affinity tag only asks the scheduler to keep tagged
      --  threads together, while a Linux mask is binding.
      return (if Operating_System = Darwin then Advisory_Placement else Strict_Placement);
   end Place_Current_Thread;

   ---------------------------------------------------------------------
   --  Reading /proc                                                   --
   ---------------------------------------------------------------------

   Line_Limit : constant := 1_024;

   --  Scans the next whitespace-separated unsigned value at or after From,
   --  leaving From just past it.
   procedure Scan_Unsigned
     (Text : String; From : in out Natural; Value : out Interfaces.Unsigned_64; Found : out Boolean)
   is
      Digits_Seen : Natural := 0;
   begin
      Value := 0;
      Found := False;
      while From <= Text'Last and then Text (From) = ' ' loop
         From := From + 1;
      end loop;
      while From <= Text'Last and then Text (From) in '0' .. '9' loop
         --  A field wider than the counter it names is not a value this
         --  package can report, so the reading is abandoned.
         if Value > (Interfaces.Unsigned_64'Last - 9) / 10 then
            Value := 0;
            Found := False;
            return;
         end if;
         Value := Value * 10 + Interfaces.Unsigned_64 (Character'Pos (Text (From)) - Character'Pos ('0'));
         Digits_Seen := Digits_Seen + 1;
         From := From + 1;
      end loop;
      Found := Digits_Seen > 0;
   end Scan_Unsigned;

   function Starts_With (Text : String; Prefix : String) return Boolean
   is (Text'Length >= Prefix'Length and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   --  Resident set size from /proc/self/statm, whose second field counts
   --  resident pages.
   procedure Read_Proc_Resident (Bytes : out Interfaces.Unsigned_64; Available : out Boolean) is
      File   : Ada.Text_IO.File_Type;
      Line   : String (1 .. Line_Limit);
      Last   : Natural;
      Cursor : Natural;
      Total  : Interfaces.Unsigned_64;
      Pages  : Interfaces.Unsigned_64;
      Found  : Boolean;
   begin
      Bytes := 0;
      Available := False;
      if Page_Bytes = 0 then
         return;
      end if;
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "/proc/self/statm");
      exception
         when others =>
            return;
      end;
      if not Ada.Text_IO.End_Of_File (File) then
         Ada.Text_IO.Get_Line (File, Line, Last);
         Cursor := Line'First;
         Scan_Unsigned (Line (Line'First .. Last), Cursor, Total, Found);
         if Found then
            Scan_Unsigned (Line (Line'First .. Last), Cursor, Pages, Found);
            if Found and then Pages <= Interfaces.Unsigned_64'Last / Page_Bytes then
               Bytes := Pages * Page_Bytes;
               Available := True;
            end if;
         end if;
      end if;
      Ada.Text_IO.Close (File);
   exception
      when others =>
         Bytes := 0;
         Available := False;
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Read_Proc_Resident;

   --  Block-device byte counts from /proc/self/io. The keys are reported
   --  independently, so one present key is still an answer.
   procedure Read_Proc_Disk_IO
     (Read_Bytes        : out Interfaces.Unsigned_64;
      Read_Available    : out Boolean;
      Written_Bytes     : out Interfaces.Unsigned_64;
      Written_Available : out Boolean)
   is
      Read_Key  : constant String := "read_bytes:";
      Write_Key : constant String := "write_bytes:";
      File      : Ada.Text_IO.File_Type;
      Line      : String (1 .. Line_Limit);
      Last      : Natural;
      Cursor    : Natural;
      Value     : Interfaces.Unsigned_64;
      Found     : Boolean;
   begin
      Read_Bytes := 0;
      Read_Available := False;
      Written_Bytes := 0;
      Written_Available := False;
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "/proc/self/io");
      exception
         when others =>
            return;
      end;
      while not Ada.Text_IO.End_Of_File (File) loop
         Ada.Text_IO.Get_Line (File, Line, Last);
         declare
            Text : constant String := Line (Line'First .. Last);
         begin
            --  cancelled_write_bytes does not answer to write_bytes because
            --  the key is matched from the start of the line.
            if Starts_With (Text, Read_Key) then
               Cursor := Text'First + Read_Key'Length;
               Scan_Unsigned (Text, Cursor, Value, Found);
               if Found then
                  Read_Bytes := Value;
                  Read_Available := True;
               end if;
            elsif Starts_With (Text, Write_Key) then
               Cursor := Text'First + Write_Key'Length;
               Scan_Unsigned (Text, Cursor, Value, Found);
               if Found then
                  Written_Bytes := Value;
                  Written_Available := True;
               end if;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Read_Proc_Disk_IO;

   --  Per-CPU tick totals from /proc/stat, each stored at the index of the
   --  logical CPU it names so that a caller holding a CPU number can read
   --  that CPU's row directly. Reading stops at the first line that is not
   --  a CPU line. A CPU line short of its eight tick fields, or one naming
   --  a CPU beyond the represented range, refuses the whole reading rather
   --  than reporting a utilization figure drawn from part of the machine.
   procedure Read_Proc_Host_CPU
     (Busy      : out Host_CPU_Counters;
      Total     : out Host_CPU_Counters;
      CPU_Count : out Natural;
      Available : out Boolean)
   is
      Prefix  : constant String := "cpu";
      File    : Ada.Text_IO.File_Type;
      Line    : String (1 .. Line_Limit);
      Last    : Natural;
      Highest : Natural := 0;
      Broken  : Boolean := False;
   begin
      Busy := [others => 0];
      Total := [others => 0];
      CPU_Count := 0;
      Available := False;
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "/proc/stat");
      exception
         when others =>
            return;
      end;
      Reading :
      while not Ada.Text_IO.End_Of_File (File) loop
         Ada.Text_IO.Get_Line (File, Line, Last);
         declare
            Text   : constant String := Line (Line'First .. Last);
            Cursor : Natural;
            Index  : Interfaces.Unsigned_64;
            Found  : Boolean;
            Ticks  : array (1 .. 8) of Interfaces.Unsigned_64 := [others => 0];
         begin
            exit Reading when not Starts_With (Text, Prefix);
            Cursor := Text'First + Prefix'Length;
            --  The whole-machine summary line puts whitespace where a CPU
            --  line puts its number. A value scan would step over that
            --  whitespace and take the summary's first tick total for a CPU
            --  number, so the digit is required to be immediately here.
            Found := Cursor <= Text'Last and then Text (Cursor) in '0' .. '9';
            if Found then
               Scan_Unsigned (Text, Cursor, Index, Found);
            end if;
            if Found then
               if Index > Interfaces.Unsigned_64 (Maximum_Host_CPUs - 1) then
                  Broken := True;
                  exit Reading;
               end if;
               for Position in Ticks'Range loop
                  Scan_Unsigned (Text, Cursor, Ticks (Position), Found);
                  exit when not Found;
               end loop;
               if not Found then
                  Broken := True;
                  exit Reading;
               end if;
               declare
                  Slot : constant Natural := Natural (Index);
               begin
                  --  user, nice, system, irq, softirq, and steal are busy;
                  --  idle and iowait are not.
                  Busy (Slot) := Ticks (1) + Ticks (2) + Ticks (3) + Ticks (6) + Ticks (7) + Ticks (8);
                  Total (Slot) := Busy (Slot) + Ticks (4) + Ticks (5);
                  --  An offline CPU has no line at all, so its row stays
                  --  zero and every reader skips it for having no elapsed
                  --  ticks.
                  Highest := Natural'Max (Highest, Slot + 1);
               end;
            end if;
         end;
      end loop Reading;
      Ada.Text_IO.Close (File);
      if Broken then
         Busy := [others => 0];
         Total := [others => 0];
         return;
      end if;
      CPU_Count := Highest;
      Available := Highest > 0;
   exception
      when others =>
         CPU_Count := 0;
         Available := False;
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Read_Proc_Host_CPU;

   ---------------------------------------------------------------------
   --  Process usage                                                   --
   ---------------------------------------------------------------------

   procedure Read_Resident_Bytes (Bytes : out Interfaces.Unsigned_64; Available : out Boolean) is
      Value : aliased Interfaces.Unsigned_64 := 0;
   begin
      if Operating_System = Darwin then
         Bytes := 0;
         Available := Mach_Resident_Bytes (Value'Access) = 0;
         if Available then
            Bytes := Value;
         end if;
      else
         Read_Proc_Resident (Bytes, Available);
      end if;
   end Read_Resident_Bytes;

   procedure Read_Process_Usage
     (CPU_Nanoseconds : out Interfaces.Unsigned_64;
      Resident_Bytes  : out Interfaces.Unsigned_64;
      Available       : out Boolean)
   is
      Usage : aliased Resource_Usage;
   begin
      CPU_Nanoseconds := 0;
      Resident_Bytes := 0;
      Available := False;
      if Get_Resource_Usage (Rusage_Self, Usage'Access) /= 0 then
         return;
      end if;
      CPU_Nanoseconds := Nanoseconds_Of (Usage.User_Time) + Nanoseconds_Of (Usage.System_Time);
      Read_Resident_Bytes (Resident_Bytes, Available);
   end Read_Process_Usage;

   ---------------------------------------------------------------------
   --  Resource snapshot                                               --
   ---------------------------------------------------------------------

   procedure Read_Resource_Snapshot
     (Values : out Resource_Values; Mask : out Interfaces.Unsigned_64; Available : out Boolean)
   is
      Usage   : aliased Resource_Usage;
      Sample  : aliased Timespec;
      Present : Boolean;
      Bytes   : Interfaces.Unsigned_64;
   begin
      Values := [others => 0];
      Mask := 0;
      Available := False;
      if Get_Resource_Usage (Rusage_Self, Usage'Access) /= 0 then
         return;
      end if;
      Values (Process_CPU_Index) := Nanoseconds_Of (Usage.User_Time) + Nanoseconds_Of (Usage.System_Time);
      Values (Minor_Faults_Index) := Counted (Usage.Minor_Faults);
      Values (Major_Faults_Index) := Counted (Usage.Major_Faults);
      Values (Voluntary_Switches_Index) := Counted (Usage.Voluntary_Switches);
      Values (Involuntary_Switches_Index) := Counted (Usage.Involuntary_Switches);
      Values (Input_Operations_Index) := Counted (Usage.Block_Input);
      Values (Output_Operations_Index) := Counted (Usage.Block_Output);
      Mark (Mask, Process_CPU_Index);
      Mark (Mask, Minor_Faults_Index);
      Mark (Mask, Major_Faults_Index);
      Mark (Mask, Voluntary_Switches_Index);
      Mark (Mask, Involuntary_Switches_Index);
      Mark (Mask, Input_Operations_Index);
      Mark (Mask, Output_Operations_Index);

      if Clock_Gettime (C.int (OSC.CLOCK_THREAD_CPUTIME_ID), Sample'Access) = 0 then
         Values (Thread_CPU_Index) := Nanoseconds_Of (Sample);
         Mark (Mask, Thread_CPU_Index);
      end if;

      Read_Resident_Bytes (Bytes, Present);
      if Present then
         Values (Resident_Bytes_Index) := Bytes;
         Mark (Mask, Resident_Bytes_Index);
      end if;

      if Operating_System = Darwin then
         declare
            Read_Bytes    : aliased Interfaces.Unsigned_64 := 0;
            Written_Bytes : aliased Interfaces.Unsigned_64 := 0;
         begin
            if Mach_Disk_IO (Read_Bytes'Access, Written_Bytes'Access) = 0 then
               Values (Disk_Read_Bytes_Index) := Read_Bytes;
               Values (Disk_Written_Bytes_Index) := Written_Bytes;
               Mark (Mask, Disk_Read_Bytes_Index);
               Mark (Mask, Disk_Written_Bytes_Index);
            end if;
         end;
      else
         declare
            Read_Bytes      : Interfaces.Unsigned_64;
            Read_Present    : Boolean;
            Written_Bytes   : Interfaces.Unsigned_64;
            Written_Present : Boolean;
         begin
            Read_Proc_Disk_IO (Read_Bytes, Read_Present, Written_Bytes, Written_Present);
            if Read_Present then
               Values (Disk_Read_Bytes_Index) := Read_Bytes;
               Mark (Mask, Disk_Read_Bytes_Index);
            end if;
            if Written_Present then
               Values (Disk_Written_Bytes_Index) := Written_Bytes;
               Mark (Mask, Disk_Written_Bytes_Index);
            end if;
         end;
      end if;
      Available := True;
   end Read_Resource_Snapshot;

   ---------------------------------------------------------------------
   --  Host CPU utilization                                            --
   ---------------------------------------------------------------------

   procedure Read_Host_CPU
     (Busy      : out Host_CPU_Counters;
      Total     : out Host_CPU_Counters;
      CPU_Count : out Natural;
      Available : out Boolean)
   is
      Count : aliased C.size_t := 0;
   begin
      if Operating_System /= Darwin then
         Read_Proc_Host_CPU (Busy, Total, CPU_Count, Available);
         return;
      end if;
      Busy := [others => 0];
      Total := [others => 0];
      CPU_Count := 0;
      Available :=
        Mach_CPU_Ticks
          (Busy (Busy'First)'Address, Total (Total'First)'Address, C.size_t (Maximum_Host_CPUs), Count'Access)
        = 0
        and then Count > 0
        and then Count <= C.size_t (Maximum_Host_CPUs);
      if Available then
         CPU_Count := Natural (Count);
      end if;
   end Read_Host_CPU;

   ---------------------------------------------------------------------
   --  Optimization barriers                                           --
   ---------------------------------------------------------------------

   procedure Escape (Value : System.Address) is
   begin
      System.Machine_Code.Asm
        ("", Inputs => System.Address'Asm_Input ("r", Value), Clobber => "memory", Volatile => True);
   end Escape;

   procedure Clobber_Memory is
   begin
      System.Machine_Code.Asm ("", Clobber => "memory", Volatile => True);
   end Clobber_Memory;

begin
   --  The structures above are derived rather than transcribed, so the
   --  derivation is checked against the headers before anything reads one.
   if C.size_t (Timeval'Max_Size_In_Storage_Elements) /= Native_Timeval_Bytes
     or else C.size_t (Timespec'Max_Size_In_Storage_Elements) /= Native_Timespec_Bytes
     or else C.size_t (Resource_Usage'Max_Size_In_Storage_Elements) /= Native_Rusage_Bytes
     or else 2 * Native_Timeval_Bytes /= Native_Rusage_Counters_Offset
   then
      raise Program_Error
        with "platform time or resource-usage layout is not the one this crate " & "derives";
   end if;

   if Operating_System = Darwin then
      declare
         Numerator   : aliased Interfaces.Unsigned_32 := 0;
         Denominator : aliased Interfaces.Unsigned_32 := 0;
      begin
         Timebase_Known :=
           Mach_Timebase (Numerator'Access, Denominator'Access) = 0
           and then Denominator /= 0
           and then Numerator /= 0;
         if Timebase_Known then
            Timebase_Numerator := Numerator;
            Timebase_Denominator := Denominator;
         end if;
      end;
   else
      declare
         Size : constant C.long := Sysconf (Native_Pagesize_Name);
      begin
         if Size > 0 then
            Page_Bytes := Interfaces.Unsigned_64 (Size);
         end if;
      end;
   end if;
end Flyology_Bench.Internal_Probes;
