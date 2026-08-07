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
   use type Interfaces.Unsigned_64;

   Test_Failure : exception;

   subtype Request is Positive range 1 .. 8;
   type Count_Array is array (Request) of Natural;

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

   type Context is limited record
      Started : Counts;
   end record;

   task type Family_Task
     (State   : not null access Context;
      Input   : not null access constant Request;
      Control : not null access Flyology.Supervision.Generation_Control)
   with CPU => System.Multiprocessors.Not_A_Specific_CPU is
      pragma Task_Info (Flyology.Native_Task);
   end Family_Task;

   task body Family_Task is
      Attempt : Positive;
   begin
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
   exception
      when Flyology.Cancellation.Operation_Cancelled =>
         Flyology.Supervision.Report_Cancellation (Control.all);
      when Occurrence : others =>
         Flyology.Supervision.Report_Exception (Control.all, Occurrence);
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
         Initial_Backoff   => Ada.Real_Time.Time_Span_Zero,
         Maximum_Backoff   => Ada.Real_Time.Milliseconds (4),
         Stability_Reset   => Ada.Real_Time.Seconds (1),
         Recovery_Deadline => Ada.Real_Time.Seconds (2)),
      Stopping          => Flyology.Supervision.Default_Stop_Policy,
      Readiness_Timeout => Ada.Real_Time.Seconds (1),
      Restart_Safe      => True,
      Lane              => Flyology.Supervision.Native_Lane,
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
   Families.Start (Item, 2, Second);
   loop
      exit when Families.Current
        (Item, Flyology.Supervision.Child (First)).Ready
        and then Families.Current
          (Item, Flyology.Supervision.Child (First)).Generation = 2
        and then Families.Current (Item, Second).Ready;
      if Ada.Real_Time.Clock >= Deadline then
         Families.Request_Shutdown (Item);
         Owner.Join;
         raise Program_Error with "family children did not become ready";
      end if;
      delay 0.001;
   end loop;
   First := Families.Latest (Item, Flyology.Supervision.Child (First));

   pragma Assert (State.Started.Value (1) = 2);
   Families.Stop (Item, First);
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
     (Flyology.Supervision.Current_Generation (Reused) = 3);
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

   Families.Request_Shutdown (Item);
   Owner.Join;
   Families.Read_Events (Item, Cursor, Events, Event_Count, Dropped);
   pragma Assert (Event_Count = Events'Length);
   pragma Assert (Dropped > 0);
   for Index in Events'First + 1 .. Events'Last loop
      pragma Assert
        (Events (Index - 1).Sequence < Events (Index).Sequence);
   end loop;
   pragma Assert
     (Result.Outcome = Flyology.Supervision.Shutdown_Completed);
end Flyology.Supervision.Families_Smoke;
