with Ada.Finalization;
with Ada.Real_Time;
with Ada.Task_Identification;
with Flyology.Cancellation;
with Flyology.Supervision.Families;
with Flyology.Supervision.Input_Task_Generations;
with Interfaces;
with System.Multiprocessors;

procedure Flyology.Supervision.Families_Smoke is
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   use type Flyology.Execution_Model;
   use type Interfaces.Unsigned_64;

   Test_Failure : exception;

   subtype Request is Positive range 1 .. 8;
   type Count_Array is array (Request) of Natural;
   type Boolean_Array is array (Request) of Boolean;

   protected type Counts is
      procedure Begin_Generation
        (Input   : Request;
         Attempt : out Positive);
      function Value (Input : Request) return Natural;
   private
      Values : Count_Array := (others => 0);
   end Counts;

   protected body Counts is
      procedure Begin_Generation
        (Input   : Request;
         Attempt : out Positive) is
      begin
         Values (Input) := Values (Input) + 1;
         Attempt := Values (Input);
      end Begin_Generation;

      function Value (Input : Request) return Natural is (Values (Input));
   end Counts;

   protected type Resource_Tracker is
      procedure Acquire (Input : Request);
      procedure Release (Input : Request);
      function Acquisitions (Input : Request) return Natural;
      function Releases (Input : Request) return Natural;
   private
      Active   : Boolean_Array := (others => False);
      Acquired : Count_Array := (others => 0);
      Released : Count_Array := (others => 0);
   end Resource_Tracker;

   protected body Resource_Tracker is
      procedure Acquire (Input : Request) is
      begin
         if Active (Input) then
            raise Program_Error with
              "replacement acquired a resource before prior finalization";
         end if;
         Active (Input) := True;
         Acquired (Input) := Acquired (Input) + 1;
      end Acquire;

      procedure Release (Input : Request) is
      begin
         if not Active (Input) then
            raise Program_Error with "generation resource released twice";
         end if;
         Active (Input) := False;
         Released (Input) := Released (Input) + 1;
      end Release;

      function Acquisitions (Input : Request) return Natural is
        (Acquired (Input));

      function Releases (Input : Request) return Natural is
        (Released (Input));
   end Resource_Tracker;

   type Context is limited record
      Started   : Counts;
      Resources : aliased Resource_Tracker;
   end record;

   type Resource_Guard is
     limited new Ada.Finalization.Limited_Controlled with record
      State : access Resource_Tracker := null;
      Input : Request := Request'First;
   end record;

   overriding procedure Finalize (Item : in out Resource_Guard);

   procedure Acquire
     (Item  : in out Resource_Guard;
      State : not null access Resource_Tracker;
      Input : Request) is
   begin
      State.Acquire (Input);
      Item.State := State;
      Item.Input := Input;
   end Acquire;

   overriding procedure Finalize (Item : in out Resource_Guard) is
   begin
      if Item.State /= null then
         Item.State.Release (Item.Input);
         Item.State := null;
      end if;
   end Finalize;

   task type Family_Task
     (State   : not null access Context;
      Input   : not null access constant Request;
      Control : not null access Flyology.Supervision.Generation_Control)
   with CPU => System.Multiprocessors.Not_A_Specific_CPU is
      pragma Task_Info (Flyology.Native_Task);
   end Family_Task;

   task body Family_Task is
      Attempt : Positive;
      Resource : Resource_Guard;
   begin
      Acquire (Resource, State.Resources'Access, Input.all);
      State.Started.Begin_Generation (Input.all, Attempt);
      Flyology.Supervision.Mark_Ready (Control.all);
      if Input.all = Request'First and then Attempt = 1 then
         raise Test_Failure with "first family generation fails";
      end if;
      loop
         if Flyology.Supervision.Stop_Requested (Control.all) then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.001;
      end loop;
   end Family_Task;

   function Create_Family_Task
     (State   : not null access Context;
      Input   : not null access constant Request;
      Control : not null access Flyology.Supervision.Generation_Control)
      return Family_Task
   is
   begin
      return Subject : Family_Task (State, Input, Control);
   end Create_Family_Task;

   function Identity
     (Subject : in out Family_Task)
      return Ada.Task_Identification.Task_Id is
     (Subject'Identity);

   procedure Abort_Subject (Subject : in out Family_Task) is
   begin
      abort Subject;
   end Abort_Subject;

   package Child is new Flyology.Supervision.Input_Task_Generations
     (Input_Type          => Request,
      Application_Context => Context,
      Generation_Task     => Family_Task,
      Create              => Create_Family_Task,
      Task_Identity       => Identity,
      Abort_Task          => Abort_Subject);

   procedure Run_Generation
     (State   : aliased in out Context;
      Input   : Request;
      Control : aliased in out Flyology.Supervision.Generation_Control;
      Result  : out Flyology.Supervision.Generation_Result) is
   begin
      Child.Run (State, Input, Control, Result);
   end Run_Generation;

   Child_Policy : constant Flyology.Supervision.Child_Specification :=
     (Restart           => Flyology.Supervision.On_Failure,
      Impact            => Flyology.Supervision.Isolate_Child,
      Recovery          =>
        (Burst_Attempts    => 3,
         Window            => Ada.Real_Time.Seconds (1),
         Total_Attempts    => 3,
         Initial_Backoff   => Ada.Real_Time.Milliseconds (50),
         Maximum_Backoff   => Ada.Real_Time.Milliseconds (50),
         Stability_Reset   => Ada.Real_Time.Seconds (1),
         Recovery_Deadline => Ada.Real_Time.Seconds (2)),
      Stopping          => Flyology.Supervision.Default_Stop_Policy,
      Readiness_Timeout => Ada.Real_Time.Seconds (1),
      Restart_Safe      => True,
      Task_Model        => Flyology.Native_Task,
      Has_Group         => False,
      Group             => 0);

   package Families is new Flyology.Supervision.Families
     (Request            => Request,
      Application_Context => Context,
      Run_One_Generation => Run_Generation,
      Policy             => Child_Policy,
      First_Child_Id     => 4_294_967_296,
      Maximum_Children  => 2,
      Event_Capacity    => 4);

   State  : aliased Context;
   Item   : aliased Families.Family;
   Result : Flyology.Supervision.Supervisor_Result;

   task Owner is
      entry Start;
      entry Join;
   end Owner;

   task body Owner is
   begin
      accept Start;
      Families.Run (Item, State, Result);
      accept Join;
   end Owner;

   Deadline : constant Ada.Real_Time.Time :=
     Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
   First  : Flyology.Supervision.Child_Handle;
   Second : Flyology.Supervision.Child_Handle;
   Reused : Flyology.Supervision.Child_Handle;
   Cursor : Flyology.Supervision.Event_Sequence := 0;
   Dropped : Flyology.Supervision.Event_Sequence;
   Event_Count : Natural;
   Events : Flyology.Supervision.Supervisor_Event_Array (1 .. 4);
   Recovery_Cursor : Flyology.Supervision.Event_Sequence := 0;
   Recovery_Dropped : Flyology.Supervision.Event_Sequence;
   Recovery_Event_Count : Natural;
   Recovery_Events : Flyology.Supervision.Supervisor_Event_Array (1 .. 4);
begin
   Owner.Start;
   loop
      exit when Families.Accepting (Item);
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with "family did not open admission";
      end if;
      delay 0.001;
   end loop;
   Families.Start (Item, 1, First);
   declare
      Observation : constant Flyology.Supervision.Generation_Observation :=
        Families.Wait_Termination (Item, First, Timeout => 0.0);
   begin
      --  The first generation deliberately fails immediately, so either the
      --  zero-time check wins or terminal publication wins. Both outcomes
      --  are legal; following the replacement is not.
      if Observation.Status not in
        Flyology.Supervision.Observation_Timed_Out |
        Flyology.Supervision.Generation_Terminated
      then
         raise Program_Error with
           "zero-time family observation followed a replacement";
      end if;
   end;
   declare
      Observation : constant Flyology.Supervision.Generation_Observation :=
        Families.Wait_Termination (Item, First, Timeout => 2.0);
   begin
      pragma Assert
        (Observation.Status = Flyology.Supervision.Generation_Terminated);
      pragma Assert (Observation.Snapshot.Generation = 1);
      pragma Assert
        (Observation.Snapshot.Termination.Kind =
           Flyology.Supervision.Unhandled_Exception);
   end;
   loop
      exit when Families.Current (Item, First).State =
        Flyology.Supervision.Backing_Off;
      if Ada.Real_Time.Clock >= Deadline then
         Families.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with "family child did not enter backoff";
      end if;
      delay 0.001;
   end loop;
   declare
      Observation : constant Flyology.Supervision.Generation_Observation :=
        Families.Wait_Termination (Item, First, Timeout => 0.0);
   begin
      if Observation.Status /= Flyology.Supervision.Generation_Terminated
        or else Observation.Snapshot.Generation /= 1
        or else Observation.Snapshot.State /=
          Flyology.Supervision.Backing_Off
      then
         Families.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with
           "terminated family generation was not observable in backoff";
      end if;
   end;
   begin
      Families.Stop (Item, First);
      Families.Request_Shutdown (Item);
      Owner.Join;
      raise Program_Error with
        "terminated generation handle was accepted during backoff";
   exception
      when Families.Stale_Handle => null;
   end;
   loop
      exit when Families.Current
        (Item, Flyology.Supervision.Child (First)).Ready
        and then Families.Current
          (Item, Flyology.Supervision.Child (First)).Generation = 2;
      if Ada.Real_Time.Clock >= Deadline then
         Families.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with "family replacement did not become ready";
      end if;
      delay 0.001;
   end loop;
   declare
      Observation : constant Flyology.Supervision.Generation_Observation :=
        Families.Wait_Termination (Item, First, Timeout => 0.0);
   begin
      pragma Assert
        (Observation.Status = Flyology.Supervision.Generation_Replaced);
      pragma Assert (Observation.Snapshot.Generation = 2);
   end;
   Families.Read_Events
     (Item,
      Recovery_Cursor,
      Recovery_Events,
      Recovery_Event_Count,
      Recovery_Dropped);
   declare
      Saw_Direct_Start   : Boolean := False;
      Saw_Restarting     : Boolean := False;
   begin
      for Index in 1 .. Recovery_Event_Count loop
         if Recovery_Events (Index).Kind =
           Flyology.Supervision.Lifecycle_Changed
           and then Recovery_Events (Index).Before /=
             Recovery_Events (Index).After
         then
            Saw_Direct_Start := Saw_Direct_Start or else
              (Recovery_Events (Index).Before =
                 Flyology.Supervision.Backing_Off
               and then Recovery_Events (Index).After =
                 Flyology.Supervision.Starting);
            Saw_Restarting := Saw_Restarting or else
              Recovery_Events (Index).After =
                Flyology.Supervision.Restarting;
         end if;
      end loop;
      if Saw_Direct_Start or else not Saw_Restarting then
         Families.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with
           "family recovery events violate the lifecycle model";
      end if;
   end;

   Families.Start (Item, 2, Second);
   loop
      exit when Families.Current (Item, Second).Ready;
      if Ada.Real_Time.Clock >= Deadline then
         Families.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with "second family child did not become ready";
      end if;
      delay 0.001;
   end loop;
   First := Families.Latest (Item, Flyology.Supervision.Child (First));

   --  Manual restart is an exact-generation recovery command. It consumes
   --  the same incident budgets and produces a fresh task generation.
   Families.Restart (Item, First);
   declare
      Observation : constant Flyology.Supervision.Generation_Observation :=
        Families.Wait_Termination (Item, First, Timeout => 2.0);
   begin
      pragma Assert
        (Observation.Status = Flyology.Supervision.Generation_Terminated);
      pragma Assert
        (Observation.Snapshot.Termination.Kind =
           Flyology.Supervision.Restart_Requested);
   end;
   begin
      Families.Restart (Item, First);
      raise Program_Error with "stale manual restart was accepted";
   exception
      when Families.Stale_Handle => null;
   end;
   loop
      exit when Families.Current
        (Item, Flyology.Supervision.Child (First)).Ready
        and then Families.Current
          (Item, Flyology.Supervision.Child (First)).Generation = 3;
      if Ada.Real_Time.Clock >= Deadline then
         Families.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with "manual replacement did not become ready";
      end if;
      delay 0.001;
   end loop;
   First := Families.Latest (Item, Flyology.Supervision.Child (First));

   --  A failed external health probe preserves its bounded diagnostic and
   --  follows the same generation-safe recovery path.
   Families.Report_Unhealthy (Item, First, "probe rejected generation");
   declare
      Observation : constant Flyology.Supervision.Generation_Observation :=
        Families.Wait_Termination (Item, First, Timeout => 2.0);
   begin
      pragma Assert
        (Observation.Status = Flyology.Supervision.Generation_Terminated);
      pragma Assert
        (Observation.Snapshot.Termination.Kind =
           Flyology.Supervision.Unhealthy);
      pragma Assert
        (Flyology.Supervision.Message_Text
           (Observation.Snapshot.Termination) = "probe rejected generation");
   end;
   loop
      exit when Families.Current
        (Item, Flyology.Supervision.Child (First)).Ready
        and then Families.Current
          (Item, Flyology.Supervision.Child (First)).Generation = 4;
      if Ada.Real_Time.Clock >= Deadline then
         Families.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with "health replacement did not become ready";
      end if;
      delay 0.001;
   end loop;
   First := Families.Latest (Item, Flyology.Supervision.Child (First));

   declare
      Observation : constant Flyology.Supervision.Generation_Observation :=
        Families.Wait_Termination (Item, Second, Timeout => 0.0);
   begin
      pragma Assert
        (Observation.Status = Flyology.Supervision.Observation_Timed_Out);
   end;

   pragma Assert (State.Started.Value (1) = 4);
   pragma Assert
     (Families.Current (Item, First).Task_Model = Flyology.Native_Task);
   Families.Stop (Item, First);
   declare
      Observation : constant Flyology.Supervision.Generation_Observation :=
        Families.Wait_Termination (Item, First, Timeout => 2.0);
   begin
      pragma Assert
        (Observation.Status = Flyology.Supervision.Generation_Terminated);
      pragma Assert (Observation.Snapshot.Generation = 4);
   end;
   loop
      exit when Families.Current (Item, First).State =
        Flyology.Supervision.Joined;
      if Ada.Real_Time.Clock >= Deadline then
         Families.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with "family child did not stop";
      end if;
      delay 0.001;
   end loop;

   loop
      begin
         Families.Start (Item, 3, Reused);
         exit;
      exception
         when Constraint_Error =>
            if Ada.Real_Time.Clock >= Deadline then
               Families.Request_Shutdown (Item);
               Owner.Join;
               raise Program_Error with "family slot was not reclaimed";
            end if;
            delay 0.001;
      end;
   end loop;
   pragma Assert
     (Flyology.Supervision.Child (Reused) =
        Flyology.Supervision.Child (First));
   pragma Assert
     (Flyology.Supervision.Current_Generation (Reused) = 5);
   pragma Assert (Families.Current (Item, Reused).Attempts = 0);
   pragma Assert
     (Families.Current (Item, Reused).Backoff =
        Ada.Real_Time.Time_Span_Zero);
   begin
      declare
         Ignored : constant Flyology.Supervision.Child_Snapshot :=
           Families.Current (Item, First);
      begin
         pragma Unreferenced (Ignored);
         raise Program_Error with "stale family handle was accepted";
      end;
   exception
      when Families.Stale_Handle => null;
   end;

   loop
      exit when Families.Current (Item, Reused).Ready;
      if Ada.Real_Time.Clock >= Deadline then
         Families.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with "reused family slot did not become ready";
      end if;
      delay 0.001;
   end loop;
   pragma Assert (Families.Current (Item, Reused).Attempts = 0);

   --  Stop linearizes before later intervention commands. The generation can
   --  still be live until its manager observes the request, but it is no
   --  longer eligible for a manual restart or failed-health report.
   Families.Stop (Item, Reused);
   begin
      Families.Restart (Item, Reused);
      raise Program_Error with "restart was accepted after stop";
   exception
      when Families.Stale_Handle => null;
   end;
   begin
      Families.Report_Unhealthy (Item, Reused, "too late after stop");
      raise Program_Error with "health report was accepted after stop";
   exception
      when Families.Stale_Handle => null;
   end;

   --  Shutdown closes the same gate atomically for every still-running slot.
   --  Second is deliberately left running until this point so the regression
   --  does not pass merely because the supplied generation already joined.
   Families.Request_Shutdown (Item);
   begin
      Families.Restart (Item, Second);
      raise Program_Error with "restart was accepted after shutdown";
   exception
      when Families.Stale_Handle => null;
   end;
   begin
      Families.Report_Unhealthy (Item, Second, "too late after shutdown");
      raise Program_Error with "health report was accepted after shutdown";
   exception
      when Families.Stale_Handle => null;
   end;
   Owner.Join;
   Families.Read_Events (Item, Cursor, Events, Event_Count, Dropped);
   pragma Assert (Event_Count = Events'Length);
   pragma Assert (Dropped > 0);
   for Index in Events'First + 1 .. Events'Last loop
      pragma Assert
        (Events (Index - 1).Sequence < Events (Index).Sequence);
      pragma Assert (Events (Index).Task_Model = Flyology.Native_Task);
   end loop;
   pragma Assert
     (Result.Outcome = Flyology.Supervision.Shutdown_Completed);
   for Input in Request loop
      pragma Assert
        (State.Resources.Acquisitions (Input) =
           State.Resources.Releases (Input));
   end loop;

   declare
      Pre_Shutdown : aliased Families.Family;
      Pre_Result   : Flyology.Supervision.Supervisor_Result;
   begin
      Families.Request_Shutdown (Pre_Shutdown);
      Families.Run (Pre_Shutdown, State, Pre_Result);
      pragma Assert (not Families.Accepting (Pre_Shutdown));
      pragma Assert
        (Pre_Result.Outcome = Flyology.Supervision.Shutdown_Completed);
   end;
exception
   when others =>
      --  Preserve the original failure instead of hanging at the Ada master
      --  while the owner and a live family child still depend on this scope.
      Families.Request_Shutdown (Item);
      select
         Owner.Join;
      or
         delay 2.0;
      end select;
      raise;
end Flyology.Supervision.Families_Smoke;
