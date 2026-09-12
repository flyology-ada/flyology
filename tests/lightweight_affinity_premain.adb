with Flyology;
with Flyology.Execution_Groups;
with Flyology.IO;
with System.Multiprocessors;
with System.Multiprocessors.Dispatching_Domains;

package body Lightweight_Affinity_Premain is
   package Domains renames System.Multiprocessors.Dispatching_Domains;
   package Groups renames Flyology.Execution_Groups;

   use type Domains.CPU_Set;
   use type Groups.Group_Id;
   use type System.Multiprocessors.CPU_Range;

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
      Result.Report (Passed);
   exception
      when others =>
         Result.Report (False);
   end Runner;

   procedure Wait (Passed : out Boolean) is
   begin
      Result.Wait (Passed);
   end Wait;
end Lightweight_Affinity_Premain;
