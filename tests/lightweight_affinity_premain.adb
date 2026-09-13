with Flyology;
with Flyology.Execution_Groups;
with Flyology.IO;
with Interfaces;
with Interfaces.C;
with System;
with System.Multiprocessors;
with System.Multiprocessors.Dispatching_Domains;

package body Lightweight_Affinity_Premain is
   package Domains renames System.Multiprocessors.Dispatching_Domains;
   package Groups renames Flyology.Execution_Groups;

   use type Domains.CPU_Set;
   use type Interfaces.C.int;
   use type Groups.Group_Id;
   use type Groups.Loop_Thread_Placement;
   use type Groups.Placement_Configuration_Result;
   use type Groups.Placement_State;
   use type System.Multiprocessors.CPU_Range;

   type Affinity_Bytes is array (Positive range <>) of Interfaces.Unsigned_8;

   function Affinity_Size return Interfaces.C.size_t;
   pragma Import (C, Affinity_Size, "flyology_test_thread_affinity_size");

   function Removable_CPU return Interfaces.C.int;
   pragma
     Import (C, Removable_CPU, "flyology_test_thread_affinity_removable_cpu");

   function Observable_CPU return Interfaces.C.int;
   pragma
     Import
       (C, Observable_CPU, "flyology_test_thread_affinity_observable_cpu");

   function Snapshot_Affinity
     (Storage : System.Address; Size : Interfaces.C.size_t)
      return Interfaces.C.int;
   pragma
     Import (C, Snapshot_Affinity, "flyology_test_thread_affinity_snapshot");

   Target_CPU    : constant Interfaces.C.int := Removable_CPU;
   Placement_CPU : constant Interfaces.C.int := Observable_CPU;

   function Prepare_Placement return Boolean is
   begin
      if Target_CPU = 0 and then Placement_CPU = 0 then
         return True;
      elsif Target_CPU <= 0 or else Placement_CPU <= 0 then
         return False;
      end if;

      return
        Groups.Configure_Loop_Thread
          (Groups.Default_Group,
           Groups.Strict_CPU,
           Groups.Placement_Value (Placement_CPU - 1))
        = Groups.Configured;
   exception
      when others =>
         return False;
   end Prepare_Placement;

   Placement_Passed : constant Boolean := Prepare_Placement;

   protected Result is
      procedure Report_Bookkeeping (Passed : Boolean);
      procedure Report_Creation (Passed : Boolean);
      entry Wait
        (Bookkeeping_Passed : out Boolean; Creation_Passed : out Boolean);
   private
      Bookkeeping_Ready : Boolean := False;
      Creation_Ready    : Boolean := False;
      Bookkeeping_OK    : Boolean := False;
      Creation_OK       : Boolean := False;
   end Result;

   protected body Result is
      procedure Report_Bookkeeping (Passed : Boolean) is
      begin
         Bookkeeping_OK := Passed;
         Bookkeeping_Ready := True;
      end Report_Bookkeeping;

      procedure Report_Creation (Passed : Boolean) is
      begin
         Creation_OK := Passed;
         Creation_Ready := True;
      end Report_Creation;

      entry Wait
        (Bookkeeping_Passed : out Boolean; Creation_Passed : out Boolean)
        when Bookkeeping_Ready and Creation_Ready
      is
      begin
         Bookkeeping_Passed := Bookkeeping_OK;
         Creation_Passed := Creation_OK;
      end Wait;
   end Result;

   task Runner
     with CPU => 127 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Runner;

   task body Runner is
      function Exercise return Boolean is
         Before_CPU    : constant System.Multiprocessors.CPU_Range :=
           Domains.Get_CPU;
         Before_Domain : constant Domains.CPU_Set :=
           Domains.Get_CPU_Set (Domains.Get_Dispatching_Domain);
      begin
         Domains.Set_CPU (System.Multiprocessors.Not_A_Specific_CPU);
         return
           Domains.Get_CPU = Before_CPU
           and then Domains.Get_CPU_Set (Domains.Get_Dispatching_Domain)
                    = Before_Domain
           and then Flyology.IO.Is_Lightweight_Task
           and then Groups.Current = 127;
      exception
         when others =>
            return False;
      end Exercise;

      --  Task activation cannot complete until this initializer returns, so
      --  the binder has not yet frozen dispatching domains when it calls
      --  Set_CPU above.
      Passed : constant Boolean := Exercise;
   begin
      Result.Report_Bookkeeping (Passed);
   exception
      when others =>
         Result.Report_Bookkeeping (False);
   end Runner;

   task Domain_Runner is
      pragma Task_Info (Flyology.Lightweight_Task);

      entry Prepare_Domain_Creation (Passed : out Boolean);
      entry Check_Domain_Creation (Passed : out Boolean);
   end Domain_Runner;

   task body Domain_Runner is
      Size   : constant Interfaces.C.size_t := Affinity_Size;
      Before : Affinity_Bytes (1 .. Natural (Size));

      function Placement_Applied return Boolean is
         Status : constant Groups.Placement_Status :=
           Groups.Loop_Thread_Status (Groups.Default_Group);
      begin
         return
           Status.Kind = Groups.Strict_CPU
           and then Status.Value = Groups.Placement_Value (Placement_CPU - 1)
           and then Status.State = Groups.Applied;
      exception
         when others =>
            return False;
      end Placement_Applied;

      Before_Passed : constant Boolean :=
        Placement_Passed
        and then (Target_CPU = 0
                  or else (Placement_Applied
                           and then Snapshot_Affinity (Before'Address, Size)
                                    = 0));
   begin
      --  The first rendezvous completes activation but keeps this lightweight
      --  task registered while the environment task creates the domain.
      accept Prepare_Domain_Creation (Passed : out Boolean) do
         Passed := Before_Passed;
      end Prepare_Domain_Creation;

      accept Check_Domain_Creation (Passed : out Boolean) do
         if Target_CPU <= 0 then
            Passed := Target_CPU = 0;
         else
            declare
               After : Affinity_Bytes (Before'Range);
            begin
               Passed :=
                 Snapshot_Affinity (After'Address, Size) = 0
                 and then Before = After
                 and then Flyology.IO.Is_Lightweight_Task
                 and then Groups.Current = Groups.Default_Group
                 and then Placement_Applied;
            end;
         end if;
      end Check_Domain_Creation;
   end Domain_Runner;

   procedure Wait
     (Bookkeeping_Passed : out Boolean; Creation_Passed : out Boolean) is
   begin
      Result.Wait (Bookkeeping_Passed, Creation_Passed);
   end Wait;

   Before_Passed   : Boolean;
   Creation_Passed : Boolean := False;
begin
   Domain_Runner.Prepare_Domain_Creation (Before_Passed);

   if Before_Passed and then Target_CPU > 0 then
      begin
         declare
            Domain : Domains.Dispatching_Domain :=
              Domains.Create
                (System.Multiprocessors.CPU (Target_CPU),
                 System.Multiprocessors.CPU_Range (Target_CPU));
            pragma Unreferenced (Domain);
         begin
            Creation_Passed := True;
         end;
      exception
         when others =>
            Creation_Passed := False;
      end;
   else
      Creation_Passed := Before_Passed and then Target_CPU = 0;
   end if;

   declare
      Mask_Preserved : Boolean;
   begin
      Domain_Runner.Check_Domain_Creation (Mask_Preserved);
      Result.Report_Creation (Creation_Passed and then Mask_Preserved);
   end;
end Lightweight_Affinity_Premain;
