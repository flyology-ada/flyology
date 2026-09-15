with Ada.Exceptions;
with Ada.Finalization;
with Ada.Real_Time;
with Ada.Task_Identification;
with Flyology.Cancellation;
with Flyology.Supervision.Families;
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

      function Value return Natural
      is (Count);
   end Counter;

   type Guard (Finalized : not null access Counter) is new Ada.Finalization.Limited_Controlled
   with null record;

   overriding
   procedure Finalize (Item : in out Guard);

   overriding
   procedure Finalize (Item : in out Guard) is
   begin
      Item.Finalized.Increment;
   end Finalize;

   type Run_Mode is
     (Return_Normally,
      Raise_Exception,
      Override_Exception,
      Initialize_Failure,
      Initialize_Failure_After_Ready,
      Await_Stop,
      Await_Abort);

   type Context is limited record
      Mode      : Run_Mode := Return_Normally;
      Began     : Counter;
      Finalized : aliased Counter;
   end record;

   task type Service_Task
     (State    : not null access Context;
      Control  : not null access Generation_Control;
      Instance : Positive)
     with CPU => System.Multiprocessors.Not_A_Specific_CPU
   is
      pragma Task_Info (Flyology.Native_Task);
      entry Begin_Service;
      entry Application_Entry;
      entry Ready_Acknowledgement;
   end Service_Task;

   task body Service_Task is
      procedure Await_Stop_Request is
      begin
         loop
            if Stop_Requested (Control.all) then
               raise Flyology.Cancellation.Operation_Cancelled;
            end if;
            delay 0.001;
         end loop;
      end Await_Stop_Request;
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
         if State.Mode /= Initialize_Failure then
            Mark_Ready (Control.all);
         end if;
         case State.Mode is
            when Return_Normally                 =>
               accept Application_Entry;

            when Raise_Exception                 =>
               raise Test_Failure with "application task failed";

            when Override_Exception              =>
               begin
                  raise Test_Failure with "translated application failure";
               exception
                  when Occurrence : others =>
                     Report_Exception (Control.all, Occurrence);
               end;

            when Initialize_Failure_After_Ready  =>
               --  Order readiness before the initializer exception so this
               --  case cannot race the resulting stop publication.
               accept Ready_Acknowledgement;
               Await_Stop_Request;

            when Initialize_Failure | Await_Stop =>
               Await_Stop_Request;

            when Await_Abort                     =>
               loop
                  delay 0.001;
               end loop;
         end case;
      end;
   end Service_Task;

   function Create
     (State : not null access Context; Control : not null access Generation_Control) return Service_Task is
   begin
      return Subject : Service_Task (State, Control, Instance => 42);
   end Create;

   procedure Initialize (Subject : in out Service_Task; Control : aliased in out Generation_Control) is
      pragma Unreferenced (Control);
   begin
      Subject.Begin_Service;
      if Subject.State.Mode = Initialize_Failure then
         raise Test_Failure with "task-specific initialization failed";
      elsif Subject.State.Mode = Initialize_Failure_After_Ready then
         Subject.Ready_Acknowledgement;
         raise Test_Failure with "task-specific initialization failed";
      end if;
      if Subject.State.Mode = Return_Normally then
         Subject.Application_Entry;
      end if;
   end Initialize;

   function Task_Identity (Subject : in out Service_Task) return Ada.Task_Identification.Task_Id
   is (Subject'Identity);

   procedure Abort_Task (Subject : in out Service_Task) is
   begin
      abort Subject;
   end Abort_Task;

   package Service_Generations is new
     Task_Generations
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
     (Mode : Run_Mode; Expected : Termination_Kind; Expected_Ready : Boolean; Expected_Finalizers : Natural)
   is
      State   : aliased Context := (Mode => Mode, others => <>);
      Control : aliased Generation_Control;
      Result  : Generation_Result;
   begin
      Open
        (Control,
         (Controller => New_Controller, Id => Child_Id (9_000 + Run_Mode'Pos (Mode)), Generation => 1));
      if Mode in Await_Stop | Await_Abort then
         declare
            Requester : Stopper (Control'Access, Request_Abort => Mode = Await_Abort);
         begin
            Service_Generations.Run (State, Control, Result);
         end;
      else
         Service_Generations.Run (State, Control, Result);
      end if;

      pragma Assert (Result.Termination.Kind = Expected);
      pragma Assert (Result.Reported_Ready = Expected_Ready);
      pragma Assert (State.Began.Value = 1);
      pragma Assert (State.Finalized.Value = Expected_Finalizers);
      if Mode = Raise_Exception then
         pragma Assert (Result.Termination.Exception_Id = Ada.Exceptions.Null_Id);
         pragma
           Assert
             (Exception_Name_Text (Result.Termination)
                = Ada.Exceptions.Exception_Name (Test_Failure'Identity));
         pragma Assert (Message_Text (Result.Termination) = "application task failed");
      elsif Mode in Override_Exception | Initialize_Failure | Initialize_Failure_After_Ready then
         pragma Assert (Result.Termination.Exception_Id = Test_Failure'Identity);
         pragma
           Assert
             (Exception_Name_Text (Result.Termination)
                = Ada.Exceptions.Exception_Name (Test_Failure'Identity));
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
     with CPU => System.Multiprocessors.Not_A_Specific_CPU
   is
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
   end Input_Task;

   function Create
     (State   : not null access Input_Context;
      Value   : not null access constant Input;
      Control : not null access Generation_Control) return Input_Task is
   begin
      return Subject : Input_Task (State, Value, Control, Tag => 99);
   end Create;

   procedure Initialize_Input (Subject : in out Input_Task; Control : aliased in out Generation_Control) is
      pragma Unreferenced (Control);
   begin
      Subject.Start (Subject.Value.all);
   end Initialize_Input;

   function Task_Identity (Subject : in out Input_Task) return Ada.Task_Identification.Task_Id
   is (Subject'Identity);

   procedure Abort_Task (Subject : in out Input_Task) is
   begin
      abort Subject;
   end Abort_Task;

   package Input_Generations is new
     Input_Task_Generations
       (Input_Type          => Input,
        Application_Context => Input_Context,
        Generation_Task     => Input_Task,
        Initialize          => Initialize_Input);

   generic
      Model : Flyology.Execution_Model;
   procedure Check_Diagnostic_Identity;

   procedure Check_Diagnostic_Identity is
      use type Ada.Real_Time.Time;
      use type Flyology.Execution_Model;

      type Outcome is (Automatic_Return, Reported_Return, Reported_Unhealthy);
      type Identity_Context is limited record
         Mode      : Outcome := Automatic_Return;
         Captured  : Ada.Task_Identification.Task_Id := Ada.Task_Identification.Null_Task_Id;
         Reported  : Ada.Task_Identification.Task_Id := Ada.Task_Identification.Null_Task_Id;
         Finalized : aliased Counter;
      end record;

      task type Identity_Task
        (State : not null access Identity_Context; Control : not null access Generation_Control)
      is
         pragma Task_Info (Model);
         entry Start;
      end Identity_Task;

      task body Identity_Task is
      begin
         accept Start;
         declare
            Cleanup : Guard (State.Finalized'Access);
            pragma Unreferenced (Cleanup);
         begin
            pragma Assert (State.Captured /= Ada.Task_Identification.Null_Task_Id);
            pragma Assert (Ada.Task_Identification.Current_Task = State.Captured);
            Mark_Ready (Control.all);
         end;
         case State.Mode is
            when Automatic_Return =>
               null;
            when Reported_Return =>
               Report_Normal_Return (Control.all);
               declare
                  Reported : Boolean;
                  Summary  : Termination_Summary;
               begin
                  Read_Termination (Control.all, Reported, Summary);
                  pragma Assert (Reported);
                  State.Reported := Summary.Task_Id;
               end;
            when Reported_Unhealthy =>
               Report_Unhealthy (Control.all, "input generation unhealthy");
         end case;
      end Identity_Task;

      function Create
        (State : not null access Identity_Context; Control : not null access Generation_Control)
         return Identity_Task is
      begin
         return Subject : Identity_Task (State, Control);
      end Create;

      function Create
        (State   : not null access Identity_Context;
         Value   : not null access constant Outcome;
         Control : not null access Generation_Control) return Identity_Task is
      begin
         State.Mode := Value.all;
         return Subject : Identity_Task (State, Control);
      end Create;

      function Task_Identity (Subject : in out Identity_Task) return Ada.Task_Identification.Task_Id is
      begin
         Subject.State.Captured := Subject'Identity;
         return Subject.State.Captured;
      end Task_Identity;

      procedure Initialize (Subject : in out Identity_Task; Control : aliased in out Generation_Control) is
         pragma Unreferenced (Control);
      begin
         Subject.Start;
      end Initialize;

      procedure Abort_Task (Subject : in out Identity_Task) is
      begin
         abort Subject;
      end Abort_Task;

      package Plain is new Task_Generations
        (Application_Context => Identity_Context, Generation_Task => Identity_Task, Initialize => Initialize);
      package Inputs is new Input_Task_Generations
        (Input_Type => Outcome, Application_Context => Identity_Context,
         Generation_Task => Identity_Task, Initialize => Initialize);
      Child_Policy : constant Child_Specification :=
        (Restart => Never, Impact => Isolate_Child, Task_Model => Model, others => <>);
      package Identity_Families is new Families
        (Request => Outcome, Application_Context => Identity_Context,
         Run_One_Generation => Inputs.Run, Policy => Child_Policy,
         First_Child_Id => 11_000, Maximum_Children => 1);

      procedure Check_Summary (State : Identity_Context; Summary : Termination_Summary) is
      begin
         --  Captured while Subject was alive. Only compare opaque diagnostic
         --  values here; Run has already destroyed the generation task object.
         pragma Assert (State.Captured /= Ada.Task_Identification.Null_Task_Id);
         pragma Assert (Summary.Task_Id = State.Captured);
         pragma Assert (State.Finalized.Value = 1);
         pragma
           Assert (Summary.Kind = (if State.Mode = Reported_Unhealthy then Unhealthy else Normal_Return));
         if State.Mode = Reported_Unhealthy then
            pragma Assert (Message_Text (Summary) = "input generation unhealthy");
         elsif State.Mode = Reported_Return then
            pragma Assert (State.Reported /= Ada.Task_Identification.Null_Task_Id);
            pragma Assert (Summary.Task_Id = State.Reported);
         end if;
      end Check_Summary;

      procedure Check_Run (Mode : Outcome; Input_Runner : Boolean) is
         State   : aliased Identity_Context;
         Control : aliased Generation_Control;
         Result  : Generation_Result;
      begin
         State.Mode := Mode;
         Open (Control, (Controller => New_Controller, Id => 11_000, Generation => 1));
         if Input_Runner then
            Inputs.Run (State, Mode, Control, Result);
         else
            Plain.Run (State, Control, Result);
         end if;
         pragma Assert (Result.Reported_Ready);
         Check_Summary (State, Result.Termination);
      end Check_Run;

      procedure Check_Family (Mode : Outcome) is
         State       : aliased Identity_Context;
         Item        : aliased Identity_Families.Family;
         Result      : Supervisor_Result;
         Handle      : Child_Handle;
         Observation : Generation_Observation;
         Deadline    : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
      begin
         declare
            task Owner;
            task body Owner is
            begin
               Identity_Families.Run (Item, State, Result);
            end Owner;
         begin
            loop
               exit when Identity_Families.Accepting (Item);
               if Ada.Real_Time.Clock >= Deadline then
                  raise Test_Failure with "identity family did not open admission";
               end if;
               delay 0.001;
            end loop;
            Identity_Families.Start (Item, Mode, Handle);
            Observation := Identity_Families.Wait_Termination (Item, Handle, Timeout => 2.0);
            Identity_Families.Request_Shutdown (Item);
         exception
            when others =>
               Identity_Families.Request_Shutdown (Item);
               raise;
         end;
         pragma Assert (Observation.Status = Generation_Terminated);
         Check_Summary (State, Observation.Snapshot.Termination);
         declare
            Snapshot : constant Child_Snapshot := Identity_Families.Current (Item, Handle);
         begin
            pragma Assert (Snapshot.State = Joined);
            pragma Assert (Snapshot.Task_Model = Model);
            Check_Summary (State, Snapshot.Termination);
         end;
      end Check_Family;
   begin
      for Mode in Outcome loop
         Check_Run (Mode, Input_Runner => False);
         Check_Run (Mode, Input_Runner => True);
         Check_Family (Mode);
      end loop;
   end Check_Diagnostic_Identity;

   procedure Check_Lightweight_Identity is new Check_Diagnostic_Identity (Flyology.Lightweight_Task);
   procedure Check_Native_Identity is new Check_Diagnostic_Identity (Flyology.Native_Task);

begin
   Check_Service (Return_Normally, Normal_Return, True, 1);
   Check_Service (Raise_Exception, Unhandled_Exception, True, 1);
   Check_Service (Override_Exception, Unhandled_Exception, True, 1);
   Check_Service (Initialize_Failure, Unhandled_Exception, False, 1);
   Check_Service (Initialize_Failure_After_Ready, Unhandled_Exception, True, 1);
   Check_Service (Await_Stop, Supervisor_Shutdown, True, 1);
   Check_Service (Await_Abort, Abnormal_Completion, True, 1);

   declare
      State   : aliased Input_Context;
      Control : aliased Generation_Control;
      Result  : Generation_Result;
   begin
      Open (Control, (Controller => New_Controller, Id => 10_000, Generation => 1));
      Input_Generations.Run (State, 7, Control, Result);
      pragma Assert (Result.Termination.Kind = Normal_Return);
      pragma Assert (Result.Reported_Ready);
      pragma Assert (State.Observed.Value = 1);
      pragma Assert (State.Finalized.Value = 1);
   end;
   Check_Lightweight_Identity;
   Check_Native_Identity;
end Flyology.Supervision.Task_Generations_Smoke;
