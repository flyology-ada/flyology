with Ada.Exceptions;
with Ada.Finalization;
with Flyology.Counter_Policy;
with Flyology.Worker_Pool_Policy;
#if FLYOLOGY_WORKER_POOL_TEST_HOOKS then
with Interfaces.C;
#end if;

package body Flyology.Worker_Pools is

   package Counters renames Flyology.Counter_Policy;
   package Policy renames Flyology.Worker_Pool_Policy;

#if FLYOLOGY_WORKER_POOL_TEST_HOOKS then
   use type Interfaces.C.int;

   function Test_Activation_Failure return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_worker_activation_failure";
   function Test_Shutdown_Barrier_Arrive return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_worker_shutdown_barrier_arrive";
   function Test_Shutdown_Barrier_Released return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_worker_shutdown_barrier_released";

   function Check_Test_Activation return Boolean is
   begin
      if Test_Activation_Failure /= 0 then
         raise Program_Error with "injected worker activation failure";
      end if;
      return True;
   end Check_Test_Activation;

   procedure Test_Shutdown_Barrier is
   begin
      if Test_Shutdown_Barrier_Arrive /= 0 then
         while Test_Shutdown_Barrier_Released = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Test_Shutdown_Barrier;
#end if;

   protected body Lifecycle is
      procedure Begin_Run (Expected_Workers : Positive) is
      begin
         if not Policy.Begin_Allowed (Begun) then
            raise Program_Error with "worker pool is one-shot";
         end if;
         Begun := True;
         Is_Running := True;
         Expected := Expected_Workers;
         Workers_Done := 0;
      end Begin_Run;

      procedure Request_Stop is
      begin
         Stop_Requested := True;
      end Request_Stop;

      procedure Job_Started is
      begin
         if not Policy.Job_Start_Allowed
           (Is_Running, Active, Expected)
         then
            raise Program_Error with "worker pool active count is invalid";
         end if;
         Active := Policy.Active_After_Start (Active, Expected);
      end Job_Started;

      procedure Job_Completed (Cancelled, Failed : Boolean) is
      begin
         if not Policy.Job_Completion_Allowed (Active) then
            raise Program_Error with "worker pool completion without a job";
         end if;
         Active := Policy.Active_After_Completion (Active);
         case Policy.Classify_Completion (Cancelled, Failed) is
            when Policy.Count_Completed =>
               Completed := Counters.Saturating_Increment (Completed);
            when Policy.Count_Cancelled =>
               Cancelled_Total :=
                 Counters.Saturating_Increment (Cancelled_Total);
            when Policy.Count_Neither =>
               null;
         end case;
      end Job_Completed;

      procedure Worker_Finished is
      begin
         if not Policy.Worker_Finish_Allowed
           (Is_Running, Workers_Done, Expected)
         then
            raise Program_Error with "worker pool completion exceeds count";
         end if;
         Workers_Done :=
           Policy.Workers_After_Finish (Workers_Done, Expected);
      end Worker_Finished;

      procedure Record_Failure (Information : String) is
         Length : constant Natural :=
           Natural'Min (Information'Length, Failure_Text'Length);
      begin
         Failure_Total := Counters.Saturating_Increment (Failure_Total);
         if not Failure_Recorded then
            Failure_Recorded := True;
            Failure_Length := Length;
            if Length > 0 then
               Failure_Text (1 .. Length) :=
                 Information
                   (Information'First .. Information'First + Length - 1);
            end if;
         end if;
         Stop_Requested := True;
      end Record_Failure;

      entry Await_All_Workers
        when Policy.All_Workers_Done (Workers_Done, Expected)
      is
      begin
         null;
      end Await_All_Workers;

      procedure Finish_Run is
      begin
         if not Policy.Finish_Allowed
           (Is_Running, Active, Workers_Done, Expected)
         then
            raise Program_Error with "worker pool finished with live work";
         end if;
         Is_Running := False;
         Expected := 0;
         Workers_Done := 0;
      end Finish_Run;

      procedure Abandon_Run is
      begin
         Begun := True;
         Is_Running := False;
         Stop_Requested := True;
         Active := 0;
         Expected := 0;
         Workers_Done := 0;
      end Abandon_Run;

      function Read_Snapshot return Snapshot is
        (Running            => Is_Running,
         Shutdown_Requested => Stop_Requested,
         Active_Workers     => Active,
         Pending_Jobs       => 0,
         Completed_Jobs     => Completed,
         Cancelled_Jobs     => Cancelled_Total,
         Failures           => Failure_Total);

      function Failure_Information return String is
      begin
         if not Failure_Recorded or else Failure_Length = 0 then
            return "";
         end if;
         return Failure_Text (1 .. Failure_Length);
      end Failure_Information;
   end Lifecycle;

   procedure Submit
     (Item     : in out Pool;
      Job      : Job_Type;
      Accepted : out Boolean)
   is
   begin
      Item.Jobs.Send (Job);
      Accepted := True;
   exception
      when Job_Channels.Channel_Closed =>
         Accepted := False;
   end Submit;

   procedure Submit
     (Item    : in out Pool;
      Job     : Job_Type;
      Timeout : Duration;
      Result  : out Submit_Result)
   is
   begin
      Job_Channels.Timed_Send (Item.Jobs, Job, Timeout);
      Result := Job_Accepted;
   exception
      when Job_Channels.Channel_Closed =>
         Result := Pool_Closed;
      when Job_Channels.Timeout_Error =>
         Result := Submit_Timed_Out;
   end Submit;

   procedure Request_Shutdown (Item : in out Pool) is
      Failed : Boolean := False;

      type Shutdown_Guard is
        new Ada.Finalization.Limited_Controlled with null record;

      overriding procedure Finalize (Guard : in out Shutdown_Guard);

      overriding procedure Finalize (Guard : in out Shutdown_Guard) is
         pragma Unreferenced (Guard);
      begin
         begin
            Item.State.Request_Stop;
         exception
            when others =>
               Failed := True;
         end;

