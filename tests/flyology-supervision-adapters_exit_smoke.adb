with Ada.Exceptions;
with Ada.Task_Identification;
with Flyology.Supervision.Adapters;

procedure Flyology.Supervision.Adapters_Exit_Smoke is
   use type Ada.Task_Identification.Task_Id;

   Service_Error : exception;
   type Exit_Mode is (Raise_Exception, Abort_Abnormally);

   protected type Observation_State is
      procedure Started (Identity : Ada.Task_Identification.Task_Id);
      function Identity return Ada.Task_Identification.Task_Id;
   private
      Value : Ada.Task_Identification.Task_Id :=
        Ada.Task_Identification.Null_Task_Id;
   end Observation_State;

   protected body Observation_State is
      procedure Started (Identity : Ada.Task_Identification.Task_Id) is
      begin
         Value := Identity;
      end Started;

      function Identity return Ada.Task_Identification.Task_Id is (Value);
   end Observation_State;

   type Context is limited record
      Mode  : Exit_Mode := Raise_Exception;
      State : Observation_State;
   end record;

   type Service (State : not null access Context) is limited null record;

   function Create (State : not null access Context) return Service is
   begin
      return Item : Service (State);
   end Create;

   procedure Run_Service
     (Item    : in out Service;
      Context : aliased in out Adapters_Exit_Smoke.Context)
   is
      pragma Unreferenced (Context);
   begin
      Item.State.State.Started (Ada.Task_Identification.Current_Task);
      case Item.State.Mode is
         when Raise_Exception =>
            raise Service_Error with "service exception retained";
         when Abort_Abnormally =>
            Ada.Task_Identification.Abort_Task
              (Ada.Task_Identification.Current_Task);
      end case;
   end Run_Service;

   procedure Request_Shutdown (Item : in out Service) is
      pragma Unreferenced (Item);
   begin
      null;
   end Request_Shutdown;

   function Ready (Item : Service) return Boolean is
      pragma Unreferenced (Item);
   begin
      return False;
   end Ready;

   package Native_Adapter is new Flyology.Supervision.Adapters
     (Application_Context => Context,
      Service             => Service,
      Create              => Create,
      Run_Service         => Run_Service,
      Request_Shutdown    => Request_Shutdown,
      Ready               => Ready,
      Generation_Model    => Native_Task);

   package Lightweight_Adapter is new Flyology.Supervision.Adapters
     (Application_Context => Context,
      Service             => Service,
      Create              => Create,
      Run_Service         => Run_Service,
      Request_Shutdown    => Request_Shutdown,
      Ready               => Ready,
      Generation_Model    => Lightweight_Task,
      Generation_CPU      => 2);

   generic
      with procedure Run
        (Context : aliased in out Adapters_Exit_Smoke.Context;
         Control : aliased in out Generation_Control;
         Result  : out Generation_Result);
   procedure Check_Exit (Mode : Exit_Mode);

   procedure Check_Exit (Mode : Exit_Mode) is
      State   : aliased Context;
      Control : aliased Generation_Control;
      Result  : Generation_Result;
   begin
      State.Mode := Mode;
      Open
        (Control,
         (Controller => New_Controller, Id => 71, Generation => 1));
      Run (State, Control, Result);
      pragma Assert
        (Result.Termination.Task_Id = State.State.Identity);
      case Mode is
         when Raise_Exception =>
            pragma Assert (Result.Termination.Kind = Unhandled_Exception);
            pragma Assert
              (Exception_Name_Text (Result.Termination) =
                 Ada.Exceptions.Exception_Name (Service_Error'Identity));
            pragma Assert
              (Message_Text (Result.Termination) =
                 "service exception retained");
         when Abort_Abnormally =>
            pragma Assert (Result.Termination.Kind = Abnormal_Completion);
      end case;
   end Check_Exit;

   procedure Check_Native is new Check_Exit (Native_Adapter.Run);
   procedure Check_Lightweight is new Check_Exit (Lightweight_Adapter.Run);

   function Fail_Activation return Integer is
   begin
      raise Program_Error with "injected service activation failure";
      return 0;
   end Fail_Activation;

   task type Failing_Task;

   task body Failing_Task is
      Marker : constant Integer := Fail_Activation;
      pragma Unreferenced (Marker);
   begin
      null;
   end Failing_Task;

   type Failing_Service is limited record
      Subject : Failing_Task;
   end record;

   type Failing_Context is limited null record;

   function Create_Failing
     (State : not null access Failing_Context) return Failing_Service
   is
      pragma Unreferenced (State);
   begin
      return Item : Failing_Service;
   end Create_Failing;

   procedure Run_Failing
     (Item    : in out Failing_Service;
      Context : aliased in out Failing_Context)
   is
      pragma Unreferenced (Item, Context);
   begin
      null;
   end Run_Failing;

   procedure Stop_Failing (Item : in out Failing_Service) is
      pragma Unreferenced (Item);
   begin
      null;
   end Stop_Failing;

   function Failing_Ready (Item : Failing_Service) return Boolean is
      pragma Unreferenced (Item);
   begin
      return False;
   end Failing_Ready;

   package Failing_Adapter is new Flyology.Supervision.Adapters
     (Application_Context => Failing_Context,
      Service             => Failing_Service,
      Create              => Create_Failing,
      Run_Service         => Run_Failing,
      Request_Shutdown    => Stop_Failing,
      Ready               => Failing_Ready,
      Generation_Model    => Native_Task);
begin
   Check_Native (Raise_Exception);
   Check_Native (Abort_Abnormally);
   Check_Lightweight (Raise_Exception);
   Check_Lightweight (Abort_Abnormally);

   declare
      State   : aliased Failing_Context;
      Control : aliased Generation_Control;
      Result  : Generation_Result;
   begin
      Open
        (Control,
         (Controller => New_Controller, Id => 72, Generation => 1));
      begin
         Failing_Adapter.Run (State, Control, Result);
         raise Program_Error with
           "service activation failure did not propagate Tasking_Error";
      exception
         when Tasking_Error => null;
      end;
   end;
end Flyology.Supervision.Adapters_Exit_Smoke;
