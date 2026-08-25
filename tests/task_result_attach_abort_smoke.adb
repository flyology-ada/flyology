with Ada.Real_Time;
with Ada.Synchronous_Task_Control;
with Ada.Task_Identification;
with Flyology;
with Flyology.Operations;
with Flyology.Task_Lifecycle_Testing;
with Flyology.Task_Results;

procedure Task_Result_Attach_Abort_Smoke is
   package Operations renames Flyology.Operations;
   package Results renames Flyology.Task_Results;
   package STC renames Ada.Synchronous_Task_Control;
   package Testing renames Flyology.Task_Lifecycle_Testing;

   use type Ada.Real_Time.Time;
   use type Results.Observation_Status;

   Subject_Started : STC.Suspension_Object;
   Subject_Gate    : STC.Suspension_Object;

   task Subject is
      pragma Task_Info (Flyology.Native_Task);
   end Subject;

   task body Subject is
   begin
      STC.Set_True (Subject_Started);
      STC.Suspend_Until_True (Subject_Gate);
   end Subject;

   Source : aliased Results.Monitor;

   procedure Await_Termination (T : Ada.Task_Identification.Task_Id; Label : String) is
      Deadline : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while not Ada.Task_Identification.Is_Terminated (T) loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with Label & " did not terminate";
         end if;
         delay 0.001;
      end loop;
   end Await_Termination;

   procedure Check_Abort_After_Attach
     (Point : Testing.Barrier_Point; From_Monitor : Boolean)
   is
      Start_Waiter : STC.Suspension_Object;
      Baseline     : constant Natural := Testing.Outstanding_References;

      task Waiter is
         pragma Task_Info (Flyology.Native_Task);
      end Waiter;

      task body Waiter is
         Set       : aliased Operations.Completion_Set (1);
         Operation : Results.Wait_Operation (Set'Access);
      begin
         STC.Suspend_Until_True (Start_Waiter);
         if From_Monitor then
            Results.Wait (Source, Operation => Operation);
         else
            Results.Wait (Subject'Identity, Operation => Operation);
         end if;
      end Waiter;
   begin
      Testing.Arm (Point);
      STC.Set_True (Start_Waiter);
      Testing.Wait_Reached (Point);
      if Testing.Outstanding_References /= Baseline + 1 then
         raise Program_Error with "scoped wait did not retain exactly one reference";
      end if;

      abort Waiter;
      delay 0.01;
      if Waiter'Terminated then
         raise Program_Error with "abort escaped before retained reference publication";
      end if;
      Testing.Release (Point);
      Await_Termination (Waiter'Identity, "aborted scoped task-result waiter");
      if Testing.Outstanding_References /= Baseline then
         raise Program_Error with "aborted scoped wait leaked a retained reference";
      end if;
   end Check_Abort_After_Attach;

   procedure Check_Reuse (From_Monitor : Boolean) is
      Baseline    : constant Natural := Testing.Outstanding_References;
      Set         : aliased Operations.Completion_Set (1);
      Operation   : Results.Wait_Operation (Set'Access);
      Observation : Results.Task_Observation;
   begin
      if From_Monitor then
         Results.Wait (Source, Timeout => 0.0, Operation => Operation);
      else
         Results.Wait (Subject'Identity, Timeout => 0.0, Operation => Operation);
      end if;
      Operations.Wait_All (Set);
      Results.Finish (Operation, Observation);
      if Observation.Status /= Results.Not_Terminal
        or else Testing.Outstanding_References /= Baseline
      then
         raise Program_Error with "replacement scoped wait did not release its reference";
      end if;
   end Check_Reuse;

begin
   STC.Suspend_Until_True (Subject_Started);
   Testing.Reset;
   Results.Attach (Source, Subject'Identity);
   if Testing.Outstanding_References /= 1 then
      raise Program_Error with "source monitor reference was not recorded";
   end if;

   Check_Abort_After_Attach (Testing.Task_Result_Attached, From_Monitor => False);
   Check_Reuse (From_Monitor => False);
   Check_Abort_After_Attach (Testing.Task_Result_Retained, From_Monitor => True);
   Check_Reuse (From_Monitor => True);

   Results.Detach (Source);
   if Testing.Outstanding_References /= 0 then
      raise Program_Error with "source monitor reference was not released";
   end if;
   STC.Set_True (Subject_Gate);
end Task_Result_Attach_Abort_Smoke;