#if FLYOLOGY_WORKER_POOL_TEST_HOOKS then
         Test_Shutdown_Barrier;
#end if;

         begin
            Item.Jobs.Close;
         exception
            when others =>
               Failed := True;
         end;

         begin
            --  Request is idempotent. Calling it unconditionally also covers
            --  the failure path, where Record_Failure marks the lifecycle
            --  stopped before this procedure closes the channel.
            Item.Stopping.Request;
         exception
            when others =>
               Failed := True;
         end;
      end Finalize;
   begin
      --  Controlled finalization is abort-deferred. Once this guard exists,
      --  shutdown publishes every wake condition even if the caller is
      --  aborted between the individual protected operations.
      declare
         Guard : Shutdown_Guard;
         pragma Unreferenced (Guard);
      begin
         null;
      end;

      if Failed then
         raise Program_Error with "worker pool shutdown failed";
      end if;
   end Request_Shutdown;

   function Current (Item : Pool) return Snapshot is
      Result : Snapshot := Item.State.Read_Snapshot;
      Queue_State : constant Job_Channels.Snapshot := Item.Jobs.Current;
   begin
      Result.Pending_Jobs := Queue_State.Pending;
      return Result;
   end Current;

   function First_Failure_Information (Item : Pool) return String is
     (Item.State.Failure_Information);

   procedure Run
     (Item    : aliased in out Pool;
      Context : aliased in out Worker_Context)
   is
      Cleanup_Armed : Boolean := False;

      type Run_Guard is
        new Ada.Finalization.Limited_Controlled with null record;

      overriding procedure Finalize (Guard : in out Run_Guard);

      overriding procedure Finalize (Guard : in out Run_Guard) is
         pragma Unreferenced (Guard);
      begin
         if not Cleanup_Armed then
            return;
         end if;

         --  Finalization is abort-deferred and the nested worker scope has
         --  already joined. Isolate shutdown failures so terminal lifecycle
         --  publication cannot replace the original exception or abort.
         begin
            Request_Shutdown (Item);
         exception
            when others =>
               null;
         end;

         begin
            if Item.State.Read_Snapshot.Running then
               Item.State.Abandon_Run;
            end if;
         exception
            when others =>
               null;
         end;
      end Finalize;

      Cleanup : Run_Guard;
      pragma Unreferenced (Cleanup);

      procedure Stop_After_Failure is
      begin
         begin
            Request_Shutdown (Item);
         exception
            when others =>
               --  Queue closure precedes wake signalling, so workers can
               --  still drain and join if an existing descriptor cannot wake.
               null;
         end;
      end Stop_After_Failure;
   begin
      Item.State.Begin_Run (Item.Worker_Count);
      Cleanup_Armed := True;

      declare
         task type Worker with CPU => Worker_CPU is
            pragma Task_Info (Worker_Model);
            entry Start;
         end Worker;

         task body Worker is
#if FLYOLOGY_WORKER_POOL_TEST_HOOKS then
            Activation_Checked : constant Boolean := Check_Test_Activation;
            pragma Unreferenced (Activation_Checked);
#end if;
            Completion_Reported : Boolean := False;

            procedure Report_Finished is
            begin
               if not Completion_Reported then
                  Completion_Reported := True;
                  Item.State.Worker_Finished;
               end if;
            end Report_Finished;
         begin
            --  No worker may consume from the shared queue until every worker
            --  has activated. If activation of a sibling fails, the enclosing
            --  master can therefore select terminate for the workers that did
            --  activate instead of waiting on an open queue forever.
            select
               accept Start;
            or
               terminate;
            end select;

            begin
               loop
                  declare
                     Job       : Job_Type;
                     Cancelled : Boolean := False;
                     Failed    : Boolean := False;
                  begin
                     begin
                        Item.Jobs.Receive (Job);
                     exception
                        when Job_Channels.Channel_Closed =>
                           exit;
                     end;

                     Item.State.Job_Started;
                     begin
                        Process (Context, Job, Item.Stopping'Access);
                     exception
                        when Flyology.Cancellation.Operation_Cancelled =>
                           Cancelled := True;
                        when Event : others =>
                           Item.State.Record_Failure
                             (Ada.Exceptions.Exception_Information (Event));
                           Failed := True;
                           Stop_After_Failure;
                     end;
                     Item.State.Job_Completed (Cancelled, Failed);
                  end;
               end loop;
            exception
               when Event : others =>
                  Item.State.Record_Failure
                    (Ada.Exceptions.Exception_Information (Event));
                  Stop_After_Failure;
            end;
            Report_Finished;
         exception
            when Event : others =>
               Item.State.Record_Failure
                 (Ada.Exceptions.Exception_Information (Event));
               Stop_After_Failure;
               Report_Finished;
         end Worker;

         Workers : array (1 .. Item.Worker_Count) of Worker;
      begin
         for Index in Workers'Range loop
            Workers (Index).Start;
         end loop;
         Item.State.Await_All_Workers;
      exception
         when others =>
            Stop_After_Failure;
            raise;
      end;

      Item.State.Finish_Run;
      Cleanup_Armed := False;
      if Item.State.Read_Snapshot.Failures > 0 then
         raise Pool_Failed with Item.State.Failure_Information;
      end if;
   end Run;

end Flyology.Worker_Pools;
