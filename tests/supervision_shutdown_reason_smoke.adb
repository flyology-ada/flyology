with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Synchronous_Task_Control;
with Ada.Task_Identification;
with Ada.Text_IO;
with Flyology.Supervision.Families;
with Flyology.Supervision.Static;
with Flyology.Supervision.Task_Generations;
with System.Multiprocessors;

procedure Supervision_Shutdown_Reason_Smoke is
   use Ada.Real_Time;
   use Flyology.Supervision;
   use type Event_Sequence;

   type Controller_Kind is (Static_Tree, Dynamic_Family);
   type Child_Model is (Native_Child, Lightweight_Child);
   type Case_Kind is (Normal, Shutdown_Short, Shutdown_Long, Timeout_First);

   procedure Check_Case (Controller_Model : Controller_Kind; Designation : Child_Model; Mode : Case_Kind) is
      Model              : constant Flyology.Execution_Model :=
        (if Designation = Native_Child then Flyology.Native_Task else Flyology.Lightweight_Task);
      Readiness_Deadline : constant Time_Span := Milliseconds (800);
      Epoch              : constant Time := Clock;
      type Child_Kind is (Child);

      protected type Observations is
         procedure Entered;
         procedure Stopped;
         procedure Returned (Kind : Termination_Kind);
         procedure Controller_Failed;
         function Has_Entered return Boolean;
         function Has_Stopped return Boolean;
         function Stop_Time return Time;
         function Original return Termination_Kind;
         function Failed return Boolean;
      private
         Entered_Flag : Boolean := False;
         Stopped_Flag : Boolean := False;
         Failed_Flag  : Boolean := False;
         At_Time      : Time := Time_First;
         Raw          : Termination_Kind := No_Termination;
      end Observations;

      protected body Observations is
         procedure Entered is
         begin
            Entered_Flag := True;
         end Entered;

         procedure Stopped is
         begin
            At_Time := Clock;
            Stopped_Flag := True;
         end Stopped;

         procedure Returned (Kind : Termination_Kind) is
         begin
            Raw := Kind;
         end Returned;

         procedure Controller_Failed is
         begin
            Failed_Flag := True;
         end Controller_Failed;

         function Has_Entered return Boolean
         is (Entered_Flag);
         function Has_Stopped return Boolean
         is (Stopped_Flag);
         function Stop_Time return Time
         is (At_Time);
         function Original return Termination_Kind
         is (Raw);
         function Failed return Boolean
         is (Failed_Flag);
      end Observations;

      type Context is limited record
         Seen          : Observations;
         Release_Child : Ada.Synchronous_Task_Control.Suspension_Object;
      end record;
      State : aliased Context;

      task type Subject_Task
        (State   : not null access Context;
         Control : not null access Generation_Control)
        with CPU => System.Multiprocessors.Not_A_Specific_CPU
      is
         pragma Task_Info (Model);
      end Subject_Task;

      task body Subject_Task is
      begin
         if Mode = Normal then
            Mark_Ready (Control.all);
         end if;
         State.Seen.Entered;
         if Mode /= Normal then
            while not Stop_Requested (Control.all) loop
               delay 0.001;
            end loop;
            State.Seen.Stopped;
         end if;
         Ada.Synchronous_Task_Control.Suspend_Until_True (State.Release_Child);
      end Subject_Task;

      function Create
        (State : not null access Context; Control : not null access Generation_Control) return Subject_Task is
      begin
         return Item : Subject_Task (State, Control);
      end Create;

      function Identity (Item : in out Subject_Task) return Ada.Task_Identification.Task_Id
      is (Item'Identity);

      procedure Abort_Task (Item : in out Subject_Task) is
      begin
         abort Item;
      end Abort_Task;

      package Generations is new
        Flyology.Supervision.Task_Generations
          (Application_Context => Context,
           Generation_Task     => Subject_Task,
           Create              => Create,
           Task_Identity       => Identity,
           Abort_Task          => Abort_Task);

      procedure Run_One
        (State   : aliased in out Context;
         Input   : Child_Kind;
         Control : aliased in out Generation_Control;
         Result  : out Generation_Result)
      is
         pragma Unreferenced (Input);
      begin
         Generations.Run (State, Control, Result);
         --  Observe the joined task's result before the manager's override.
         State.Seen.Returned (Result.Termination.Kind);
      end Run_One;

      Policy : constant Child_Specification :=
        (Restart           => Never,
         Impact            => Escalate,
         Recovery          => Default_Recovery_Limits,
         Stopping          => Default_Stop_Policy,
         Readiness_Timeout => Readiness_Deadline,
         Restart_Safe      => False,
         Task_Model        => Model,
         Has_Group         => False,
         Group             => 0);

      function Specification (Input : Child_Kind) return Child_Specification is
         pragma Unreferenced (Input);
      begin
         return Policy;
      end Specification;

      function Logical_Id (Input : Child_Kind) return Child_Id is
         pragma Unreferenced (Input);
      begin
         return 174;
      end Logical_Id;

      function Related (Left, Right : Child_Kind) return Boolean is
         pragma Unreferenced (Left, Right);
      begin
         return False;
      end Related;

      package Trees is new
        Flyology.Supervision.Static
          (Child_Kind,
           Context,
           Logical_Id,
           Specification,
           Related,
           Related,
           Run_One);
      package Families is new Flyology.Supervision.Families (Child_Kind, Context, Run_One, Policy, 174, 1);

      Tree            : aliased Trees.Supervisor;
      Family          : aliased Families.Family;
      Result          : Supervisor_Result;
      Handle_Value    : Child_Handle;
      Snapshot        : Child_Snapshot;
      Events          : Supervisor_Event_Array (1 .. 64);
      Cursor          : Event_Sequence := 0;
      Dropped         : Event_Sequence;
      Count           : Natural;
      Terminal_Events : Natural := 0;
      Stop_Events     : Natural := 0;
      Ready_Events    : Natural := 0;
      Expected        : constant Termination_Kind :=
        (case Mode is
           when Normal                         => Normal_Return,
           when Shutdown_Short | Shutdown_Long => Supervisor_Shutdown,
           when Timeout_First                  => Readiness_Timeout);

      task Controller;
      task body Controller is
      begin
         if Controller_Model = Dynamic_Family then
            Families.Run (Family, State, Result);
         else
            Trees.Run (Tree, State, Result);
         end if;
      exception
         when E : others =>
            State.Seen.Controller_Failed;
            Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Information (E));
      end Controller;

      procedure Shutdown is
      begin
         if Controller_Model = Dynamic_Family then
            Families.Request_Shutdown (Family);
         else
            Trees.Request_Shutdown (Tree);
         end if;
      end Shutdown;
   begin
      if Controller_Model = Dynamic_Family then
         while not Families.Accepting (Family) loop
            pragma Assert (not Controller'Terminated, "family ended before admission opened");
            delay 0.001;
         end loop;
         Families.Start (Family, Child, Handle_Value);
      end if;
      while not State.Seen.Has_Entered loop
         pragma Assert (not Controller'Terminated, "controller ended before child entered");
         delay 0.001;
      end loop;

      if Mode in Shutdown_Short | Shutdown_Long then
         Shutdown;
      end if;
      if Mode /= Normal then
         while not State.Seen.Has_Stopped loop
            pragma Assert (not Controller'Terminated, "controller ended before stop acknowledgment");
            delay 0.001;
         end loop;
         if Mode in Shutdown_Short | Shutdown_Long then
            --  Epoch precedes manager Started_At, so this conservatively
            --  establishes shutdown before the actual readiness deadline.
            pragma
              Assert
                (State.Seen.Stop_Time - Epoch < Readiness_Deadline,
                 "shutdown-before-readiness precondition failed");
         else
            --  Only the readiness timeout could publish this first stop.
            Shutdown;
         end if;
         if Mode = Shutdown_Long then
            --  Stop acknowledgment follows manager Started_At. Hold the
            --  unready task alive past expiry, below the default stop grace,
            --  with time for the manager's 1-ms polling to observe expiry.
            delay until State.Seen.Stop_Time + Readiness_Deadline + Milliseconds (200);
         end if;
      end if;
      Ada.Synchronous_Task_Control.Set_True (State.Release_Child);
      if Mode = Normal then
         while State.Seen.Original = No_Termination loop
            pragma Assert (not Controller'Terminated, "controller ended without task result");
            delay 0.001;
         end loop;
         Shutdown;
      end if;
      while not Controller'Terminated loop
         delay 0.001;
      end loop;
      pragma Assert (not State.Seen.Failed, "controller raised an exception");

      if Controller_Model = Dynamic_Family then
         Snapshot := Families.Current (Family, Handle_Value);
         Families.Read_Events (Family, Cursor, Events, Count, Dropped);
      else
         Snapshot := Trees.Current (Tree, Child);
         Trees.Read_Events (Tree, Cursor, Events, Count, Dropped);
      end if;
      pragma Assert (not Snapshot.Live and then not Snapshot.Ready, "child did not join");
      pragma Assert (Dropped = 0, "regression events were dropped");
      if Mode in Shutdown_Short | Shutdown_Long then
         pragma Assert (State.Seen.Original = Supervisor_Shutdown, "original stop was not shutdown");
      elsif Mode = Normal then
         pragma Assert (State.Seen.Original = Normal_Return, "normal control did not return normally");
      else
         pragma Assert (State.Seen.Original = Cancelled, "timeout-first control was not cancelled");
      end if;
      pragma Assert (Snapshot.Termination.Kind = Expected, "retained child stop classification changed");
      if Mode /= Normal then
         pragma Assert (Result.Outcome = Shutdown_Completed, "aggregate shutdown outcome changed");
      end if;
      for I in 1 .. Count loop
         pragma Assert (Events (I).Kind /= Child_Became_Stuck, "stop reached Stuck before child exit");
         if Events (I).Kind = Lifecycle_Changed and then Events (I).After in Terminated | Joined then
            Terminal_Events := Terminal_Events + 1;
            pragma Assert (Events (I).Termination = Expected, "terminal event stop classification changed");
         elsif Events (I).Kind = Stop_Published then
            Stop_Events := Stop_Events + 1;
         elsif Events (I).Kind = Readiness_Published then
            Ready_Events := Ready_Events + 1;
         end if;
      end loop;
      pragma Assert (Terminal_Events > 0, "no terminal child event retained");
      if Mode in Shutdown_Short | Shutdown_Long then
         pragma Assert (Stop_Events = 1, "shutdown did not publish exactly one stop event");
      end if;
      pragma Assert (Ready_Events = (if Mode = Normal then 1 else 0), "readiness precondition changed");
   exception
      when others =>
         Shutdown;
         Ada.Synchronous_Task_Control.Set_True (State.Release_Child);
         raise;
   end Check_Case;
begin
   for Controller_Model in Controller_Kind loop
      for Designation in Child_Model loop
         for Mode in Case_Kind loop
            Ada.Text_IO.Put_Line (Controller_Model'Image & " " & Designation'Image & " " & Mode'Image);
            Check_Case (Controller_Model, Designation, Mode);
         end loop;
      end loop;
   end loop;
end Supervision_Shutdown_Reason_Smoke;
