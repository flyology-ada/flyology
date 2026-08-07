with Ada.Finalization;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Synchronous_Task_Control;
with Ada.Task_Identification;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.Task_Results;
with System.Task_Info;

procedure Task_Results_Smoke is
   package Results renames Flyology.Task_Results;
   package RT renames Ada.Real_Time;
   package STC renames Ada.Synchronous_Task_Control;
   package Task_Ids renames Ada.Task_Identification;

   use type Results.Exit_Cause;
   use type Results.Observation_Status;
   use type RT.Time;

   protected type Signal is
      procedure Set;
      entry Wait;
      function Is_Set return Boolean;
   private
      Raised : Boolean := False;
   end Signal;

   protected body Signal is
      procedure Set is
      begin
         Raised := True;
      end Set;

      entry Wait when Raised is
      begin
         null;
      end Wait;

      function Is_Set return Boolean is (Raised);
   end Signal;

   function Await_Task
     (T       : Task_Ids.Task_Id;
      Context : String) return Results.Task_Result
   is
      Observation : constant Results.Task_Observation :=
        Results.Wait (T, Timeout => 2.0);
   begin
      if Observation.Status /= Results.Terminal then
         raise Program_Error with Context & " result was not published";
      end if;
      return Observation.Result;
   end Await_Task;

   generic
      Label : String;
      Model : System.Task_Info.Task_Info_Type;
   procedure Run_Lane;

   procedure Run_Lane is
      Failure            : exception;
      Activation_Failure : exception;
      Long_Message : constant String
        (1 .. Results.Exception_Message_Capacity + 19) := (others => 'M');

      task type Fast_Task is
         pragma Task_Info (Model);
      end Fast_Task;

      task body Fast_Task is
      begin
         null;
      end Fast_Task;

      type Fast_Access is access Fast_Task;
      procedure Free_Fast is new Ada.Unchecked_Deallocation
        (Fast_Task, Fast_Access);

      task type Failure_Task is
         pragma Task_Info (Model);
      end Failure_Task;

      task body Failure_Task is
      begin
         raise Failure with Long_Message;
      end Failure_Task;

      type Failure_Access is access Failure_Task;
      procedure Free_Failure is new Ada.Unchecked_Deallocation
        (Failure_Task, Failure_Access);

      Started : Signal;
      Gate    : STC.Suspension_Object;

      task type Abort_Task is
         pragma Task_Info (Model);
      end Abort_Task;

      task body Abort_Task is
      begin
         Started.Set;
         STC.Suspend_Until_True (Gate);
      end Abort_Task;

      type Abort_Access is access Abort_Task;
      procedure Free_Abort is new Ada.Unchecked_Deallocation
        (Abort_Task, Abort_Access);

      Finalized : Signal;

      type Finalization_Probe is
        new Ada.Finalization.Limited_Controlled with null record;
      overriding procedure Finalize (Item : in out Finalization_Probe);

      procedure Finalize (Item : in out Finalization_Probe) is
         pragma Unreferenced (Item);
      begin
         Finalized.Set;
      end Finalize;

      task type Finalizing_Task is
         pragma Task_Info (Model);
      end Finalizing_Task;

      task body Finalizing_Task is
         Probe : Finalization_Probe;
         pragma Unreferenced (Probe);
      begin
         null;
      end Finalizing_Task;

      type Finalizing_Access is access Finalizing_Task;
      procedure Free_Finalizing is new Ada.Unchecked_Deallocation
        (Finalizing_Task, Finalizing_Access);

      function Fail_Activation return Boolean is
      begin
         raise Activation_Failure with
           "activation failed before allocator return";
         return False;
      end Fail_Activation;

      task type Broken_Task is
         pragma Task_Info (Model);
      end Broken_Task;

      task body Broken_Task is
         Failed : constant Boolean := Fail_Activation;
         pragma Unreferenced (Failed);
      begin
         null;
      end Broken_Task;

      type Broken_Access is access Broken_Task;

      Item : Results.Task_Result;
   begin
      --  The sidecar is attached before activation, so a task that returns
      --  before its allocator's continuation is still directly observable.
      declare
         Subject : Fast_Access := new Fast_Task;
      begin
         Item := Await_Task (Subject.all'Identity, Label & " fast task");
         if Item.Cause /= Results.Normal_Completion then
            raise Program_Error with Label & " normal result mismatch";
         end if;
         Free_Fast (Subject);
      end;

      --  Independent monitors retain the fixed result after the allocator-
      --  owned task object is reclaimed. They do not retain or address the
      --  task itself and detach independently.
      declare
         Subject : Fast_Access := new Fast_Task;
         First   : Results.Monitor;
         Second  : Results.Monitor;
         First_Observation  : Results.Task_Observation;
         Second_Observation : Results.Task_Observation;
      begin
         Results.Attach (First, Subject.all'Identity);
         Results.Attach (Second, Subject.all'Identity);
         First_Observation := Results.Wait (First, Timeout => 2.0);
         if First_Observation.Status /= Results.Terminal
           or else First_Observation.Result.Cause /= Results.Normal_Completion
         then
            raise Program_Error with Label & " first monitor mismatch";
         end if;

         Free_Fast (Subject);
         Second_Observation := Results.Observe (Second);
         if Second_Observation.Status /= Results.Terminal
           or else
             Second_Observation.Result.Cause /= Results.Normal_Completion
         then
            raise Program_Error with
              Label & " monitor did not survive task-object reclamation";
         end if;
         Results.Detach (First);
         Results.Detach (First);
         if Results.Attached (First) or else not Results.Attached (Second) then
            raise Program_Error with Label & " monitor detach mismatch";
         end if;
      end;

      --  A declared task object owns the same persistent result sidecar; no
      --  allocator or access object is required.
      declare
         Subject : Fast_Task;
      begin
         Item := Await_Task (Subject'Identity, Label & " declared task");
         if Item.Cause /= Results.Normal_Completion then
            raise Program_Error with Label & " declared result mismatch";
         end if;
      end;

      declare
         Subject : Failure_Access := new Failure_Task;
      begin
         Item := Await_Task (Subject.all'Identity, Label & " failed task");
         if Item.Cause /= Results.Unhandled_Exception
           or else Ada.Strings.Fixed.Index
             (Results.Text (Item.Exception_Name), "FAILURE") = 0
           or else Item.Exception_Name.Truncated
           or else not Item.Exception_Message.Truncated
           or else Item.Exception_Message.Length /=
             Results.Exception_Message_Capacity
           or else Results.Text (Item.Exception_Message) /=
             Long_Message (1 .. Results.Exception_Message_Capacity)
         then
            raise Program_Error with Label & " exception result mismatch";
         end if;
         Free_Failure (Subject);
      end;

      declare
         Subject : Abort_Access := new Abort_Task;
      begin
         Started.Wait;
         abort Subject.all;
         Item := Await_Task (Subject.all'Identity, Label & " aborted task");
         if Item.Cause /= Results.Abnormal_Completion then
            raise Program_Error with Label & " abnormal result mismatch";
         end if;
         Free_Abort (Subject);
      end;

      declare
         Subject : Finalizing_Access := new Finalizing_Task;
      begin
         Item := Await_Task (Subject.all'Identity, Label & " finalizing task");
         if not Finalized.Is_Set then
            raise Program_Error with Label & " result preceded finalization";
         end if;
         Free_Finalizing (Subject);
      end;

      declare
         Timeout_Started : Signal;
         Timeout_Gate    : STC.Suspension_Object;

         task type Timeout_Task is
            pragma Task_Info (Model);
         end Timeout_Task;

         task body Timeout_Task is
         begin
            Timeout_Started.Set;
            STC.Suspend_Until_True (Timeout_Gate);
         end Timeout_Task;

         type Timeout_Access is access Timeout_Task;
         procedure Free_Timeout is new Ada.Unchecked_Deallocation
           (Timeout_Task, Timeout_Access);

         Subject     : Timeout_Access := new Timeout_Task;
         Watch       : Results.Monitor;
         Observation : Results.Task_Observation;
      begin
         Timeout_Started.Wait;
         Results.Attach (Watch, Subject.all'Identity);
         Observation := Results.Observe (Subject.all'Identity);
         if Observation.Status /= Results.Not_Terminal then
            raise Program_Error with Label & " running task was terminal";
         end if;
         Observation := Results.Wait (Subject.all'Identity, Timeout => 0.01);
         if Observation.Status /= Results.Not_Terminal then
            raise Program_Error with Label & " direct wait did not time out";
         end if;
         Observation := Results.Wait (Watch, Timeout => 0.01);
         if Observation.Status /= Results.Not_Terminal then
            raise Program_Error with Label & " monitor wait did not time out";
         end if;
         STC.Set_True (Timeout_Gate);
         Observation := Results.Wait (Watch, Timeout => 2.0);
         if Observation.Status /= Results.Terminal
           or else Observation.Result.Cause /= Results.Normal_Completion
         then
            raise Program_Error with Label & " direct wait result mismatch";
         end if;
         Free_Timeout (Subject);
      end;

      --  When activation fails, Ada raises Tasking_Error and the allocator
      --  returns no Task_Id. There is intentionally no detached result lookup.
      declare
         Subject           : Broken_Access;
         pragma Unreferenced (Subject);
         Activation_Raised : Boolean := False;
      begin
         begin
            Subject := new Broken_Task;
         exception
            when Tasking_Error =>
               Activation_Raised := True;
         end;
         if not Activation_Raised then
            raise Program_Error with Label & " activation failure was not raised";
         end if;
      end;

      Ada.Text_IO.Put_Line ("task results: " & Label & " lane passed");
   end Run_Lane;

   procedure Run_Native is new Run_Lane
     (Label => "native", Model => Flyology.Native_Task);
   procedure Run_Lightweight is new Run_Lane
     (Label => "lightweight", Model => Flyology.Lightweight_Task);

   generic
      Label : String;
      Publisher_Model : System.Task_Info.Task_Info_Type;
   procedure Check_Direct_Waiters;

   procedure Check_Direct_Waiters is
      Publisher_Gate : STC.Suspension_Object;

      task type Publisher is
         pragma Task_Info (Publisher_Model);
      end Publisher;

      task body Publisher is
      begin
         STC.Suspend_Until_True (Publisher_Gate);
      end Publisher;

      type Publisher_Access is access Publisher;
      procedure Free_Publisher is new Ada.Unchecked_Deallocation
        (Publisher, Publisher_Access);

      Subject : Publisher_Access := new Publisher;

      Native_Started      : Signal;
      Native_Done         : Signal;
      Lightweight_Started : Signal;
      Lightweight_Done    : Signal;
      Native_Observation  : Results.Task_Observation;
      Light_Observation   : Results.Task_Observation;

      task Native_Waiter is
         pragma Task_Info (Flyology.Native_Task);
      end Native_Waiter;

      task body Native_Waiter is
      begin
         Native_Started.Set;
         Native_Observation :=
           Results.Wait (Subject.all'Identity, Timeout => 2.0);
         Native_Done.Set;
      end Native_Waiter;

      task Lightweight_Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Lightweight_Waiter;

      task body Lightweight_Waiter is
      begin
         Lightweight_Started.Set;
         Light_Observation :=
           Results.Wait (Subject.all'Identity, Timeout => 2.0);
         Lightweight_Done.Set;
      end Lightweight_Waiter;
   begin
      Native_Started.Wait;
      Lightweight_Started.Wait;
      STC.Set_True (Publisher_Gate);
      Native_Done.Wait;
      Lightweight_Done.Wait;
      if Native_Observation.Status /= Results.Terminal
        or else Light_Observation.Status /= Results.Terminal
        or else Native_Observation.Result.Cause /= Results.Normal_Completion
        or else Light_Observation.Result.Cause /= Results.Normal_Completion
      then
         raise Program_Error with Label & " direct waiter mismatch";
      end if;
      Free_Publisher (Subject);
   end Check_Direct_Waiters;

   procedure Check_Native_Direct_Waiters is new Check_Direct_Waiters
     (Label => "native publication", Publisher_Model => Flyology.Native_Task);
   procedure Check_Lightweight_Direct_Waiters is new Check_Direct_Waiters
     (Label => "lightweight publication",
      Publisher_Model => Flyology.Lightweight_Task);

   procedure Check_Abortable_Direct_Wait is
      Subject_Started : Signal;
      Subject_Gate    : STC.Suspension_Object;
      Waiter_Started  : Signal;
      Monitor_Waiter_Started : Signal;

      task type Subject_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Subject_Task;

      task body Subject_Task is
      begin
         Subject_Started.Set;
         STC.Suspend_Until_True (Subject_Gate);
      end Subject_Task;

      type Subject_Access is access Subject_Task;
      procedure Free_Subject is new Ada.Unchecked_Deallocation
        (Subject_Task, Subject_Access);

      Subject : Subject_Access := new Subject_Task;

      task Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Waiter;

      task body Waiter is
         Observation : Results.Task_Observation;
         pragma Unreferenced (Observation);
      begin
         Waiter_Started.Set;
         Observation := Results.Wait (Subject.all'Identity);
      end Waiter;

      task Monitor_Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Monitor_Waiter;

      task body Monitor_Waiter is
         Watch       : Results.Monitor;
         Observation : Results.Task_Observation;
         pragma Unreferenced (Observation);
      begin
         Results.Attach (Watch, Subject.all'Identity);
         Monitor_Waiter_Started.Set;
         Observation := Results.Wait (Watch);
      end Monitor_Waiter;

      Deadline : constant RT.Time := RT.Clock + RT.Seconds (2);
      Item     : Results.Task_Result;
   begin
      Subject_Started.Wait;
      Waiter_Started.Wait;
      Monitor_Waiter_Started.Wait;
      delay 0.01;
      abort Waiter;
      abort Monitor_Waiter;
      while not Waiter'Terminated loop
         if RT.Clock >= Deadline then
            raise Program_Error with "blocked direct waiter did not abort";
         end if;
         delay 0.001;
      end loop;
      while not Monitor_Waiter'Terminated loop
         if RT.Clock >= Deadline then
            raise Program_Error with "blocked monitor waiter did not abort";
         end if;
         delay 0.001;
      end loop;
      Item := Await_Task (Waiter'Identity, "aborted direct waiter");
      if Item.Cause /= Results.Abnormal_Completion then
         raise Program_Error with "direct wait swallowed task abort";
      end if;
      Item := Await_Task
        (Monitor_Waiter'Identity, "aborted monitor waiter");
      if Item.Cause /= Results.Abnormal_Completion then
         raise Program_Error with "monitor wait swallowed task abort";
      end if;
      abort Subject.all;
      Item := Await_Task (Subject.all'Identity, "direct-wait subject");
      if Item.Cause /= Results.Abnormal_Completion then
         raise Program_Error with "direct-wait subject abort mismatch";
      end if;
      Free_Subject (Subject);
   end Check_Abortable_Direct_Wait;

   procedure Check_Lightweight_Creation_Failure is
      task type Unreserved_Task with CPU => 128 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Unreserved_Task;

      task body Unreserved_Task is
      begin
         raise Program_Error with "unreserved task body ran";
      end Unreserved_Task;

      Raised : Boolean := False;
   begin
      begin
         declare
            Subject : Unreserved_Task;
            pragma Unreferenced (Subject);
         begin
            raise Program_Error with "unreserved task activated";
         end;
      exception
         when Tasking_Error =>
            Raised := True;
      end;

      if not Raised then
         raise Program_Error with "lightweight creation failure was not raised";
      end if;
   end Check_Lightweight_Creation_Failure;

   procedure Check_Null_Identity is
      Raised : Boolean := False;
   begin
      begin
         declare
            Observation : constant Results.Task_Observation :=
              Results.Observe (Task_Ids.Null_Task_Id);
            pragma Unreferenced (Observation);
         begin
            null;
         end;
      exception
         when Program_Error =>
            Raised := True;
      end;
      if not Raised then
         raise Program_Error with "null Task_Id was accepted";
      end if;

      Raised := False;
      begin
         declare
            Watch : Results.Monitor;
         begin
            Results.Attach (Watch, Task_Ids.Null_Task_Id);
         end;
      exception
         when Program_Error =>
            Raised := True;
      end;
      if not Raised then
         raise Program_Error with "monitor accepted null Task_Id";
      end if;
   end Check_Null_Identity;

begin
   Check_Null_Identity;
   Run_Native;
   Run_Lightweight;
   Check_Native_Direct_Waiters;
   Check_Lightweight_Direct_Waiters;
   Check_Abortable_Direct_Wait;
   Check_Lightweight_Creation_Failure;
   Ada.Text_IO.Put_Line
     ("task results: completion, exception, abort, activation, finalization, "
      & "declared and allocated lifetime, retained monitors, timed waits, "
      & "and lane parity passed");
end Task_Results_Smoke;
