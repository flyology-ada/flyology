with Ada.Real_Time;
with Ada.Finalization;
with Flyology;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.Native_Executors;
with Flyology.Task_Scopes;
with Interfaces;

procedure Task_Scopes_Smoke is
   use type Interfaces.Unsigned_64;
   type Work_Result is record
      Value       : Integer := 0;
      Lightweight : Boolean := False;
   end record;

   protected Tracker is
      procedure Enter;
      procedure Leave;
      function Peak return Natural;
      procedure Reset;
   private
      Active : Natural := 0;
      Maximum : Natural := 0;
   end Tracker;

   protected body Tracker is
      procedure Enter is
      begin
         Active := Active + 1;
         Maximum := Natural'Max (Maximum, Active);
      end Enter;

      procedure Leave is
      begin
         Active := Active - 1;
      end Leave;

      function Peak return Natural is (Maximum);

      procedure Reset is
      begin
         Active := 0;
         Maximum := 0;
      end Reset;
   end Tracker;

   procedure Work
     (Input    : Integer;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Work_Result)
   is
      use type Ada.Real_Time.Time;
   begin
      pragma Assert (Deadline = Ada.Real_Time.Time_Last);
      Tracker.Enter;
      begin
         if Input = -1 then
            raise Constraint_Error with "expected task-scope failure";
         elsif Input = 0 then
            while not Token.Requested loop
               delay 0.001;
            end loop;
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.01;
         Result :=
           (Value => Input * 2,
            Lightweight => Flyology.IO.Is_Lightweight_Task);
      exception
         when others =>
            Tracker.Leave;
            raise;
      end;
      Tracker.Leave;
   end Work;

   package Lightweight_Scopes is new
     Flyology.Task_Scopes (Integer, Work_Result, Work);
   package Native_Executor is new
     Flyology.Native_Executors (Integer, Work_Result, Work);

   Copy_Should_Fail : Boolean := False;

   type Copy_Checked_Input is new Ada.Finalization.Controlled with record
      Value : Integer := 0;
   end record;

   overriding procedure Adjust (Item : in out Copy_Checked_Input) is
      pragma Unreferenced (Item);
   begin
      if Copy_Should_Fail then
         Copy_Should_Fail := False;
         raise Constraint_Error with "expected input copy failure";
      end if;
   end Adjust;

   procedure Copy_Checked_Work
     (Input    : Copy_Checked_Input;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Integer)
   is
      pragma Unreferenced (Token, Deadline);
   begin
      Result := Input.Value;
   end Copy_Checked_Work;

   package Copy_Checked_Scopes is new
     Flyology.Task_Scopes
       (Copy_Checked_Input, Integer, Copy_Checked_Work);

   procedure Check_Input_Copy_Failure is
      Item : Copy_Checked_Scopes.Scope (Capacity => 1, Parent => null);
      Handle : Copy_Checked_Scopes.Operation_Handle;
      Failed : Boolean := False;
   begin
      Copy_Checked_Scopes.Configure (Item, Ada.Real_Time.Time_Last);
      Copy_Should_Fail := True;
      begin
         Copy_Checked_Scopes.Spawn
           (Item, (Ada.Finalization.Controlled with Value => 1), Handle);
      exception
         when Program_Error => Failed := True;
      end;
      pragma Assert (Failed);

      Copy_Checked_Scopes.Spawn
        (Item, (Ada.Finalization.Controlled with Value => 2), Handle);
      Copy_Checked_Scopes.Join (Item);
      pragma Assert (Copy_Checked_Scopes.Result (Item, Handle) = 2);
   end Check_Input_Copy_Failure;

   procedure Check_Lightweight is
      Item : Lightweight_Scopes.Scope (Capacity => 2, Parent => null);
      First, Second : Lightweight_Scopes.Operation_Handle;
   begin
      Tracker.Reset;
      Lightweight_Scopes.Configure
        (Item, Ada.Real_Time.Time_Last);
      Lightweight_Scopes.Spawn (Item, 2, First);
      Lightweight_Scopes.Spawn (Item, 3, Second);
      Lightweight_Scopes.Join (Item);
      pragma Assert (Lightweight_Scopes.Succeeded (Item, First));
      pragma Assert (Lightweight_Scopes.Result (Item, First).Value = 4);
      pragma Assert (Lightweight_Scopes.Result (Item, First).Lightweight);
      pragma Assert (Lightweight_Scopes.Result (Item, Second).Value = 6);
      pragma Assert (Tracker.Peak = 2);
   end Check_Lightweight;

   procedure Check_Native is
      Item : aliased Native_Executor.Executor (Workers => 2, Capacity => 2);
      First, Second, Rejected : Native_Executor.Operation_Handle (Item'Access);
      First_Result, Second_Result : Work_Result;
      Accepted : Boolean;
   begin
      Tracker.Reset;
      Native_Executor.Start (Item);
      Native_Executor.Submit
        (Item, 4, null, Ada.Real_Time.Time_Last, First, Accepted);
      pragma Assert (Accepted);
      declare
         Rejected_Reuse : Boolean := False;
      begin
         begin
            Native_Executor.Submit
              (Item, 99, null, Ada.Real_Time.Time_Last, First, Accepted);
         exception
            when Native_Executor.Invalid_Handle => Rejected_Reuse := True;
         end;
         pragma Assert (Rejected_Reuse);
      end;
      Native_Executor.Submit
        (Item, 5, null, Ada.Real_Time.Time_Last, Second, Accepted);
      pragma Assert (Accepted);
      Native_Executor.Submit
        (Item, 6, null, Ada.Real_Time.Time_Last, Rejected, Accepted);
      pragma Assert (not Accepted);
      declare
         Sample : constant Native_Executor.Executor_Statistics :=
           Native_Executor.Statistics (Item);
      begin
         pragma Assert (Sample.Accepted_Submissions = 2);
         pragma Assert (Sample.Rejected_Submissions = 1);
         pragma Assert (Sample.Outstanding_Operations = 2);
         pragma Assert (Sample.Peak_Outstanding = 2);
      end;
      Native_Executor.Await (Item, First, First_Result);
      Native_Executor.Await (Item, Second, Second_Result);
      pragma Assert (First_Result.Value = 8);
      pragma Assert (not First_Result.Lightweight);
      pragma Assert (Second_Result.Value = 10);
      pragma Assert (Tracker.Peak <= 2);
      declare
         Sample : constant Native_Executor.Executor_Statistics :=
           Native_Executor.Statistics (Item);
      begin
         pragma Assert (Sample.Successful_Executions = 2);
         pragma Assert (Sample.Failed_Executions = 0);
         pragma Assert (Sample.Outstanding_Operations = 0);
         pragma Assert (Sample.Queued_Operations = 0);
         pragma Assert (Sample.Running_Operations = 0);
      end;
   end Check_Native;

   procedure Check_Native_Exception_And_Deadline is
      Item : aliased Native_Executor.Executor (Workers => 1, Capacity => 1);
      Accepted : Boolean;
   begin
      Native_Executor.Start (Item);
      declare
         Failing : Native_Executor.Operation_Handle (Item'Access);
         Value   : Work_Result;
         Saw_Failure : Boolean := False;
      begin
         Native_Executor.Submit
           (Item, -1, null, Ada.Real_Time.Time_Last, Failing, Accepted);
         pragma Assert (Accepted);
         begin
            Native_Executor.Await (Item, Failing, Value);
         exception
            when Constraint_Error => Saw_Failure := True;
         end;
         pragma Assert (Saw_Failure);
      end;
      declare
         Expired : Native_Executor.Operation_Handle (Item'Access);
         Value   : Work_Result;
         Saw_Timeout : Boolean := False;
      begin
         Native_Executor.Submit
           (Item, 1, null, Ada.Real_Time.Clock, Expired, Accepted);
         pragma Assert (Accepted);
         begin
            Native_Executor.Await (Item, Expired, Value);
         exception
            when Flyology.IO.Timeout_Error => Saw_Timeout := True;
         end;
         pragma Assert (Saw_Timeout);
      end;
      for Attempt in 1 .. 100 loop
         exit when
           Native_Executor.Statistics (Item).Outstanding_Operations = 0;
         delay 0.001;
      end loop;
      declare
         Sample : constant Native_Executor.Executor_Statistics :=
           Native_Executor.Statistics (Item);
      begin
         pragma Assert (Sample.Failed_Executions = 2);
         pragma Assert (Sample.Outstanding_Operations = 0);
      end;
   end Check_Native_Exception_And_Deadline;

   procedure Check_Native_Abandon is
      Item : aliased Native_Executor.Executor (Workers => 1, Capacity => 1);
      Parent : aliased Flyology.Cancellation.Token;
      Accepted : Boolean;
      Saw_Cancellation : Boolean := False;
   begin
      Tracker.Reset;
      Native_Executor.Start (Item);
      declare
         Waiting : Native_Executor.Operation_Handle (Item'Access);
         Ignored : Work_Result;
      begin
         Native_Executor.Submit
           (Item, 0, Parent'Access, Ada.Real_Time.Time_Last,
            Waiting, Accepted);
         pragma Assert (Accepted);
         Parent.Request;
         begin
            Native_Executor.Await
              (Item, Waiting, Ignored, Parent'Access,
               Ada.Real_Time.Time_Last);
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Saw_Cancellation := True;
         end;
      end;
      pragma Assert (Saw_Cancellation);

      declare
         Completed : Native_Executor.Operation_Handle (Item'Access);
         Value     : Work_Result;
      begin
         for Attempt in 1 .. 100 loop
            Native_Executor.Submit
              (Item, 7, null, Ada.Real_Time.Time_Last, Completed, Accepted);
            exit when Accepted;
            delay 0.001;
         end loop;
         pragma Assert (Accepted);
         Native_Executor.Await (Item, Completed, Value);
         pragma Assert (Value.Value = 14);
      end;

      declare
         Abandoned : Native_Executor.Operation_Handle (Item'Access);
      begin
         Native_Executor.Submit
           (Item, 0, null, Ada.Real_Time.Time_Last, Abandoned, Accepted);
         pragma Assert (Accepted);
         --  Finalizing Abandoned requests its executor-owned token and marks
         --  the slot for automatic reclamation.
      end;
      declare
         Reused : Native_Executor.Operation_Handle (Item'Access);
         Value  : Work_Result;
      begin
         for Attempt in 1 .. 100 loop
            Native_Executor.Submit
              (Item, 8, null, Ada.Real_Time.Time_Last, Reused, Accepted);
            exit when Accepted;
            delay 0.001;
         end loop;
         pragma Assert (Accepted);
         Native_Executor.Await (Item, Reused, Value);
         pragma Assert (Value.Value = 16);
      end;
      declare
         Sample : constant Native_Executor.Executor_Statistics :=
           Native_Executor.Statistics (Item);
      begin
         pragma Assert (Sample.Abandoned_Operations = 2);
         pragma Assert (Sample.Outstanding_Operations = 0);
      end;
   end Check_Native_Abandon;

   procedure Check_Native_Shutdown_With_Active_Work is
      Item : aliased Native_Executor.Executor (Workers => 1, Capacity => 1);
      Waiting : Native_Executor.Operation_Handle (Item'Access);
      Accepted : Boolean;
      Value : Work_Result;
      Cancelled : Boolean := False;
   begin
      Native_Executor.Start (Item);
      Native_Executor.Submit
        (Item, 0, null, Ada.Real_Time.Time_Last, Waiting, Accepted);
      pragma Assert (Accepted);
      Native_Executor.Shutdown (Item);
      begin
         Native_Executor.Await (Item, Waiting, Value);
      exception
         when Flyology.Cancellation.Operation_Cancelled =>
            Cancelled := True;
      end;
      pragma Assert (Cancelled);
      Native_Executor.Shutdown (Item);
   end Check_Native_Shutdown_With_Active_Work;

   procedure Check_Failure_Cancels_Sibling is
      Item : Lightweight_Scopes.Scope (Capacity => 2, Parent => null);
      Waiting, Failing : Lightweight_Scopes.Operation_Handle;
      Saw_Failure : Boolean := False;
      Saw_Cancellation : Boolean := False;
   begin
      Lightweight_Scopes.Configure
        (Item, Ada.Real_Time.Time_Last,
         Cancel_Siblings_On_Failure => True);
      Lightweight_Scopes.Spawn (Item, 0, Waiting);
      Lightweight_Scopes.Spawn (Item, -1, Failing);
      Lightweight_Scopes.Join (Item);
      begin
         declare
            Ignored : constant Work_Result :=
              Lightweight_Scopes.Result (Item, Failing);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Constraint_Error =>
            Saw_Failure := True;
      end;
      begin
         declare
            Ignored : constant Work_Result :=
              Lightweight_Scopes.Result (Item, Waiting);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Flyology.Cancellation.Operation_Cancelled =>
            Saw_Cancellation := True;
      end;
      pragma Assert (Saw_Failure and Saw_Cancellation);
   end Check_Failure_Cancels_Sibling;

   procedure Check_Child_Cancellation_Is_Downward is
      Parent : aliased Flyology.Cancellation.Token;
   begin
      declare
         Item : Lightweight_Scopes.Scope
           (Capacity => 2, Parent => Parent'Access);
         Waiting, Failing : Lightweight_Scopes.Operation_Handle;
      begin
         Lightweight_Scopes.Configure
           (Item, Ada.Real_Time.Time_Last,
            Cancel_Siblings_On_Failure => True);
         Lightweight_Scopes.Spawn (Item, 0, Waiting);
         Lightweight_Scopes.Spawn (Item, -1, Failing);
         Lightweight_Scopes.Join (Item);
      end;
      pragma Assert (not Parent.Requested);

      declare
         Item : Lightweight_Scopes.Scope
           (Capacity => 1, Parent => Parent'Access);
         Waiting : Lightweight_Scopes.Operation_Handle;
      begin
         Lightweight_Scopes.Configure
           (Item, Ada.Real_Time.Time_Last);
         Lightweight_Scopes.Spawn (Item, 0, Waiting);
         --  Scope finalization cancels and joins Waiting without requesting
         --  the parent token.
      end;
      pragma Assert (not Parent.Requested);
   end Check_Child_Cancellation_Is_Downward;

   procedure Check_Result_Requires_Join is
      Item : Lightweight_Scopes.Scope (Capacity => 1, Parent => null);
      Handle : Lightweight_Scopes.Operation_Handle;
      Raised : Boolean := False;
   begin
      Lightweight_Scopes.Configure
        (Item, Ada.Real_Time.Time_Last);
      Lightweight_Scopes.Spawn (Item, 2, Handle);
      begin
         declare
            Ignored : constant Work_Result :=
              Lightweight_Scopes.Result (Item, Handle);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Program_Error => Raised := True;
      end;
      pragma Assert (Raised);
      Lightweight_Scopes.Join (Item);
   end Check_Result_Requires_Join;

   procedure Check_Handle_Scope_Identity is
      First  : Lightweight_Scopes.Scope (Capacity => 1, Parent => null);
      Second : Lightweight_Scopes.Scope (Capacity => 1, Parent => null);
      Handle : Lightweight_Scopes.Operation_Handle;
      Other  : Lightweight_Scopes.Operation_Handle;
      Rejected : Boolean := False;
   begin
      Lightweight_Scopes.Configure (First, Ada.Real_Time.Time_Last);
      Lightweight_Scopes.Configure (Second, Ada.Real_Time.Time_Last);
      Lightweight_Scopes.Spawn (First, 2, Handle);
      Lightweight_Scopes.Spawn (Second, 3, Other);
      Lightweight_Scopes.Join (First);
      Lightweight_Scopes.Join (Second);
      begin
         declare
            Ignored : constant Work_Result :=
              Lightweight_Scopes.Result (Second, Handle);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Lightweight_Scopes.Invalid_Handle => Rejected := True;
      end;
      pragma Assert (Rejected);
      pragma Assert (Lightweight_Scopes.Result (First, Handle).Value = 4);
      pragma Assert (Lightweight_Scopes.Result (Second, Other).Value = 6);
   end Check_Handle_Scope_Identity;

   procedure Check_Sequential_Scope_Identity is
      Stale : Lightweight_Scopes.Operation_Handle;
      Fresh : Lightweight_Scopes.Operation_Handle;
      Rejected : Boolean := False;
   begin
      declare
         Item : Lightweight_Scopes.Scope (Capacity => 1, Parent => null);
      begin
         Lightweight_Scopes.Configure (Item, Ada.Real_Time.Time_Last);
         Lightweight_Scopes.Spawn (Item, 2, Stale);
         Lightweight_Scopes.Join (Item);
      end;
      declare
         Item : Lightweight_Scopes.Scope (Capacity => 1, Parent => null);
      begin
         Lightweight_Scopes.Configure (Item, Ada.Real_Time.Time_Last);
         Lightweight_Scopes.Spawn (Item, 3, Fresh);
         Lightweight_Scopes.Join (Item);
         begin
            declare
               Ignored : constant Work_Result :=
                 Lightweight_Scopes.Result (Item, Stale);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Lightweight_Scopes.Invalid_Handle => Rejected := True;
         end;
         pragma Assert (Lightweight_Scopes.Result (Item, Fresh).Value = 6);
      end;
      pragma Assert (Rejected);
   end Check_Sequential_Scope_Identity;

begin
   Check_Input_Copy_Failure;
   Check_Lightweight;
   Check_Native;
   Check_Native_Exception_And_Deadline;
   Check_Native_Abandon;
   Check_Native_Shutdown_With_Active_Work;
   Check_Failure_Cancels_Sibling;
   Check_Child_Cancellation_Is_Downward;
   Check_Result_Requires_Join;
   Check_Handle_Scope_Identity;
   Check_Sequential_Scope_Identity;
end Task_Scopes_Smoke;
