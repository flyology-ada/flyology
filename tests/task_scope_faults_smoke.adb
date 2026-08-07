with Ada.Command_Line;
with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.Task_Scopes;
with Worker_Pool_Test_Control;

--  Task-scope lifecycle behavior that needs injected faults or timing
--  evidence. Each section is individually selectable so one regression can be
--  reproduced on its own.
procedure Task_Scope_Faults_Smoke is
   use type Ada.Real_Time.Time;

   --  Largest accepted parent-to-child cancellation latency. The retired
   --  polling monitor woke every 10 ms, so its latency was spread over
   --  0 .. 10 ms and could not stay below this bound for every round.
   Latency_Limit : constant Duration := 0.005;

   Latency_Rounds : constant := 16;

   protected Cancel_Timing is
      procedure Reset;
      procedure Mark_Started;
      entry Await_Started;
      procedure Mark_Request;
      function Requested_At return Ada.Real_Time.Time;
   private
      Started : Boolean := False;
      Instant : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   end Cancel_Timing;

   protected body Cancel_Timing is
      procedure Reset is
      begin
         Started := False;
         Instant := Ada.Real_Time.Time_First;
      end Reset;

      procedure Mark_Started is
      begin
         Started := True;
      end Mark_Started;

      entry Await_Started when Started is
      begin
         null;
      end Await_Started;

      procedure Mark_Request is
      begin
         Instant := Ada.Real_Time.Clock;
      end Mark_Request;

      function Requested_At return Ada.Real_Time.Time is (Instant);
   end Cancel_Timing;

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

   --  Report how long the scope token took to observe the parent request.
   procedure Measure_Cancellation
     (Input    : Integer;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Duration)
   is
      pragma Unreferenced (Input, Deadline);
   begin
      Cancel_Timing.Mark_Started;
      Token.Await_Request;
      Result :=
        Ada.Real_Time.To_Duration
          (Ada.Real_Time.Clock - Cancel_Timing.Requested_At);
   end Measure_Cancellation;

   package Idle_Scopes is new
     Flyology.Task_Scopes (Integer, Integer, Never_Run);
   package Timing_Scopes is new
     Flyology.Task_Scopes (Integer, Duration, Measure_Cancellation);

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

   --  Parent cancellation must reach the scope token through a blocking wait
   --  rather than a periodic poll.
   procedure Check_Parent_Cancellation_Is_Prompt is
   begin
      for Round in 1 .. Latency_Rounds loop
         declare
            Parent : aliased Flyology.Cancellation.Token;
            Item   : Timing_Scopes.Scope
              (Capacity => 1, Parent => Parent'Access);
            Handle : Timing_Scopes.Operation_Handle;
         begin
            Cancel_Timing.Reset;
            Timing_Scopes.Configure (Item, Ada.Real_Time.Time_Last);
            Timing_Scopes.Spawn (Item, Round, Handle);
            Cancel_Timing.Await_Started;
            Cancel_Timing.Mark_Request;
            Parent.Request;
            Timing_Scopes.Join (Item);
            pragma Assert (Timing_Scopes.Succeeded (Item, Handle));
            pragma Assert
              (Timing_Scopes.Result (Item, Handle) <= Latency_Limit);
         end;
      end loop;
   end Check_Parent_Cancellation_Is_Prompt;

   Selection : constant String :=
     (if Ada.Command_Line.Argument_Count = 0 then "all"
      else Ada.Command_Line.Argument (1));
begin
   if Selection = "all" or else Selection = "activation" then
      Check_Activation_Failure_Rollback;
   end if;
   if Selection = "all" or else Selection = "latency" then
      Check_Parent_Cancellation_Is_Prompt;
   end if;
end Task_Scope_Faults_Smoke;
