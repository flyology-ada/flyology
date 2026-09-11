with Ada.Text_IO;

with Flyology;
with Flyology.Execution_Groups;
with Flyology.IO;
with Interfaces;
with Interfaces.C;
with System;
with System.Multiprocessors;
with System.Multiprocessors.Dispatching_Domains;

procedure Lightweight_Affinity_Smoke is
   package Domains renames System.Multiprocessors.Dispatching_Domains;
   package Groups renames Flyology.Execution_Groups;

   use type Interfaces.C.int;
   use type Groups.Group_Id;

   type Affinity_Bytes is array (Positive range <>) of Interfaces.Unsigned_8;

   function Affinity_Size return Interfaces.C.size_t;
   pragma Import (C, Affinity_Size, "flyology_test_thread_affinity_size");

   function Observable_CPU return Interfaces.C.int;
   pragma
     Import
       (C, Observable_CPU, "flyology_test_thread_affinity_observable_cpu");

   function Snapshot_Affinity
     (Storage : System.Address; Size : Interfaces.C.size_t)
      return Interfaces.C.int;
   pragma
     Import (C, Snapshot_Affinity, "flyology_test_thread_affinity_snapshot");

   protected Result is
      procedure Report (Passed : Boolean);
      entry Wait (Passed : out Boolean);
   private
      Ready : Boolean := False;
      OK    : Boolean := False;
   end Result;

   protected body Result is
      procedure Report (Passed : Boolean) is
      begin
         OK := Passed;
         Ready := True;
      end Report;

      entry Wait (Passed : out Boolean) when Ready is
      begin
         Passed := OK;
      end Wait;
   end Result;

   task Runner
     with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Runner;

   task body Runner is
      Size : constant Interfaces.C.size_t := Affinity_Size;
      CPU  : constant Interfaces.C.int := Observable_CPU;
   begin
      if CPU < 0 then
         Result.Report (False);
      elsif CPU = 0 then
         Ada.Text_IO.Put_Line
           ("lightweight affinity smoke skipped: fewer than two allowed CPUs");
         Result.Report (True);
      else
         declare
            Before : Affinity_Bytes (1 .. Natural (Size));
            After  : Affinity_Bytes (Before'Range);
         begin
            if Snapshot_Affinity (Before'Address, Size) /= 0 then
               Result.Report (False);
            else
               Domains.Set_CPU (System.Multiprocessors.CPU_Range (CPU));
               Result.Report
                 (Snapshot_Affinity (After'Address, Size) = 0
                  and then Before = After
                  and then Flyology.IO.Is_Lightweight_Task
                  and then Groups.Current = 1);
            end if;
         end;
      end if;
   exception
      when others =>
         Result.Report (False);
   end Runner;

   Passed : Boolean;
begin
   Result.Wait (Passed);
   if not Passed then
      raise Program_Error
        with "lightweight affinity changed the shared event-loop pthread mask";
   end if;
end Lightweight_Affinity_Smoke;
