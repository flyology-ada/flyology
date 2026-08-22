with Flyology;
with Flyology.Execution_Groups;

procedure Loop_Thread_Project_Placement_Smoke is
   package Groups renames Flyology.Execution_Groups;

   use type Groups.Group_Id;
   use type Groups.Loop_Thread_Placement;
   use type Groups.Placement_State;

   Project_Group : constant Groups.Group_Id := 6;
   Before        : constant Groups.Placement_Status := Groups.Loop_Thread_Status (Project_Group);

   protected Result is
      procedure Set (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Result;

   protected body Result is
      procedure Set (Passed : Boolean) is
      begin
         OK := Passed;
         Done := True;
      end Set;
      entry Wait when Done is
      begin
         null;
      end Wait;
      function Passed return Boolean
      is (OK);
   end Result;

   task Project_Worker
     with CPU => 6 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Project_Worker;

   task body Project_Worker is
   begin
      Result.Set
        (Groups.Current = Project_Group
         and then (if Before.Kind = Groups.Strict_CPU
                   then Groups.Current_Processor = Integer (Before.Value)
                   else Groups.Current_Processor = Groups.No_Processor));
   exception
      when others =>
         Result.Set (False);
   end Project_Worker;

   After : Groups.Placement_Status;
begin
   if Before.State /= Groups.Pending_Startup or else Before.Kind = Groups.No_Placement then
      raise Program_Error with "project placement was not compiled into RTS";
   end if;
   Result.Wait;
   After := Groups.Loop_Thread_Status (Project_Group);
   if not Result.Passed
     or else After.Kind /= Before.Kind
     or else After.Value /= Before.Value
     or else After.State /= Groups.Applied
   then
      raise Program_Error with "project loop placement was not applied";
   end if;
end Loop_Thread_Project_Placement_Smoke;
