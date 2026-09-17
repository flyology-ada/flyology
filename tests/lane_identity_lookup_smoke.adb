with Ada.Dynamic_Priorities;
with Ada.Task_Identification;
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Fault_Control;
with Flyology;
with Interfaces.C;
with System.Flyology.Scheduler;
with System.OS_Interface;
with System.Task_Primitives.Operations;
with System.Tasking;

procedure Lane_Identity_Lookup_Smoke is
   package Priorities renames Ada.Dynamic_Priorities;
   package Task_Ids renames Ada.Task_Identification;
   package Task_Primitives renames System.Task_Primitives.Operations;
   package Scheduler renames System.Flyology.Scheduler;

   use type Interfaces.C.int;

   protected Activation is
      procedure Report_Ready;
      entry Wait_Ready;
   private
      Ready : Boolean := False;
   end Activation;

   protected body Activation is
      procedure Report_Ready is
      begin
         Ready := True;
      end Report_Ready;

      entry Wait_Ready when Ready is
      begin
         null;
      end Wait_Ready;
   end Activation;

   task Native_Peer is
      pragma Task_Info (Flyology.Native_Task);
      entry Ping;
      entry Stop;
   end Native_Peer;

   task body Native_Peer is
   begin
      loop
         select
            accept Ping;
         or
            accept Stop;
            exit;
         end select;
      end loop;
   end Native_Peer;

   task type Lightweight_Probe is
      pragma Task_Info (Flyology.Lightweight_Task);
      entry Release;
   end Lightweight_Probe;

   task body Lightweight_Probe is
   begin
      Activation.Report_Ready;
      accept Release;
   end Lightweight_Probe;

   type Probe_Access is access Lightweight_Probe;
   procedure Free is new Ada.Unchecked_Deallocation (Lightweight_Probe, Probe_Access);

   function To_Runtime_Task_Id is new Ada.Unchecked_Conversion (Task_Ids.Task_Id, System.Tasking.Task_Id);

   Probe             : Probe_Access;
   Original_Priority : System.Any_Priority;
   Changed_Priority  : System.Any_Priority;
   Thread            : System.OS_Interface.Thread_Id;

   procedure Require_Fiber_Lookup (Kind : Fault_Control.Registry_Lookup_Kind) is
   begin
      if Fault_Control.Registry_Lookup_Count (Kind) = 0 then
         raise Program_Error with "Fiber-consuming registry lookup was not observed: " & Kind'Image;
      end if;
   end Require_Fiber_Lookup;

   procedure Check_Pre_Activation_Priority is
      task Target is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Target;

      task body Target is
      begin
         null;
      end Target;

      function Adjust return Boolean is
      begin
         Priorities.Set_Priority (Priorities.Get_Priority (Target'Identity), Target'Identity);
         return True;
      end Adjust;

      Adjusted : constant Boolean := Adjust;
      pragma Unreferenced (Adjusted);
   begin
      null;
   end Check_Pre_Activation_Priority;

   procedure Check_Missing_Fiber_Destruction is
      Missing : aliased System.Tasking.Ada_Task_Control_Block (0);
   begin
      --  This synthetic ATCB has never been registered and is not an Ada task.
      --  Only its lifecycle state is read by the absent-record destruction path.
      Missing.Common.Is_Lightweight := True;
      Missing.Common.State := System.Tasking.Runnable;
      if Scheduler.Destroy (Missing'Address) /= -1 then
         raise Program_Error with "destruction accepted a missing live Fiber";
      end if;

      Missing.Common.State := System.Tasking.Terminated;
      for Attempt in 1 .. 2 loop
         if Scheduler.Destroy (Missing'Address) /= 0 then
            raise Program_Error with "finished destruction was not idempotent";
         end if;
      end loop;

      Missing.Common.State := System.Tasking.Unactivated;
      if Scheduler.Destroy (Missing'Address) /= 0 then
         raise Program_Error with "unactivated cleanup required a Fiber";
      end if;
   end Check_Missing_Fiber_Destruction;
begin
   if not Fault_Control.Enabled then
      raise Program_Error with "lane lookup test requires FLYOLOGY_TEST_FAULTS=1 runtime";
   end if;

   Check_Pre_Activation_Priority;
   Check_Missing_Fiber_Destruction;
   Probe := new Lightweight_Probe;
   Activation.Wait_Ready;
   Fault_Control.Reset;

   --  Before the ATCB lane bit, each native rendezvous reached one or more
   --  GNARL predicates which classified the task through the Fiber registry.
   for Iteration in 1 .. 10 loop
      Native_Peer.Ping;
   end loop;

   if Fault_Control.Registry_Lookup_Count (Fault_Control.Lane_Predicate) /= 0 then
      raise Program_Error with "native GNARL predicates consulted the Fiber registry";
   end if;

   Thread := Task_Primitives.Get_Thread_Id (To_Runtime_Task_Id (Probe.all'Identity));
   pragma Unreferenced (Thread);

   Original_Priority := Priorities.Get_Priority (Probe.all'Identity);
   Changed_Priority :=
     (if Original_Priority < System.Any_Priority'Last then Original_Priority + 1 else Original_Priority - 1);
   Priorities.Set_Priority (Changed_Priority, Probe.all'Identity);

   Probe.Release;
   while not Probe.all'Terminated loop
      delay 0.001;
   end loop;
   Free (Probe);
   Native_Peer.Stop;

   Require_Fiber_Lookup (Fault_Control.Task_Thread);
   Require_Fiber_Lookup (Fault_Control.Wake);
   Require_Fiber_Lookup (Fault_Control.Set_Priority);
   Require_Fiber_Lookup (Fault_Control.Destroy);
end Lane_Identity_Lookup_Smoke;
