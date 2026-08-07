with Ada.Real_Time;
with Ada.Task_Identification;
with Flyology.Cancellation;
with Flyology.Supervision.Families;
with Flyology.Supervision.Input_Task_Generations;

procedure Flyology.Supervision.Families_Shutdown_Smoke is
   use type Ada.Real_Time.Time;

   type Request is (Fail_Once);
   type Count_Array is array (Request) of Natural;

   protected type Counts is
      procedure Increment (Value : Request; Attempt : out Positive);
      function Read (Value : Request) return Natural;
   private
      Values : Count_Array := (others => 0);
   end Counts;

   protected body Counts is
      procedure Increment (Value : Request; Attempt : out Positive) is
      begin
         Values (Value) := Values (Value) + 1;
         Attempt := Values (Value);
      end Increment;

      function Read (Value : Request) return Natural is (Values (Value));
   end Counts;

   type Context is limited record
      Started : Counts;
      Factory : Counts;
   end record;

   task type Subject_Task
     (State   : not null access Context;
      Input   : not null access constant Request;
      Control : not null access Generation_Control);

   task body Subject_Task is
      Attempt : Positive;
   begin
      State.Started.Increment (Input.all, Attempt);
      Mark_Ready (Control.all);
      if Attempt = 1 then
         raise Program_Error with "injected family failure";
      end if;
      loop
         if Stop_Requested (Control.all) then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.001;
      end loop;
   end Subject_Task;

   function Create
     (State   : not null access Context;
      Input   : not null access constant Request;
      Control : not null access Generation_Control) return Subject_Task
   is
   begin
      return Item : Subject_Task (State, Input, Control);
   end Create;

   function Identity
     (Item : in out Subject_Task) return Ada.Task_Identification.Task_Id is
     (Item'Identity);

   procedure Abort_Task (Item : in out Subject_Task) is
   begin
      abort Item;
   end Abort_Task;

   package Generations is new Flyology.Supervision.Input_Task_Generations
     (Input_Type          => Request,
      Application_Context => Context,
      Generation_Task     => Subject_Task,
      Create              => Create,
      Task_Identity       => Identity,
      Abort_Task          => Abort_Task);

   procedure Run_Generation
     (State   : aliased in out Context;
      Input   : Request;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      Attempt : Positive;
   begin
      State.Factory.Increment (Input, Attempt);
      Generations.Run (State, Input, Control, Result);
   end Run_Generation;

   Policy : constant Child_Specification :=
     (Restart           => On_Failure,
      Impact            => Isolate_Child,
      Recovery          =>
        (Burst_Attempts    => 3,
         Window            => Ada.Real_Time.Seconds (2),
         Total_Attempts    => 3,
         Initial_Backoff   => Ada.Real_Time.Milliseconds (500),
         Maximum_Backoff   => Ada.Real_Time.Milliseconds (500),
         Stability_Reset   => Ada.Real_Time.Seconds (1),
         Recovery_Deadline => Ada.Real_Time.Seconds (2)),
      Stopping          => Default_Stop_Policy,
      Readiness_Timeout => Ada.Real_Time.Seconds (1),
      Restart_Safe      => True,
      Task_Model        => Native_Task,
      Has_Group         => False,
      Group             => 0);

   package Families is new Flyology.Supervision.Families
     (Request             => Request,
      Application_Context => Context,
      Run_One_Generation  => Run_Generation,
      Policy              => Policy,
      First_Child_Id      => 20_000_000_000,
      Maximum_Children   => 2,
      Event_Capacity     => 16);

   procedure Wait_Open (Item : Families.Family) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      loop
         exit when Families.Accepting (Item);
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "family admission did not open";
         end if;
         delay 0.001;
      end loop;
   end Wait_Open;
begin
   --  Shutdown must cancel an admitted recovery wait and must not construct a
   --  replacement generation after admission has closed.
   declare
      State  : aliased Context;
      Item   : aliased Families.Family;
      Result : Supervisor_Result;
      Handle : Child_Handle;
      Timed_Out : Boolean := False;

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
   begin
      Owner.Start;
      Wait_Open (Item);
      Families.Start (Item, Fail_Once, Handle);
      loop
         exit when Families.Current (Item, Child (Handle)).State = Backing_Off;
         delay 0.001;
      end loop;
      Families.Request_Shutdown (Item);
      select
         Owner.Join;
      or
         delay 0.100;
         Timed_Out := True;
      end select;
      if Timed_Out then
         Owner.Join;
         raise Program_Error with "shutdown slept through family backoff";
      end if;
      if State.Factory.Read (Fail_Once) /= 1 then
         raise Program_Error with
           "shutdown constructed" &
           Natural'Image (State.Factory.Read (Fail_Once)) &
           " family generations";
      end if;
      pragma Assert (Result.Outcome = Shutdown_Completed);
   end;
end Flyology.Supervision.Families_Shutdown_Smoke;
