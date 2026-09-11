with Flyology;
with Flyology.Execution_Groups;
with Flyology.IO;
with System.Multiprocessors;
with System.Multiprocessors.Dispatching_Domains;

procedure Lightweight_Affinity_Smoke is
   package Domains renames System.Multiprocessors.Dispatching_Domains;
   package Groups renames Flyology.Execution_Groups;

   use type Groups.Group_Id;

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
   begin
      Domains.Set_CPU (System.Multiprocessors.Not_A_Specific_CPU);
      Result.Report
        (Flyology.IO.Is_Lightweight_Task and then Groups.Current = 1);
   exception
      when others =>
         Result.Report (False);
   end Runner;

   Passed : Boolean;
begin
   Result.Wait (Passed);
   if not Passed then
      raise Program_Error
        with "lightweight affinity reached the shared event-loop pthread";
   end if;
end Lightweight_Affinity_Smoke;
