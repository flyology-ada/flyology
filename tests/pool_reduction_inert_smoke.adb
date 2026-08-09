with Flyology;
with Flyology.Execution_Groups;
with Flyology.Observability;
with Flyology.Process_Lifecycle;

procedure Pool_Reduction_Inert_Smoke is
   package Groups renames Flyology.Execution_Groups;
   package Lifecycle renames Flyology.Process_Lifecycle;

   use type Groups.Group_Id;
   use type Groups.Pool_Reduction_Phase;
   use type Groups.Pool_Reduction_Request_Result;
   use type Lifecycle.Event_Runtime_State;

   Initial_Size : constant Groups.Loop_Pool_Size := 3;
   Target_Size  : constant Groups.Loop_Pool_Size := 1;

   protected Control is
      procedure Report (Group : Groups.Group_Id);
      entry Wait_Ready;
      entry Hold;
      procedure Release;
      function Passed return Boolean;
   private
      Ready    : Boolean := False;
      Released : Boolean := False;
      Correct  : Boolean := False;
   end Control;

   protected body Control is
      procedure Report (Group : Groups.Group_Id) is
      begin
         Correct := Group = 2;
         Ready := True;
      end Report;

      entry Wait_Ready when Ready is
      begin
         null;
      end Wait_Ready;

      entry Hold when Released is
      begin
         null;
      end Hold;

      procedure Release is
      begin
         Released := True;
      end Release;

      function Passed return Boolean is (Correct);
   end Control;

   task type Explicit_Worker with CPU => 2 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Explicit_Worker;

   task body Explicit_Worker is
   begin
      Control.Report (Groups.Current);
      Control.Hold;
   end Explicit_Worker;

   type Explicit_Access is access Explicit_Worker;

   Status : Groups.Pool_Reduction_Status;
   Sample : Flyology.Observability.Group_Snapshot;
begin
   if Groups.Configured_Pool_Size /= Initial_Size
     or else Lifecycle.State /= Lifecycle.Dormant
     or else Lifecycle.Created_Groups /= 0
   then
      raise Program_Error with "pool reduction inertness precondition failed";
   end if;

   if Groups.Request_Pool_Reduction (Target_Size) /= Groups.Reduction_Started
   then
      raise Program_Error with "dormant reduction did not start";
   end if;
   Status := Groups.Pool_Reduction;
   if Status.Phase /= Groups.Drained
     or else Status.Target_Size /= Target_Size
     or else Status.Automatic_Tasks /= 0
     or else Status.Placement_Claims /= 0
     or else Lifecycle.State /= Lifecycle.Dormant
     or else Lifecycle.Created_Groups /= 0
     or else Flyology.Observability.Snapshot
       (Groups.Default_Group, Sample)
   then
      raise Program_Error with "dormant reduction started event machinery";
   end if;

   Groups.Grow_Configured_Pool (Initial_Size);
   declare
      Worker : constant Explicit_Access := new Explicit_Worker;
      pragma Unreferenced (Worker);
   begin
      Control.Wait_Ready;
      if not Control.Passed
        or else Lifecycle.Created_Groups /= 1
        or else Flyology.Observability.Snapshot
          (Groups.Default_Group, Sample)
      then
         Control.Release;
         raise Program_Error with "explicit worker started the wrong group";
      end if;

      if Groups.Request_Pool_Reduction (Target_Size) /=
        Groups.Reduction_Started
      then
         raise Program_Error with "explicit-only reduction did not start";
      end if;
      Status := Groups.Pool_Reduction;
      if Status.Phase /= Groups.Drained
        or else Status.Automatic_Tasks /= 0
        or else Status.Explicit_Tasks /= 1
        or else Lifecycle.Created_Groups /= 1
        or else Flyology.Observability.Snapshot
          (Groups.Default_Group, Sample)
      then
         Control.Release;
         raise Program_Error with
           "explicit-only reduction started a drainage group";
      end if;
      Control.Release;
   end;
exception
   when others =>
      Control.Release;
      raise;
end Pool_Reduction_Inert_Smoke;
