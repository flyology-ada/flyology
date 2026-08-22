--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

--  System.OS_Constants is generated from this host's own headers by the
--  compiler, which makes it the platform specification for the values used
--  below. The crate already requires GNAT, so the warning about depending
--  on an implementation unit does not apply.
pragma Warnings (Off, "*internal GNAT unit*");
pragma Warnings (Off, "*non-portable and version-dependent*");

with GNAT.OS_Lib;
with System;
with System.OS_Constants;

package body Flyology_Bench.Internal_Probes.Counters is
   package C renames Interfaces.C;
   package OSC renames System.OS_Constants;

   use type C.long;
   use type Interfaces.Unsigned_64;

   ---------------------------------------------------------------------
   --  Values the platform headers define                              --
   ---------------------------------------------------------------------

   --  Both the call number and the ioctl requests are computed by macros
   --  and differ between architectures, so the native unit publishes them.
   Native_Open_Call : constant C.long;
   pragma Import (C, Native_Open_Call, "flyology_bench_perf_event_open_call");

   Native_Enable_Request : constant C.unsigned_long;
   pragma Import (C, Native_Enable_Request, "flyology_bench_perf_enable_request");

   Native_Disable_Request : constant C.unsigned_long;
   pragma Import (C, Native_Disable_Request, "flyology_bench_perf_disable_request");

   Native_Group_Flag : constant C.unsigned_long;
   pragma Import (C, Native_Group_Flag, "flyology_bench_perf_group_flag");

   --  perf_event ABI values. These are architecture-independent and have
   --  not changed since the interface was introduced.
   Type_Hardware : constant := 0;

   Config_For : constant array (Counter_Index) of Interfaces.Unsigned_64 :=
     [Cycles_Index        => 0,
      --  PERF_COUNT_HW_CPU_CYCLES
      Instructions_Index  => 1,
      --  PERF_COUNT_HW_INSTRUCTIONS
      Cache_Misses_Index  => 3,
      --  PERF_COUNT_HW_CACHE_MISSES
      Branches_Index      => 4,
      --  PERF_COUNT_HW_BRANCH_INSTRUCTIONS
      Branch_Misses_Index => 5];  --  PERF_COUNT_HW_BRANCH_MISSES

   Format_Total_Time_Enabled : constant := 16#1#;
   Format_Total_Time_Running : constant := 16#2#;

   --  Bit positions within the attribute flag word. The kernel declares
   --  them as bit fields of a __u64, which both supported architectures
   --  fill from the least significant end.
   Disabled_Flag           : constant := 16#1#;         --  bit 0
   Inherit_Flag            : constant := 16#2#;          --  bit 1
   Exclude_Kernel_Flag     : constant := 16#20#;  --  bit 5
   Exclude_Hypervisor_Flag : constant := 16#40#;  --  bit 6
   Inherit_Stat_Flag       : constant := 16#800#;   --  bit 11

   --  The attribute record is versioned by its own size field. A kernel
   --  older than this version accepts a longer record whose tail is zero,
   --  and a newer one zero-fills what this record does not carry, so a
   --  fixed size is portable in both directions.
   Attribute_Bytes      : constant := 128;
   Attribute_Head_Bytes : constant := 48;
   Attribute_Tail_Words : constant := (Attribute_Bytes - Attribute_Head_Bytes) / 8;

   type Attribute_Tail is array (1 .. Attribute_Tail_Words) of Interfaces.Unsigned_64;

   type Event_Attributes is record
      Kind          : Interfaces.Unsigned_32 := Type_Hardware;
      Size          : Interfaces.Unsigned_32 := Attribute_Bytes;
      Config        : Interfaces.Unsigned_64 := 0;
      Sample_Period : Interfaces.Unsigned_64 := 0;
      Sample_Type   : Interfaces.Unsigned_64 := 0;
      Read_Format   : Interfaces.Unsigned_64 := 0;
      Flags         : Interfaces.Unsigned_64 := 0;
      Reserved      : Attribute_Tail := [others => 0];
   end record
   with Convention => C;

   type Counter_Reading is record
      Value        : Interfaces.Unsigned_64 := 0;
      Time_Enabled : Interfaces.Unsigned_64 := 0;
      Time_Running : Interfaces.Unsigned_64 := 0;
   end record
   with Convention => C;

   ---------------------------------------------------------------------
   --  Entry points                                                    --
   ---------------------------------------------------------------------

   --  syscall is variadic. C_Variadic_1 marks its one fixed parameter, so
   --  GNAT emits the call sequence the platform ABI wants for the rest.
   function Open_Event
     (Call       : C.long;
      Attributes : System.Address;
      Process    : C.int;
      CPU        : C.int;
      Leader     : C.int;
      Flags      : C.unsigned_long) return C.long
   with Import, Convention => C_Variadic_1, External_Name => "syscall";

   function Control (Descriptor : C.int; Request : C.unsigned_long; Argument : C.unsigned_long) return C.int
   with Import, Convention => C_Variadic_2, External_Name => "ioctl";

   function Read_Descriptor (Descriptor : C.int; Buffer : System.Address; Count : C.size_t) return C.long;
   pragma Import (C, Read_Descriptor, "read");

   function Close_Descriptor (Descriptor : C.int) return C.int;
   pragma Import (C, Close_Descriptor, "close");

   --  Closing a counter descriptor cannot fail in a way a caller could act
   --  on, and the group is being abandoned either way.
   procedure Discard (Status : C.int) is
      pragma Unreferenced (Status);
   begin
      null;
   end Discard;

   ---------------------------------------------------------------------
   --  Error classification                                            --
   ---------------------------------------------------------------------

   --  Linux and Darwin agree on these numbers; the runtime records the
   --  ones where they differ.
   Error_Not_Permitted : constant := 1;
   Error_No_Device     : constant := 19;
   Error_Busy          : constant := 16;
   Error_Table_Full    : constant := 23;
   Error_No_Space      : constant := 28;
   Error_Invalid       : constant := OSC.EINVAL;

   --  Classifies an errno reported by a counter control or read operation.
   --  EINVAL is deliberately absent: at open time it is ambiguous and is
   --  resolved separately by Probe_Event, and on a control or read path it
   --  means this package issued a malformed request.
   function Failure_Status (Error : Integer) return Metric_Availability is
   begin
      if Error = OSC.EACCES or else Error = Error_Not_Permitted then
         return Permission_Denied;
      elsif Error = Error_No_Device or else Error = OSC.ENOENT or else Error = OSC.EOPNOTSUPP then
         return Unsupported_Event;
      elsif Error = Error_Busy
        or else Error = OSC.EMFILE
        or else Error = Error_Table_Full
        or else Error = Error_No_Space
      then
         return Counter_Resources_Unavailable;
      end if;
      return Probe_Failed;
   end Failure_Status;

   --  Classifies a probe of the bare generic event.
   --
   --  perf_event_open reports EINVAL both for a generic event that the host
   --  PMU cannot map (x86-64 returns EINVAL where AArch64 returns ENOENT)
   --  and for an attribute combination the kernel rejects. Re-opening the
   --  event with only the permission-relevant attributes separates the two:
   --  the excludes are retained so a paranoid-level rejection still
   --  surfaces as a failure rather than being misread as an unsupported
   --  event.
   function Probe_Event (Config : Interfaces.Unsigned_64) return Metric_Availability is
      Attributes : aliased Event_Attributes;
      Descriptor : C.long;
   begin
      Attributes.Config := Config;
      Attributes.Flags := Disabled_Flag or Exclude_Kernel_Flag or Exclude_Hypervisor_Flag;
      Descriptor := Open_Event (Native_Open_Call, Attributes'Address, 0, -1, -1, 0);
      if Descriptor < 0 then
         --  A bare generic event is unsupported when the PMU cannot map it.
         --  Permission and resource failures are preserved rather than
         --  collapsed into Unsupported_Event.
         if GNAT.OS_Lib.Errno = Error_Invalid then
            return Unsupported_Event;
         end if;
         return Failure_Status (GNAT.OS_Lib.Errno);
      end if;
      Discard (Close_Descriptor (C.int (Descriptor)));
      return Metric_Collected;
   end Probe_Event;

   --  Classifies a failed open for one requested event.
   function Open_Status (Error : Integer; Config : Interfaces.Unsigned_64) return Metric_Availability is
      Probed : Metric_Availability;
   begin
      if Error /= Error_Invalid then
         return Failure_Status (Error);
      end if;
      Probed := Probe_Event (Config);
      return (if Probed = Metric_Collected then Probe_Failed else Probed);
   end Open_Status;

   ---------------------------------------------------------------------
   --  Descriptor bookkeeping                                          --
   ---------------------------------------------------------------------

   procedure Retire (Counters : in out Group; Index : Counter_Index; Outcome : Metric_Availability) is
   begin
      if Counters.Descriptor (Index) >= 0 then
         Discard (Close_Descriptor (Counters.Descriptor (Index)));
         Counters.Descriptor (Index) := -1;
      end if;
      Counters.Mask := Counters.Mask and not Mask_Bit (Index);
      Counters.Outcome (Index) := Outcome;
   end Retire;

   procedure Retire_Pair (Counters : in out Group; Outcome : Metric_Availability) is
   begin
      Retire (Counters, Cycles_Index, Outcome);
      Retire (Counters, Instructions_Index, Outcome);
      Counters.Grouped := False;
   end Retire_Pair;

   --  Retires one event. Cycles and instructions are retired together
   --  while they share a counting group, so instructions per cycle is
   --  never formed from two differently bounded windows.
   procedure Fail (Counters : in out Group; Index : Counter_Index; Outcome : Metric_Availability) is
   begin
      if Counters.Grouped and then (Index = Cycles_Index or else Index = Instructions_Index) then
         Retire_Pair (Counters, Outcome);
      else
         Retire (Counters, Index, Outcome);
      end if;
   end Fail;

   --  Reads one counter together with its multiplexing time accounting.
   procedure Read_Counter
     (Descriptor : C.int;
      Reading    : out Counter_Reading;
      Outcome    : out Metric_Availability;
      Success    : out Boolean)
   is
      Sample : aliased Counter_Reading;
      Wanted : constant C.long := Counter_Reading'Size / 8;
      Taken  : constant C.long := Read_Descriptor (Descriptor, Sample'Address, C.size_t (Wanted));
   begin
      if Taken /= Wanted then
         Reading := (others => 0);
         Outcome := (if Taken < 0 then Failure_Status (GNAT.OS_Lib.Errno) else Probe_Failed);
         Success := False;
         return;
      end if;
      Reading := Sample;
      Outcome := Metric_Collected;
      Success := True;
   end Read_Counter;

   ---------------------------------------------------------------------
   --  Group lifecycle                                                 --
   ---------------------------------------------------------------------

   procedure Open (Counters : in out Group; Requested_Mask : Interfaces.Unsigned_64) is
   begin
      Counters.Descriptor := [others => -1];
      Counters.Mask := 0;
      Counters.Outcome := [others => Metric_Not_Requested];
      Counters.Grouped := False;
      Counters.Baseline_Value := [others => 0];
      Counters.Baseline_Enabled := [others => 0];
      Counters.Baseline_Running := [others => 0];

      if Operating_System /= Linux then
         for Index in Counter_Index loop
            if Mask_Has (Requested_Mask, Index) then
               Counters.Outcome (Index) := Unsupported_Platform;
            end if;
         end loop;
         return;
      end if;

      for Index in Counter_Index loop
         if Mask_Has (Requested_Mask, Index) then
            declare
               Attributes : aliased Event_Attributes;
               Leader     : C.int := -1;
               Descriptor : C.long;
            begin
               if Index = Instructions_Index and then Counters.Descriptor (Cycles_Index) >= 0 then
                  Leader := Counters.Descriptor (Cycles_Index);
               end if;
               Attributes.Config := Config_For (Index);
               --  A group member follows its leader's enabled state, so
               --  only a leader starts disabled.
               Attributes.Flags :=
                 (if Leader < 0 then Disabled_Flag else 0)
                 or Inherit_Flag
                 or Inherit_Stat_Flag
                 or Exclude_Kernel_Flag
                 or Exclude_Hypervisor_Flag;
               Attributes.Read_Format := Format_Total_Time_Enabled or Format_Total_Time_Running;
               Descriptor := Open_Event (Native_Open_Call, Attributes'Address, 0, -1, Leader, 0);
               if Descriptor >= 0 then
                  Counters.Descriptor (Index) := C.int (Descriptor);
                  Counters.Mask := Counters.Mask or Mask_Bit (Index);
                  Counters.Outcome (Index) := Metric_Collected;
                  if Leader >= 0 then
                     Counters.Grouped := True;
                  end if;
               else
                  Counters.Outcome (Index) := Open_Status (GNAT.OS_Lib.Errno, Config_For (Index));
               end if;
            end;
         end if;
      end loop;
   end Open;

   procedure Start (Counters : in out Group) is
      Reading : Counter_Reading;
      Outcome : Metric_Availability;
      Success : Boolean;
   begin
      --  Every baseline is taken before any event is enabled. Cycles and
      --  instructions in particular must not acquire baselines at
      --  different instants: the group enable below then gives both sides
      --  of IPC one identical counting interval. The descriptors retain
      --  totals across samples, so inherited child counts are included
      --  without relying on a reset.
      for Index in Counter_Index loop
         if Counters.Descriptor (Index) >= 0 then
            Read_Counter (Counters.Descriptor (Index), Reading, Outcome, Success);
            if Success then
               Counters.Baseline_Value (Index) := Reading.Value;
               Counters.Baseline_Enabled (Index) := Reading.Time_Enabled;
               Counters.Baseline_Running (Index) := Reading.Time_Running;
            else
               Fail (Counters, Index, Outcome);
            end if;
         end if;
      end loop;

      if Counters.Grouped then
         declare
            Leader : constant C.int := Counters.Descriptor (Cycles_Index);
         begin
            if Leader < 0 or else Control (Leader, Native_Enable_Request, Native_Group_Flag) /= 0 then
               Retire_Pair (Counters, Failure_Status (GNAT.OS_Lib.Errno));
            end if;
         end;
      end if;

      for Index in Counter_Index loop
         if not (Counters.Grouped and then (Index = Cycles_Index or else Index = Instructions_Index))
           and then Counters.Descriptor (Index) >= 0
           and then Control (Counters.Descriptor (Index), Native_Enable_Request, 0) /= 0
         then
            Retire (Counters, Index, Failure_Status (GNAT.OS_Lib.Errno));
         end if;
      end loop;
   end Start;

   --  Applies the multiplexing correction. When a counter ran for its whole
   --  enabled window the answer is the count itself, which keeps the common
   --  case exact.
   procedure Scale
     (Counted : Interfaces.Unsigned_64;
      Enabled : Interfaces.Unsigned_64;
      Running : Interfaces.Unsigned_64;
      Result  : out Interfaces.Unsigned_64;
      Fits    : out Boolean)
   is
      Estimate : Long_Float;
   begin
      Result := 0;
      Fits := False;
      if Running = 0 then
         return;
      elsif Enabled = Running then
         Result := Counted;
         Fits := True;
         return;
      end if;
      Estimate := Long_Float (Counted) * Long_Float (Enabled) / Long_Float (Running);
      if Estimate < 0.0 or else Estimate >= 2.0**64 then
         return;
      end if;
      Result := Interfaces.Unsigned_64 (Long_Float'Floor (Estimate));
      Fits := True;
   end Scale;

   procedure Finish (Counters : in out Group; Result : out Perf_Values; Mask : out Interfaces.Unsigned_64) is
   begin
      Result := [others => 0];

      if Counters.Grouped then
         declare
            Leader : constant C.int := Counters.Descriptor (Cycles_Index);
         begin
            if Leader < 0 or else Control (Leader, Native_Disable_Request, Native_Group_Flag) /= 0 then
               Retire_Pair (Counters, Failure_Status (GNAT.OS_Lib.Errno));
            end if;
         end;
      end if;

      for Index in Counter_Index loop
         if not (Counters.Grouped and then (Index = Cycles_Index or else Index = Instructions_Index))
           and then Counters.Descriptor (Index) >= 0
           and then Control (Counters.Descriptor (Index), Native_Disable_Request, 0) /= 0
         then
            Retire (Counters, Index, Failure_Status (GNAT.OS_Lib.Errno));
         end if;
      end loop;

      for Index in Counter_Index loop
         if Counters.Descriptor (Index) >= 0 then
            declare
               Reading : Counter_Reading;
               Outcome : Metric_Availability;
               Success : Boolean;
               Counted : Interfaces.Unsigned_64;
               Enabled : Interfaces.Unsigned_64;
               Running : Interfaces.Unsigned_64;
               Scaled  : Interfaces.Unsigned_64;
               Fits    : Boolean;
            begin
               Read_Counter (Counters.Descriptor (Index), Reading, Outcome, Success);
               if not Success then
                  Fail (Counters, Index, Outcome);
               --  All three totals accumulate for the life of the
               --  descriptor, so a sample is the difference against the
               --  baseline captured in Start. A total that moved backwards
               --  would mean the kernel's accounting is not usable here.
               elsif Reading.Value < Counters.Baseline_Value (Index)
                 or else Reading.Time_Enabled < Counters.Baseline_Enabled (Index)
                 or else Reading.Time_Running < Counters.Baseline_Running (Index)
               then
                  Fail (Counters, Index, Probe_Failed);
               else
                  Counted := Reading.Value - Counters.Baseline_Value (Index);
                  Enabled := Reading.Time_Enabled - Counters.Baseline_Enabled (Index);
                  Running := Reading.Time_Running - Counters.Baseline_Running (Index);
                  if Running = 0 then
                     Fail (Counters, Index, Counter_Resources_Unavailable);
                  else
                     Scale (Counted, Enabled, Running, Scaled, Fits);
                     if Fits then
                        Result (Index) := Scaled;
                     else
                        Fail (Counters, Index, Probe_Failed);
                     end if;
                  end if;
               end if;
            end;
         end if;
      end loop;
      Mask := Counters.Mask;
   end Finish;

   procedure Sample
     (Counters : in out Group;
      Result   : out Perf_Values;
      Enabled  : out Perf_Values;
      Running  : out Perf_Values;
      Status   : out Perf_Status_Values;
      Mask     : out Interfaces.Unsigned_64) is
   begin
      Result := [others => 0];
      Enabled := [others => 0];
      Running := [others => 0];
      for Index in Counter_Index loop
         Status (Index) := Counters.Outcome (Index);
         if Counters.Descriptor (Index) >= 0 then
            declare
               Reading : Counter_Reading;
               Outcome : Metric_Availability;
               Success : Boolean;
            begin
               Read_Counter (Counters.Descriptor (Index), Reading, Outcome, Success);
               if Success then
                  Result (Index) := Reading.Value;
                  Enabled (Index) := Reading.Time_Enabled;
                  Running (Index) := Reading.Time_Running;
               else
                  Fail (Counters, Index, Outcome);
                  Status (Index) := Counters.Outcome (Index);
               end if;
            end;
         end if;
      end loop;
      Mask := Counters.Mask;
   end Sample;

   procedure Close (Counters : in out Group) is
   begin
      for Index in Counter_Index loop
         if Counters.Descriptor (Index) >= 0 then
            Discard (Close_Descriptor (Counters.Descriptor (Index)));
            Counters.Descriptor (Index) := -1;
         end if;
      end loop;
      Counters.Mask := 0;
      Counters.Grouped := False;
   end Close;

   function Status (Counters : Group; Index : Counter_Index) return Metric_Availability
   is (Counters.Outcome (Index));

   overriding
   procedure Finalize (Object : in out Handle) is
   begin
      if Object.Initialized then
         Close (Object.Counters);
         Object.Initialized := False;
      end if;
   end Finalize;

end Flyology_Bench.Internal_Probes.Counters;
