with Ada.Command_Line;
with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Task_Scopes;
with Worker_Pool_Test_Control;

--  Task-scope lifecycle behavior that needs injected faults. Each section is
--  individually selectable so one regression can be reproduced on its own.
procedure Task_Scope_Faults_Smoke is

   procedure Never_Run
     (Input    : Integer;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Integer)
   is
      pragma Unreferenced (Token, Deadline);
   begin
      Result := Input;
   end Never_Run;

   package Idle_Scopes is new
     Flyology.Task_Scopes (Integer, Integer, Never_Run);

   --  A worker whose activation fails must not orphan the workers that were
   --  already created: finalization stops and releases them, so the enclosing
   --  master can still complete.
   procedure Check_Activation_Failure_Rollback is
      Failed : Boolean := False;
   begin
      Worker_Pool_Test_Control.Reset;
      Worker_Pool_Test_Control.Fail_Activation_At (3);
      declare
         Item : Idle_Scopes.Scope (Capacity => 4, Parent => null);
      begin
         begin
            Idle_Scopes.Configure (Item, Ada.Real_Time.Time_Last);
         exception
            when Tasking_Error =>
               Failed := True;
         end;
         pragma Assert (Failed);
         --  Leaving the block must release every created worker.
      end;
      Worker_Pool_Test_Control.Reset;
   end Check_Activation_Failure_Rollback;

   Selection : constant String :=
     (if Ada.Command_Line.Argument_Count = 0 then "all"
      else Ada.Command_Line.Argument (1));
begin
   if Selection = "all" or else Selection = "activation" then
      Check_Activation_Failure_Rollback;
   end if;
end Task_Scope_Faults_Smoke;
