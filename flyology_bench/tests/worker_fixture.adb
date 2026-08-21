--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology_Bench;
with Flyology_Bench.Workers;
with Flyology_Bench.Workers.Test_Support;
with Interfaces;
with Interfaces.C;
with System;

procedure Worker_Fixture is
   package C renames Interfaces.C;
   use type C.int;
   use type C.long;
   use type Flyology_Bench.Workers.Result_Kind;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Counter : Natural := 0 with Volatile;

   procedure Operation is
   begin
      Counter := Counter + 1;
   end Operation;

   procedure Contender is
   begin
      Counter := Counter + 1;
      Counter := Counter + 1;
   end Contender;

   procedure Measure_One is new Flyology_Bench.Measure (Operation);
   procedure Compare_One is new Flyology_Bench.Compare
     (Reference_Operation => Operation,
      Contender_Operation => Contender);

   procedure Abort_Process;
   pragma Import
     (C, Abort_Process, "flyology_bench_worker_test_abort");

   function Ignore_Terminate return C.int;
   pragma Import
     (C, Ignore_Terminate,
      "flyology_bench_worker_test_ignore_terminate");

   function Descriptor_Open (Descriptor : C.int) return C.int;
   pragma Import
     (C, Descriptor_Open,
      "flyology_bench_worker_test_descriptor_open");

   function Getpid return C.int;
   pragma Import (C, Getpid, "getpid");

   function Spawn_Stubborn_Descendant return C.int;
   pragma Import
     (C, Spawn_Stubborn_Descendant,
      "flyology_bench_worker_test_spawn_stubborn_descendant");

   function C_Write
     (Descriptor : C.int;
      Data       : System.Address;
      Length     : C.size_t) return C.long;
   pragma Import (C, C_Write, "write");

   procedure Put_U8
     (Data : in out Ada.Strings.Unbounded.Unbounded_String;
      Value : Natural) is
   begin
      Ada.Strings.Unbounded.Append (Data, Character'Val (Value mod 256));
   end Put_U8;

   procedure Put_U32
     (Data : in out Ada.Strings.Unbounded.Unbounded_String;
      Value : Interfaces.Unsigned_32) is
   begin
      for Shift in reverse 0 .. 3 loop
         Put_U8
           (Data, Natural
              (Interfaces.Shift_Right (Value, Shift * 8) and 16#FF#));
      end loop;
   end Put_U32;

   procedure Put_U64
     (Data : in out Ada.Strings.Unbounded.Unbounded_String;
      Value : Interfaces.Unsigned_64) is
   begin
      for Shift in reverse 0 .. 7 loop
         Put_U8
           (Data, Natural
              (Interfaces.Shift_Right (Value, Shift * 8) and 16#FF#));
      end loop;
   end Put_U64;

   procedure Put_String
     (Data : in out Ada.Strings.Unbounded.Unbounded_String;
      Value : String) is
   begin
      Put_U32 (Data, Interfaces.Unsigned_32 (Value'Length));
      Ada.Strings.Unbounded.Append (Data, Value);
   end Put_String;

   procedure Write_Raw (Value : String) is
      Ignored : constant C.long :=
        C_Write (3, Value'Address, C.size_t (Value'Length));
      pragma Unreferenced (Ignored);
   begin
      null;
   end Write_Raw;

   procedure Flood_Output is
      Chunk : aliased constant String (1 .. 8_192) := [others => 'x'];
      Wrote : C.long;
   begin
      loop
         Wrote := C_Write (1, Chunk'Address, C.size_t (Chunk'Length));
         if Wrote < 0 then
            return;
         end if;
      end loop;
   end Flood_Output;

   Request : Flyology_Bench.Workers.Worker_Request;
   Config  : Flyology_Bench.Configuration;
   Name    : Ada.Strings.Unbounded.Unbounded_String;
begin
   if not Flyology_Bench.Workers.Worker_Mode then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Request := Flyology_Bench.Workers.Current_Request;
   Config := Flyology_Bench.Workers.Requested_Configuration (Request);
   Name := Ada.Strings.Unbounded.To_Unbounded_String
     (Flyology_Bench.Workers.Requested_Identity (Request));

   if Ada.Strings.Unbounded.To_String (Name) = "startup-timeout" then
      delay 0.250;
   end if;
   if Ada.Strings.Unbounded.To_String (Name) = "malformed"
     or else Ada.Strings.Unbounded.To_String (Name) = "truncated"
   then
      Write_Raw
        ((if Ada.Strings.Unbounded.To_String (Name) = "truncated"
          then "FLYBWRK1" else "not-a-worker-envelope"));
      return;
   elsif Ada.Strings.Unbounded.To_String (Name) = "wrong-version" then
      declare
         Data : Ada.Strings.Unbounded.Unbounded_String;
      begin
         Ada.Strings.Unbounded.Append (Data, "FLYBWRK1");
         Put_U32
           (Data,
            Interfaces.Unsigned_32
              (Flyology_Bench.Workers.Protocol_Version + 1));
         Put_U32 (Data, 1);
         Put_U32 (Data, 0);
         Write_Raw (Ada.Strings.Unbounded.To_String (Data));
         return;
      end;
   elsif Ada.Strings.Unbounded.To_String (Name) = "oversized" then
      declare
         Data : Ada.Strings.Unbounded.Unbounded_String;
      begin
         Ada.Strings.Unbounded.Append (Data, "FLYBWRK1");
         Put_U32 (Data, 1);
         Put_U32 (Data, 1);
         Put_U32 (Data, 4 * 1_024 * 1_024 + 1);
         Write_Raw (Ada.Strings.Unbounded.To_String (Data));
         return;
      end;
   elsif Ada.Strings.Unbounded.To_String (Name) = "wrong-identity" then
      declare
         Data, Frame : Ada.Strings.Unbounded.Unbounded_String;
      begin
         Put_String (Data, "different-case");
         Put_U64 (Data, 0);
         Put_U64 (Data, 1);
         for Index in 1 .. 5 loop
            Put_U64 (Data, 0);
         end loop;
         Put_U64 (Data, 16#C0DE_F17E_BA5E_0001#);
         Ada.Strings.Unbounded.Append (Frame, "FLYBWRK1");
         Put_U32 (Frame, 1);
         Put_U32 (Frame, 1);
         Put_U32
           (Frame, Interfaces.Unsigned_32 (Ada.Strings.Unbounded.Length (Data)));
         Ada.Strings.Unbounded.Append
           (Frame, Ada.Strings.Unbounded.To_String (Data));
         Write_Raw (Ada.Strings.Unbounded.To_String (Frame));
         return;
      end;
   end if;
   Flyology_Bench.Workers.Announce_Ready (Request);

   if Ada.Strings.Unbounded.To_String (Name) = "long-exception" then
      Flyology_Bench.Workers.Return_Benchmark_Exception
        (Request, "fixture", String'(1 .. 20_000 => 'm'));
      return;
   elsif Ada.Strings.Unbounded.To_String (Name) = "nonzero" then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   elsif Ada.Strings.Unbounded.To_String (Name) = "invalid" then
      Flyology_Bench.Workers.Return_Invalid_Configuration
        (Request, "fixture invalid configuration");
      return;
   elsif Ada.Strings.Unbounded.To_String (Name) = "abort" then
      Abort_Process;
   elsif Ada.Strings.Unbounded.To_String (Name) = "timeout" then
      if Ignore_Terminate /= 0 then
         raise Program_Error with "cannot ignore SIGTERM";
      end if;
      loop
         delay 1.0;
      end loop;
   elsif Ada.Strings.Unbounded.To_String (Name) = "exception" then
      raise Constraint_Error with "fixture benchmark exception";
   elsif Ada.Strings.Unbounded.To_String (Name) = "diagnostics" then
      for Index in 1 .. 100 loop
         Ada.Text_IO.Put (String'(1 .. 1_000 => 'x'));
      end loop;
   elsif Ada.Strings.Unbounded.To_String (Name) = "diagnostics-timeout" then
      Flood_Output;
      return;
   elsif Ada.Strings.Unbounded.To_String (Name) = "parent-abort" then
      declare
         File : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create
           (File, Ada.Text_IO.Out_File,
            Ada.Environment_Variables.Value ("WORKER_PID_FILE"));
         Ada.Text_IO.Put_Line (File, C.int'Image (Getpid));
         Ada.Text_IO.Close (File);
      end;
      loop
         delay 1.0;
      end loop;
   elsif Ada.Strings.Unbounded.To_String (Name) = "descendant-timeout" then
      declare
         Descendant : constant C.int := Spawn_Stubborn_Descendant;
         File : Ada.Text_IO.File_Type;
      begin
         if Descendant <= 0 then
            raise Program_Error with "cannot spawn descendant fixture";
         elsif Ignore_Terminate /= 0 then
            raise Program_Error with "cannot ignore SIGTERM";
         end if;
         Ada.Text_IO.Create
           (File, Ada.Text_IO.Out_File,
            Ada.Environment_Variables.Value ("DESCENDANT_PID_FILE"));
         Ada.Text_IO.Put_Line (File, C.int'Image (Descendant));
         Ada.Text_IO.Close (File);
      end;
      loop
         delay 1.0;
      end loop;
   elsif Ada.Strings.Unbounded.To_String (Name) = "environment" then
      Ada.Text_IO.Put_Line
        ("KEEP=" & Ada.Environment_Variables.Value ("KEEP", "<missing>"));
      Ada.Text_IO.Put_Line
        ("SECRET=" & Ada.Environment_Variables.Value ("WORKER_SECRET", "<missing>"));
      Ada.Text_IO.Put_Line ("CWD=" & Ada.Directories.Current_Directory);
   elsif Ada.Strings.Unbounded.To_String (Name) = "descriptor" then
      declare
         FD : constant C.int := C.int'Value
           (Ada.Environment_Variables.Value ("TEST_FD"));
      begin
         if Descriptor_Open (FD) /= 0 then
            raise Program_Error with "unintended descriptor survived exec";
         end if;
      end;
   end if;

   if Flyology_Bench.Workers.Requested_Kind (Request)
     = Flyology_Bench.Workers.Ordinary_Measurement
   then
      declare
         Result : Flyology_Bench.Measurement;
      begin
         if Ada.Strings.Unbounded.To_String (Name) = "wrong-result-seed" then
            Config.Random_Seed := Config.Random_Seed + 1;
         end if;
         Measure_One (Config, Result);
         if Ada.Strings.Unbounded.To_String (Name) = "wrong-metrics" then
            Flyology_Bench.Workers.Test_Support.Corrupt_Metric_Request
              (Result);
         elsif Ada.Strings.Unbounded.To_String (Name) = "wrong-statistics" then
            Flyology_Bench.Workers.Test_Support.Corrupt_Statistics (Result);
         elsif Ada.Strings.Unbounded.To_String (Name)
           = "wrong-environment-report"
         then
            Flyology_Bench.Workers.Test_Support.Corrupt_Environment_Report
              (Result);
         end if;
         Flyology_Bench.Workers.Return_Result (Request, Result);
         if Ada.Strings.Unbounded.To_String (Name) = "trailing" then
            Write_Raw ("x");
         end if;
      end;
   else
      declare
         Result : Flyology_Bench.Comparison;
      begin
         Compare_One (Config, Result);
         if Ada.Strings.Unbounded.To_String (Name) = "wrong-counts" then
            Flyology_Bench.Workers.Test_Support.Corrupt_Comparison_Counts
              (Result);
         elsif Ada.Strings.Unbounded.To_String (Name)
           = "wrong-comparison-statistics"
         then
            Flyology_Bench.Workers.Test_Support.Corrupt_Comparison_Statistics
              (Result);
         end if;
         Flyology_Bench.Workers.Return_Result (Request, Result);
      end;
   end if;
exception
   when Error : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Ada.Exceptions.Exception_Name (Error) & ": "
         & Ada.Exceptions.Exception_Message (Error));
      Flyology_Bench.Workers.Return_Benchmark_Exception
        (Request,
         Ada.Exceptions.Exception_Name (Error),
         Ada.Exceptions.Exception_Message (Error));
end Worker_Fixture;
