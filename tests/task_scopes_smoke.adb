with Ada.Real_Time;
with Flyology;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.Native_Executors;
with Flyology.Task_Scopes;

procedure Task_Scopes_Smoke is
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
     Flyology.Task_Scopes
       (Integer, Work_Result, Work, Flyology.Lightweight_Task);
   package Native_Executor is new
     Flyology.Native_Executors (Integer, Work_Result, Work);
   package Native_Scopes renames Native_Executor.Operations;

   procedure Check_Lightweight is
      Item : Lightweight_Scopes.Scope (Capacity => 2);
      First, Second : Lightweight_Scopes.Operation_Handle;
   begin
      Tracker.Reset;
      Lightweight_Scopes.Configure
        (Item, null, Ada.Real_Time.Time_Last);
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
      Item : Native_Scopes.Scope (Capacity => 2);
      First, Second : Native_Scopes.Operation_Handle;
   begin
      Tracker.Reset;
      Native_Scopes.Configure (Item, null, Ada.Real_Time.Time_Last);
      Native_Scopes.Spawn (Item, 4, First);
      Native_Scopes.Spawn (Item, 5, Second);
      Native_Scopes.Join (Item);
      pragma Assert (Native_Scopes.Result (Item, First).Value = 8);
      pragma Assert (not Native_Scopes.Result (Item, First).Lightweight);
      pragma Assert (Native_Scopes.Result (Item, Second).Value = 10);
      pragma Assert (Tracker.Peak <= 2);
   end Check_Native;

   procedure Check_Failure_Cancels_Sibling is
      Item : Lightweight_Scopes.Scope (Capacity => 2);
      Waiting, Failing : Lightweight_Scopes.Operation_Handle;
      Saw_Failure : Boolean := False;
      Saw_Cancellation : Boolean := False;
   begin
      Lightweight_Scopes.Configure
        (Item, null, Ada.Real_Time.Time_Last,
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

begin
   Check_Lightweight;
   Check_Native;
   Check_Failure_Cancels_Sibling;
end Task_Scopes_Smoke;
