with Ada.Task_Identification;
with Flyology.Supervision.Adapters;

procedure Flyology.Supervision.Adapters_Smoke is
   use type Ada.Task_Identification.Task_Id;

   protected type Service_State is
      procedure Begin_Run;
      procedure Stop;
      function Running return Boolean;
      function Stopping return Boolean;
   private
      Is_Running  : Boolean := False;
      Is_Stopping : Boolean := False;
   end Service_State;

   protected body Service_State is
      procedure Begin_Run is
      begin
         Is_Running := True;
      end Begin_Run;

      procedure Stop is
      begin
         Is_Stopping := True;
      end Stop;

      function Running return Boolean
      is (Is_Running);
      function Stopping return Boolean
      is (Is_Stopping);
   end Service_State;

   type Context is limited record
      State : Service_State;
   end record;

   type Service (State : not null access Context) is limited null record;

   function Create (State : not null access Context) return Service is
   begin
      return Item : Service (State);
   end Create;

   procedure Run_Service (Item : in out Service; Context : aliased in out Adapters_Smoke.Context) is
      pragma Unreferenced (Context);
   begin
      Item.State.State.Begin_Run;
      while not Item.State.State.Stopping loop
         delay 0.001;
      end loop;
   end Run_Service;

   procedure Request_Shutdown (Item : in out Service) is
   begin
      Item.State.State.Stop;
   end Request_Shutdown;

   function Ready (Item : Service) return Boolean
   is (Item.State.State.Running);

   package Native_Adapter is new
     Flyology.Supervision.Adapters
       (Application_Context => Context,
        Service             => Service,
        Create              => Create,
        Run_Service         => Run_Service,
        Request_Shutdown    => Request_Shutdown,
        Ready               => Ready,
        Generation_Model    => Flyology.Native_Task);

   package Lightweight_Adapter is new
     Flyology.Supervision.Adapters
       (Application_Context => Context,
        Service             => Service,
        Create              => Create,
        Run_Service         => Run_Service,
        Request_Shutdown    => Request_Shutdown,
        Ready               => Ready,
        Generation_Model    => Flyology.Lightweight_Task,
        Generation_CPU      => 2);

   generic
      with
        procedure Run
          (Context : aliased in out Adapters_Smoke.Context;
           Control : aliased in out Generation_Control;
           Result  : out Generation_Result);
   procedure Check;

   procedure Check is
      State   : aliased Context;
      Control : aliased Generation_Control;
      Result  : Generation_Result;

      task Owner is
         entry Start;
         entry Join;
      end Owner;

      task body Owner is
      begin
         accept Start;
         Run (State, Control, Result);
         accept Join;
      end Owner;
   begin
      Open (Control, (Controller => New_Controller, Id => 61, Generation => 1));
      Owner.Start;
      while not Is_Ready (Control) loop
         delay 0.001;
      end loop;

      --  A generation-local failed health probe is retained automatically and
      --  causes the adapter to forward cooperative shutdown to the service.
      Report_Unhealthy (Control, "adapter probe failed");
      Owner.Join;
      pragma Assert (Result.Reported_Ready);
      pragma Assert (Result.Termination.Kind = Unhealthy);
      pragma Assert (Message_Text (Result.Termination) = "adapter probe failed");
      pragma Assert (Result.Termination.Task_Id /= Ada.Task_Identification.Null_Task_Id);
   end Check;

   procedure Check_Native is new Check (Native_Adapter.Run);
   procedure Check_Lightweight is new Check (Lightweight_Adapter.Run);
begin
   Check_Native;
   Check_Lightweight;
end Flyology.Supervision.Adapters_Smoke;
