with Fault_Control;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.Execution_Groups.Topology;
with Flyology.Observability;

procedure Pool_Reduction_Cross_To_Shard_Smoke is
   package Groups renames Flyology.Execution_Groups;
   package Topology renames Flyology.Execution_Groups.Topology;
   package Observe renames Flyology.Observability;

   use type Groups.Group_Id;
   use type Groups.Pool_Reduction_Request_Result;

   Target_Size : constant Groups.Loop_Pool_Size := 1;
   Grown_Size  : constant Groups.Loop_Pool_Size := 3;
   Target      : constant Topology.Shard_Id := 2;

   protected Coordination is
      procedure Report (Was_Rejected : Boolean; Final_Group : Groups.Group_Id);
      entry Wait_For_Report;
      entry Wait_For_Release;
      procedure Release;
      function Rejected return Boolean;
      function Group return Groups.Group_Id;
   private
      Reported       : Boolean := False;
      Released       : Boolean := False;
      Cross_Rejected : Boolean := False;
      Result_Group   : Groups.Group_Id := Groups.Default_Group;
   end Coordination;

   protected body Coordination is
      procedure Report (Was_Rejected : Boolean; Final_Group : Groups.Group_Id) is
      begin
         Cross_Rejected := Was_Rejected;
         Result_Group := Final_Group;
         Reported := True;
      end Report;

      entry Wait_For_Report when Reported is
      begin
         null;
      end Wait_For_Report;

      entry Wait_For_Release when Released is
      begin
         null;
      end Wait_For_Release;

      procedure Release is
      begin
         Released := True;
      end Release;

      function Rejected return Boolean
      is (Cross_Rejected);

      function Group return Groups.Group_Id
      is (Result_Group);
   end Coordination;

   task type Crossing_Task is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Crossing_Task;

   task body Crossing_Task is
      Was_Rejected : Boolean := False;
   begin
      begin
         Topology.Cross_To_Shard (Target);
      exception
         when Groups.Migration_Error =>
            Was_Rejected := True;
      end;
      Coordination.Report (Was_Rejected, Groups.Current);
      Coordination.Wait_For_Release;
   end Crossing_Task;

   Status   : Groups.Pool_Reduction_Status;
   Snapshot : Observe.Group_Snapshot;
   Parked   : Boolean := False;
begin
   if not Fault_Control.Enabled then
      raise Program_Error with "pool reduction crossing test requires FLYOLOGY_TEST_FAULTS=1 runtime";
   end if;

   Groups.Grow_Configured_Pool (Grown_Size);
   Fault_Control.Reset;
   Fault_Control.Arm (Fault_Control.Cross_To_Shard_Window, Count => 1_000_000);
   declare
      Worker : Crossing_Task;
      pragma Unreferenced (Worker);
   begin
      begin
         for Attempt in 1 .. 5_000 loop
            Parked := Fault_Control.Calls (Fault_Control.Cross_To_Shard_Window) /= 0;
            exit when Parked;
            delay 0.001;
         end loop;
         if not Parked then
            raise Program_Error with "crossing task never reached the migration window";
         end if;
         if not Observe.Snapshot (Target, Snapshot) then
            raise Program_Error with "crossing task paused before target preparation";
         end if;

         if Groups.Request_Pool_Reduction (Target_Size) /= Groups.Reduction_Started then
            raise Program_Error with "concurrent pool reduction did not start";
         end if;
         Fault_Control.Disarm (Fault_Control.Cross_To_Shard_Window);
         Coordination.Wait_For_Report;

         Status := Groups.Pool_Reduction;
         if not Coordination.Rejected
           or else Coordination.Group /= Groups.Default_Group
           or else Status.Explicit_Tasks /= 0
         then
            Coordination.Release;
            raise Program_Error
              with
                "stale shard crossing survived reduction: rejected="
                & Boolean'Image (Coordination.Rejected)
                & " group="
                & Groups.Group_Id'Image (Coordination.Group)
                & " explicit="
                & Natural'Image (Status.Explicit_Tasks);
         end if;
         Coordination.Release;
      exception
         when others =>
            Fault_Control.Disarm (Fault_Control.Cross_To_Shard_Window);
            Coordination.Release;
            raise;
      end;
   end;
exception
   when others =>
      Fault_Control.Disarm (Fault_Control.Cross_To_Shard_Window);
      Coordination.Release;
      raise;
end Pool_Reduction_Cross_To_Shard_Smoke;
