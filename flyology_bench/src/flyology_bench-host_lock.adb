--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology_Bench.Metadata;
with Interfaces;
with System;

package body Flyology_Bench.Host_Lock is
   use Ada.Strings.Unbounded;

   --  Open flags and flock operations are C macros, so the crate's native
   --  unit publishes their values as objects. Every call below is an
   --  ordinary libc entry point.
   Open_Read_Write    : constant Interfaces.C.int;
   pragma Import (C, Open_Read_Write, "flyology_bench_o_rdwr");
   Open_Create        : constant Interfaces.C.int;
   pragma Import (C, Open_Create, "flyology_bench_o_creat");
   Open_Close_On_Exec : constant Interfaces.C.int;
   pragma Import (C, Open_Close_On_Exec, "flyology_bench_o_cloexec");
   Open_No_Follow     : constant Interfaces.C.int;
   pragma Import (C, Open_No_Follow, "flyology_bench_o_nofollow");

   Lock_Shared      : constant Interfaces.C.int;
   pragma Import (C, Lock_Shared, "flyology_bench_lock_shared");
   Lock_Exclusive   : constant Interfaces.C.int;
   pragma Import (C, Lock_Exclusive, "flyology_bench_lock_exclusive");
   Lock_Nonblocking : constant Interfaces.C.int;
   pragma Import (C, Lock_Nonblocking, "flyology_bench_lock_nonblocking");
   Lock_Unlock      : constant Interfaces.C.int;
   pragma Import (C, Lock_Unlock, "flyology_bench_lock_unlock");

   function C_Flock (Descriptor : Interfaces.C.int; Operation : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Flock, "flock");

   function C_Close (Descriptor : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, C_Close, "close");

   function C_Process_Id return Interfaces.C.int;
   pragma Import (C, C_Process_Id, "getpid");

   --  open() is variadic. C_Variadic_2 marks the two fixed parameters, so
   --  GNAT emits the call sequence the platform ABI wants for the mode
   --  argument rather than the fixed-parameter one. Darwin on AArch64 passes
   --  variadic arguments on the stack while fixed ones go in registers, so a
   --  plain Convention => C import would deliver the wrong mode there.
   --  The convention compiles on every GNAT this crate supports; it was
   --  checked against 13.2.2 through 16.1.0, and alire.toml floors at 13.
   function C_Open
     (Path : Interfaces.C.char_array; Flags : Interfaces.C.int; Mode : Interfaces.C.unsigned)
      return Interfaces.C.int
   with Import, Convention => C_Variadic_2, External_Name => "open";

   --  mode_t is 32-bit on Linux and 16-bit on Darwin. The only value passed
   --  is 8#666#, which both ABIs carry in the low bits of one register.
   function C_Fchmod (Descriptor : Interfaces.C.int; Mode : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Fchmod, "fchmod");

   function C_Ftruncate
     (Descriptor : Interfaces.C.int; Length : Interfaces.Integer_64) return Interfaces.C.int;
   pragma Import (C, C_Ftruncate, "ftruncate");

   --  pwrite carries its own offset, so publishing never depends on where
   --  the descriptor's file position happens to be.
   function C_Pwrite
     (Descriptor : Interfaces.C.int;
      Buffer     : System.Address;
      Count      : Interfaces.C.size_t;
      Offset     : Interfaces.Integer_64) return Interfaces.Integer_64;
   pragma Import (C, C_Pwrite, "pwrite");

   Claim_File_Mode : constant Interfaces.C.unsigned := 8#666#;

   Content_Limit : constant := 4_096;

   function Trimmed (Value : String) return String
   is (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

   function Resolved_Path return String is
   begin
      if Ada.Environment_Variables.Exists (Override_Variable)
        and then Ada.Environment_Variables.Value (Override_Variable) /= ""
      then
         return Ada.Environment_Variables.Value (Override_Variable);
      elsif Ada.Environment_Variables.Exists (Convention_Variable)
        and then Ada.Environment_Variables.Value (Convention_Variable) /= ""
      then
         return Ada.Environment_Variables.Value (Convention_Variable);
      end if;
      return Default_Path;
   end Resolved_Path;

   --  Per-CPU claim files sit beside the machine file, so a claim on one
   --  logical CPU is visible to any tool that computes the same name.
   function CPU_Path (Machine : String; CPU : Natural) return String is
      Suffix : constant String := ".lock";
      Number : constant String := Trimmed (Natural'Image (CPU));
   begin
      if Machine'Length > Suffix'Length
        and then Machine (Machine'Last - Suffix'Length + 1 .. Machine'Last) = Suffix
      then
         return Machine (Machine'First .. Machine'Last - Suffix'Length) & "." & Number & Suffix;
      end if;
      return Machine & "." & Number;
   end CPU_Path;

   --  Only CR and LF can break the one-pair-per-line grammar. Percent itself
   --  is encoded so that the transformation stays reversible.
   function Encoded (Value : String) return String is
      Result : Unbounded_String;
   begin
      for Item of Value loop
         case Item is
            when ASCII.CR =>
               Append (Result, "%0D");

            when ASCII.LF =>
               Append (Result, "%0A");

            when '%'      =>
               Append (Result, "%25");

            when others   =>
               Append (Result, Item);
         end case;
      end loop;
      return To_String (Result);
   end Encoded;

   function Working_Directory return String is
   begin
      return Ada.Directories.Current_Directory;
   exception
      when others =>
         return "";
   end Working_Directory;

   function Acquisition_Timestamp return String is
      Result : String :=
        Ada.Calendar.Formatting.Image
          (Date => Ada.Calendar.Clock, Include_Time_Fraction => False, Time_Zone => 0);
   begin
      for Index in Result'Range loop
         if Result (Index) = ' ' then
            Result (Index) := 'T';
         end if;
      end loop;
      return Result & "Z";
   end Acquisition_Timestamp;

   function Claim_Description (CPUs : CPU_List) return String is
      Result : Unbounded_String;
   begin
      if CPUs'Length = 0 then
         return "all";
      end if;
      for Index in CPUs'Range loop
         if Length (Result) > 0 then
            Append (Result, ",");
         end if;
         Append (Result, Trimmed (Natural'Image (CPUs (Index))));
      end loop;
      return To_String (Result);
   end Claim_Description;

   function Content (Tool : String; CPUs : CPU_List) return String is
   begin
      return
        "convention="
        & Convention
        & ASCII.LF
        & "spec=https://github.com/flyology-ada/flyology/blob/main/docs/"
        & "host-cpu-lock.md"
        & ASCII.LF
        & "tool="
        & Encoded (Tool)
        & ASCII.LF
        & "pid="
        & Trimmed (Interfaces.C.int'Image (C_Process_Id))
        & ASCII.LF
        & "started="
        & Acquisition_Timestamp
        & ASCII.LF
        & "claim="
        & Claim_Description (CPUs)
        & ASCII.LF
        & "cwd="
        & Encoded (Working_Directory)
        & ASCII.LF;
   end Content;

   --  A restrictive umask in whichever process created the file first would
   --  otherwise lock every other user out of the convention, and being unable
   --  to open the file is indistinguishable from finding it free.
   function Open_Claim_File (Path : String) return Interfaces.C.int is
      use type Interfaces.C.unsigned;
      Flags      : constant Interfaces.C.int :=
        Interfaces.C.int
          (Interfaces.C.unsigned (Open_Read_Write)
           or Interfaces.C.unsigned (Open_Create)
           or Interfaces.C.unsigned (Open_Close_On_Exec)
           or Interfaces.C.unsigned (Open_No_Follow));
      Descriptor : constant Interfaces.C.int := C_Open (Interfaces.C.To_C (Path), Flags, Claim_File_Mode);
   begin
      if Descriptor >= 0 then
         declare
            Ignored : constant Interfaces.C.int := C_Fchmod (Descriptor, Claim_File_Mode);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      end if;
      return Descriptor;
   end Open_Claim_File;

   --  Failing to publish costs a diagnostic line, never the claim itself.
   procedure Publish (Descriptor : Interfaces.C.int; Text : String) is
      use type Interfaces.C.size_t;
      use type Interfaces.Integer_64;

      Buffer    : aliased Interfaces.C.char_array := Interfaces.C.To_C (Text);
      Remaining : Interfaces.C.size_t := Buffer'Length - 1;
      Offset    : Interfaces.Integer_64 := 0;
      Written   : Interfaces.Integer_64;
   begin
      if C_Ftruncate (Descriptor, 0) /= 0 then
         return;
      end if;
      while Remaining > 0 loop
         Written := C_Pwrite (Descriptor, Buffer (Interfaces.C.size_t (Offset))'Address, Remaining, Offset);
         exit when Written <= 0;
         Remaining := Remaining - Interfaces.C.size_t (Written);
         Offset := Offset + Written;
      end loop;
   end Publish;

   --  Whitespace-separated field of a /proc line, one-based.
   function Field (Line : String; Index : Positive) return String is
      First   : Natural := Line'First;
      Current : Natural := 0;
   begin
      while First <= Line'Last loop
         while First <= Line'Last and then Line (First) = ' ' loop
            First := First + 1;
         end loop;
         exit when First > Line'Last;
         declare
            Last : Natural := First;
         begin
            while Last < Line'Last and then Line (Last + 1) /= ' ' loop
               Last := Last + 1;
            end loop;
            Current := Current + 1;
            if Current = Index then
               return Line (First .. Last);
            end if;
            First := Last + 2;
         end;
      end loop;
      return "";
   end Field;

   function Covers (Mount_Point : String; Path : String) return Boolean is
   begin
      if Mount_Point = "/" then
         return True;
      elsif Mount_Point'Length = 0 or else Mount_Point'Length > Path'Length then
         return False;
      elsif Path (Path'First .. Path'First + Mount_Point'Length - 1) /= Mount_Point then
         return False;
      end if;
      return Path'Length = Mount_Point'Length or else Path (Path'First + Mount_Point'Length) = '/';
   end Covers;

   --  A mount whose root is a subtree rather than "/" is a bind mount of part
   --  of some filesystem. systemd PrivateTmp= produces exactly this, with a
   --  root of /systemd-private-<hex>-<service>-<jumble>/tmp.
   function Detect_Isolation (Path : String) return Path_Isolation is
      File        : Ada.Text_IO.File_Type;
      Best_Root   : Unbounded_String;
      Best_Length : Natural := 0;
      Found       : Boolean := False;
   begin
      --  Mount points are absolute, so a relative claim path cannot be
      --  resolved against them. Answering from the root mount instead would
      --  describe the wrong filesystem, and Require_Machine_Scope would then
      --  accept a claim whose scope was never established.
      if Path'Length = 0 or else Path (Path'First) /= '/' then
         return Isolation_Unknown;
      end if;
      --  Darwin has no mount namespaces, so the path is not privately bound.
      --  That is still not proof that it is machine-wide.
      if Flyology_Bench.Metadata.Operating_System = "darwin" then
         return Isolation_Not_Detected;
      end if;
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "/proc/self/mountinfo");
      exception
         when others =>
            return Isolation_Unknown;
      end;
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            --  mount id, parent id, major:minor, root, mount point, ...
            Line  : constant String := Ada.Text_IO.Get_Line (File);
            Root  : constant String := Field (Line, 4);
            Point : constant String := Field (Line, 5);
         begin
            if Root'Length > 0
              and then Point'Length > 0
              and then Covers (Point, Path)
              and then Point'Length >= Best_Length
            then
               Best_Length := Point'Length;
               Best_Root := To_Unbounded_String (Root);
               Found := True;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      if not Found then
         return Isolation_Unknown;
      elsif To_String (Best_Root) /= "/" then
         return Private_Namespace;
      end if;
      return Isolation_Not_Detected;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return Isolation_Unknown;
   end Detect_Isolation;

   procedure Release (Object : in out Claim) is
      Ignored : Interfaces.C.int;
   begin
      for Index in reverse 1 .. Object.CPU_Total loop
         Ignored := C_Flock (Object.CPU_Descriptors (Index), Lock_Unlock);
         Ignored := C_Close (Object.CPU_Descriptors (Index));
         Object.CPU_Descriptors (Index) := -1;
      end loop;
      Object.CPU_Total := 0;
      if Object.Machine_Descriptor >= 0 then
         Ignored := C_Flock (Object.Machine_Descriptor, Lock_Unlock);
         Ignored := C_Close (Object.Machine_Descriptor);
         Object.Machine_Descriptor := -1;
      end if;
      Object.Held_Value := False;
   end Release;

   overriding
   procedure Finalize (Object : in out Claim) is
   begin
      Release (Object);
   end Finalize;

   --  flock reports conflict and genuine failure the same way, and a caller
   --  that retries treats them the same way too.
   function Locked (Descriptor : Interfaces.C.int; Exclusive : Boolean) return Boolean is
      use type Interfaces.C.unsigned;
      Operation : constant Interfaces.C.int :=
        Interfaces.C.int
          (Interfaces.C.unsigned (if Exclusive then Lock_Exclusive else Lock_Shared)
           or Interfaces.C.unsigned (Lock_Nonblocking));
   begin
      return C_Flock (Descriptor, Operation) = 0;
   end Locked;

   procedure Try_Acquire
     (Object  : in out Claim;
      Outcome : out Acquisition;
      CPUs    : CPU_List := Whole_Machine;
      Path    : String := "";
      Tool    : String := "flyology_bench")
   is
      Machine : constant String := (if Path = "" then Resolved_Path else Path);
      Ordered : CPU_List (1 .. CPUs'Length);
   begin
      if Object.Held_Value then
         raise Program_Error with "host CPU claim is already held";
      elsif CPUs'Length > Maximum_Claimed_CPUs then
         raise Program_Error with "host CPU claim names more logical CPUs than the convention allows";
      end if;
      Outcome := Path_Unusable;
      Object.Path_Value := To_Unbounded_String (Machine);

      Ordered := CPUs;
      --  Ascending order is what stops two callers claiming overlapping sets
      --  from deadlocking against each other's partial claims.
      for Outer in Ordered'Range loop
         for Inner in Outer + 1 .. Ordered'Last loop
            if Ordered (Inner) < Ordered (Outer) then
               declare
                  Saved : constant Natural := Ordered (Outer);
               begin
                  Ordered (Outer) := Ordered (Inner);
                  Ordered (Inner) := Saved;
               end;
            end if;
         end loop;
      end loop;

      Object.Machine_Descriptor := Open_Claim_File (Machine);
      if Object.Machine_Descriptor < 0 then
         return;
      end if;
      Object.Isolation_Value := Detect_Isolation (Machine);

      if not Locked (Object.Machine_Descriptor, CPUs'Length = 0) then
         Outcome := Busy;
         Release (Object);
         return;
      end if;

      for Index in Ordered'Range loop
         declare
            Descriptor : constant Interfaces.C.int := Open_Claim_File (CPU_Path (Machine, Ordered (Index)));
         begin
            if Descriptor < 0 then
               Outcome := Path_Unusable;
               Release (Object);
               return;
            end if;
            Object.CPU_Descriptors (Index) := Descriptor;
            Object.CPU_Total := Index;
            if not Locked (Descriptor, True) then
               Outcome := Busy;
               Release (Object);
               return;
            end if;
         end;
      end loop;

      Object.Held_Value := True;
      Outcome := Acquired;

      --  Content is published after the claim is taken, so a reader can
      --  observe an empty file in the window between the two.
      declare
         Text : constant String := Content (Tool, Ordered);
      begin
         Publish (Object.Machine_Descriptor, Text);
         for Index in 1 .. Object.CPU_Total loop
            Publish (Object.CPU_Descriptors (Index), Text);
         end loop;
      end;
   end Try_Acquire;

   procedure Acquire
     (Object        : in out Claim;
      Outcome       : out Acquisition;
      CPUs          : CPU_List := Whole_Machine;
      Path          : String := "";
      Tool          : String := "flyology_bench";
      Timeout       : Duration := 30.0;
      Poll_Interval : Duration := 0.250)
   is
      Waited : Duration := 0.0;
      Step   : constant Duration := Duration'Max (0.001, Poll_Interval);
   begin
      loop
         Try_Acquire (Object, Outcome, CPUs, Path, Tool);
         exit when Outcome /= Busy;
         exit when Waited >= Timeout;
         --  Waiting must be idle: a spinning waiter would itself become the
         --  competing load it is waiting out.
         delay Duration'Min (Step, Duration'Max (0.0, Timeout - Waited));
         Waited := Waited + Step;
      end loop;
   end Acquire;

   function Held (Object : Claim) return Boolean
   is (Object.Held_Value);

   function Isolation (Object : Claim) return Path_Isolation
   is (Object.Isolation_Value);

   function Claim_Path (Object : Claim) return String
   is (To_String (Object.Path_Value));

   function Read_Holder (Path : String := "") return Holder is
      Target : constant String := (if Path = "" then Resolved_Path else Path);
      File   : Ada.Text_IO.File_Type;
      Result : Holder;
      Read   : Natural := 0;
   begin
      --  Deliberately unlocked. Taking a shared lock here would block behind
      --  the holder, which is the one process the reader is trying to name.
      --  The content is therefore allowed to be empty, stale, or truncated,
      --  and only the convention's own keys are ever extracted.
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Target);
      exception
         when others =>
            return Result;
      end;
      while not Ada.Text_IO.End_Of_File (File) and then Read < Content_Limit loop
         declare
            Line      : constant String := Ada.Text_IO.Get_Line (File);
            Separator : Natural := 0;
         begin
            Read := Read + Line'Length + 1;
            Result.Available := True;
            for Index in Line'Range loop
               if Line (Index) = '=' then
                  Separator := Index;
                  exit;
               end if;
            end loop;
            if Separator > 0 then
               declare
                  Key   : constant String := Line (Line'First .. Separator - 1);
                  Value : constant String := Line (Separator + 1 .. Line'Last);
               begin
                  --  Unknown keys are ignored so that a later revision of the
                  --  convention stays readable by this parser.
                  if Key = "convention" then
                     Result.Convention_Id := To_Unbounded_String (Value);
                  elsif Key = "tool" then
                     Result.Tool := To_Unbounded_String (Value);
                  elsif Key = "pid" then
                     Result.Process_Id := To_Unbounded_String (Value);
                  elsif Key = "started" then
                     Result.Started := To_Unbounded_String (Value);
                  elsif Key = "claim" then
                     Result.Claim := To_Unbounded_String (Value);
                  elsif Key = "cwd" then
                     Result.Working_Directory := To_Unbounded_String (Value);
                  end if;
               end;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      return Result;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return Result;
   end Read_Holder;
end Flyology_Bench.Host_Lock;
