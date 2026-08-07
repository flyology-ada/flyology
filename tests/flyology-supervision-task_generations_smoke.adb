with Ada.Exceptions;
with Ada.Finalization;
with Ada.Task_Identification;
with Flyology.Cancellation;
with Flyology.Supervision.Input_Task_Generations;
with Flyology.Supervision.Task_Generations;
with System.Multiprocessors;

procedure Flyology.Supervision.Task_Generations_Smoke is
   use type Ada.Exceptions.Exception_Id;
   use type Ada.Task_Identification.Task_Id;

   Test_Failure : exception;

   protected type Counter is
      procedure Increment;
      function Value return Natural;
   private
      Count : Natural := 0;
   end Counter;

   protected body Counter is
      procedure Increment is
      begin
         Count := Count + 1;
      end Increment;

      function Value return Natural is (Count);
   end Counter;

   type Guard (Finalized : not null access Counter) is
     new Ada.Finalization.Limited_Controlled with null record;

   overriding procedure Finalize (Item : in out Guard);

   overriding procedure Finalize (Item : in out Guard) is
   begin
      Item.Finalized.Increment;
   end Finalize;

   type Run_Mode is
     (Return_Normally,
      Raise_Exception,
      Initialize_Failure,
      Await_Stop,
      Await_Abort);

   type Context is limited record
      Mode       : Run_Mode := Return_Normally;
      Began      : Counter;
      Finalized  : aliased Counter;
   end record;

   task type Service_Task
     (State   : not null access Context;
      Control : not null access Generation_Control;
      Instance : Positive)
   with CPU => System.Multiprocessors.Not_A_Specific_CPU is
      pragma Task_Info (Flyology.Native_Task);
      entry Begin_Service;
      entry Application_Entry;
   end Service_Task;

   task body Service_Task is
   begin
      accept Begin_Service;
      declare
         Cleanup : Guard (State.Finalized'Access);
         pragma Unreferenced (Cleanup);
      begin
         if Instance /= 42 then
            raise Test_Failure with "wrong task-specific discriminant";
         end if;
         State.Began.Increment;
         Mark_Ready (Control.all);
         case State.Mode is
            when Return_Normally =>
               accept Application_Entry;
            when Raise_Exception =>
               raise Test_Failure with "application task failed";
            when Initialize_Failure | Await_Stop =>
               loop
                  if Stop_Requested (Control.all) then
                     raise Flyology.Cancellation.Operation_Cancelled;
                  end if;
                  delay 0.001;
               end loop;
            when Await_Abort =>
               loop
                  delay 0.001;
               end loop;
         end case;
      end;
      Report_Normal_Return (Control.all);
   exception
      when Flyology.Cancellation.Operation_Cancelled =>
         Report_Cancellation (Control.all);
      when Occurrence : others =>
         Report_Exception (Control.all, Occurrence);
   end Service_Task;

   function Create
     (State   : not null access Context;
      Control : not null access Generation_Control) return Service_Task
   is
   begin
      return Subject : Service_Task (State, Control, Instance => 42);
   end Create;

   procedure Initialize
     (Subject : in out Service_Task;
      Control : aliased in out Generation_Control)
   is
      pragma Unreferenced (Control);
   begin
      Subject.Begin_Service;
      if Subject.State.Mode = Initialize_Failure then
         raise Test_Failure with "task-specific initialization failed";
      end if;
      if Subject.State.Mode = Return_Normally then
         Subject.Application_Entry;
      end if;
   end Initialize;

   function Task_Identity
     (Subject : in out Service_Task)
      return Ada.Task_Identification.Task_Id is
     (Subject'Identity);

   procedure Abort_Task (Subject : in out Service_Task) is
   begin
      abort Subject;
   end Abort_Task;

   package Service_Generations is new Task_Generations
     (Application_Context => Context,
      Generation_Task     => Service_Task,
      Initialize          => Initialize);

   task type Stopper
     (Control       : not null access Generation_Control;
      Request_Abort : Boolean);

   task body Stopper is
   begin
      loop
         exit when Is_Ready (Control.all);
         delay 0.001;
      end loop;
      Flyology.Supervision.Request_Stop (Control.all, Shutdown => True);
      if Request_Abort then
         Flyology.Supervision.Request_Abort (Control.all);
      end if;
   end Stopper;

   procedure Check_Service
     (Mode                : Run_Mode;
      Expected            : Termination_Kind;
      Expected_Finalizers : Natural)
   is
      State   : aliased Context := (Mode => Mode, others => <>);
      Control : aliased Generation_Control;
      Result  : Generation_Result;
   begin
      Open
        (Control,
         (Id         => Child_Id (9_000 + Run_Mode'Pos (Mode)),
          Generation => 1));
      if Mode in Await_Stop | Await_Abort then
         declare
            Requester : Stopper
              (Control'Access, Request_Abort => Mode = Await_Abort);
         begin
            Service_Generations.Run (State, Control, Result);
         end;
      else
         Service_Generations.Run (State, Control, Result);
      end if;

      pragma Assert (Result.Termination.Kind = Expected);
      pragma Assert (Result.Reported_Ready);
      pragma Assert (State.Began.Value = 1);
      pragma Assert (State.Finalized.Value = Expected_Finalizers);
      if Mode in Raise_Exception | Initialize_Failure then
         pragma Assert
           (Result.Termination.Exception_Id = Test_Failure'Identity);
      end if;
   end Check_Service;

   subtype Input is Positive range 1 .. 10;

   type Input_Context is limited record
      Observed  : Counter;
      Finalized : aliased Counter;
   end record;

   task type Input_Task
     (State   : not null access Input_Context;
      Value   : not null access constant Input;
      Control : not null access Generation_Control;
      Tag     : Positive)
   with CPU => System.Multiprocessors.Not_A_Specific_CPU is
      pragma Task_Info (Flyology.Native_Task);
      entry Start (Expected : Input);
   end Input_Task;

   task body Input_Task is
   begin
      declare
         Cleanup : Guard (State.Finalized'Access);
         pragma Unreferenced (Cleanup);
      begin
         if Tag /= 99 then
            raise Test_Failure with "wrong input task discriminant";
         end if;
         accept Start (Expected : Input) do
            if Value.all /= Expected then
               raise Test_Failure with "typed input changed";
            end if;
         end Start;
         State.Observed.Increment;
         Mark_Ready (Control.all);
      end;
      Report_Normal_Return (Control.all);
   exception
      when Occurrence : others =>
         Report_Exception (Control.all, Occurrence);
   end Input_Task;

   function Create
     (State   : not null access Input_Context;
      Value   : not null access constant Input;
      Control : not null access Generation_Control) return Input_Task
   is
   begin
      return Subject : Input_Task (State, Value, Control, Tag => 99);
   end Create;

   procedure Initialize_Input
     (Subject : in out Input_Task;
      Control : aliased in out Generation_Control)
   is
      pragma Unreferenced (Control);
   begin
      Subject.Start (Subject.Value.all);
   end Initialize_Input;

   function Task_Identity
     (Subject : in out Input_Task)
      return Ada.Task_Identification.Task_Id is
     (Subject'Identity);

   procedure Abort_Task (Subject : in out Input_Task) is
   begin
      abort Subject;
   end Abort_Task;

   package Input_Generations is new Input_Task_Generations
     (Input_Type          => Input,
      Application_Context => Input_Context,
      Generation_Task     => Input_Task,
      Initialize          => Initialize_Input);

begin
   Check_Service (Return_Normally, Normal_Return, 1);
   Check_Service (Raise_Exception, Unhandled_Exception, 1);
   Check_Service (Initialize_Failure, Unhandled_Exception, 1);
   Check_Service (Await_Stop, Supervisor_Shutdown, 1);
   Check_Service (Await_Abort, Abnormal_Completion, 1);

   declare
      State   : aliased Input_Context;
      Control : aliased Generation_Control;
      Result  : Generation_Result;
   begin
      Open (Control, (Id => 10_000, Generation => 1));
      Input_Generations.Run (State, 7, Control, Result);
      pragma Assert (Result.Termination.Kind = Normal_Return);
      pragma Assert (Result.Reported_Ready);
      pragma Assert (State.Observed.Value = 1);
      pragma Assert (State.Finalized.Value = 1);
   end;
end Flyology.Supervision.Task_Generations_Smoke;
