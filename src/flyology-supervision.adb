package body Flyology.Supervision is
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;

   protected Incident_Source is
      procedure Next (Value : out Incident_Id);
   private
      Last : Interfaces.Unsigned_64 := 0;
   end Incident_Source;

   protected body Incident_Source is
      procedure Next (Value : out Incident_Id) is
      begin
         if Last = Interfaces.Unsigned_64'Last then
            raise Program_Error with "supervision incident space exhausted";
         end if;
         Last := Last + 1;
         Value := Incident_Id (Last);
      end Next;
   end Incident_Source;

   protected body Generation_Control_State is
      procedure Open
        (Value    : Child_Handle;
         Incident : Incident_Context)
      is
      begin
         if Opened then
            raise Program_Error with "generation control is one-shot";
         end if;
         Generation_Control_State.Value := Value;
         Generation_Control_State.Incident := Incident;
         Opened := True;
      end Open;

      procedure Publish_Ready is
      begin
         if not Opened then
            raise Program_Error with "generation control is inactive";
         elsif Ready then
            raise Program_Error with "generation is already ready";
         elsif Stopping then
            raise Program_Error with "generation is stopping";
         end if;
         Ready := True;
      end Publish_Ready;

      procedure Publish_Stop (Shutdown : Boolean) is
      begin
         if not Opened then
            raise Program_Error with "generation control is inactive";
         end if;
         Stopping := True;
         Shutdown_Stop := Shutdown_Stop or else Shutdown;
      end Publish_Stop;

      procedure Publish_Abort is
      begin
         if not Opened or else not Stopping then
            raise Program_Error with
              "abort requires an active stopping generation";
         end if;
         Abort_Requested := True;
      end Publish_Abort;

      procedure Publish_Escalation (Incident : Incident_Context) is
      begin
         if not Opened then
            raise Program_Error with "generation control is inactive";
         elsif not Incident.Is_Active then
            raise Program_Error with "escalation incident is inactive";
         end if;
         Generation_Control_State.Incident := Incident;
         Escalated := True;
      end Publish_Escalation;

      procedure Publish_Termination (Value : Termination_Summary) is
      begin
         if not Opened then
            raise Program_Error with "generation control is inactive";
         elsif Termination_Reported then
            raise Program_Error with "generation outcome is already reported";
         end if;
         Termination := Value;
         Termination_Reported := True;
      end Publish_Termination;

      procedure Close_Incident is
      begin
         if not Opened then
            raise Program_Error with "generation control is inactive";
         elsif not Ready then
            raise Program_Error with
              "recovery incident cannot close before readiness";
         elsif not Escalated then
            Incident := No_Incident;
         end if;
      end Close_Incident;

      function Current_Handle return Child_Handle is
      begin
         if not Opened then
            raise Program_Error with "generation control is inactive";
         end if;
         return Value;
      end Current_Handle;

      function Is_Ready return Boolean is (Ready);

      function Is_Stopping return Boolean is (Stopping);

      function Is_Shutdown return Boolean is (Shutdown_Stop);

      function Is_Abort_Requested return Boolean is (Abort_Requested);

      function Current_Incident return Incident_Context is (Incident);

      procedure Read_Termination
        (Reported : out Boolean;
         Value    : out Termination_Summary) is
      begin
         Reported := Termination_Reported;
         Value := Termination;
      end Read_Termination;
   end Generation_Control_State;

   function Base_Summary
     (Kind : Termination_Kind) return Termination_Summary is
     ((Kind           => Kind,
       Exception_Id   => Ada.Exceptions.Null_Id,
       Task_Id        => Ada.Task_Identification.Current_Task,
       Message_Length => 0,
       Message        => (others => ' ')));

   function Active (Context : Incident_Context) return Boolean is
     (Context.Is_Active);

   function Incident (Context : Incident_Context) return Incident_Id is
   begin
      if not Context.Is_Active then
         raise Program_Error with "recovery incident is inactive";
      end if;
      return Context.Id;
   end Incident;

   function Attempt
     (Context : Incident_Context) return Incident_Attempt is
   begin
      if not Context.Is_Active then
         raise Program_Error with "recovery incident is inactive";
      end if;
      return Context.Number;
   end Attempt;

   function Recovery_Deadline
     (Context : Incident_Context) return Ada.Real_Time.Time is
   begin
      if not Context.Is_Active then
         raise Program_Error with "recovery incident is inactive";
      end if;
      return Context.Deadline;
   end Recovery_Deadline;

   function Child (Handle : Child_Handle) return Child_Id is (Handle.Id);

   function Current_Generation
     (Handle : Child_Handle) return Generation is
     (Handle.Generation);

   function Is_Current
     (Handle : Child_Handle;
      Id     : Child_Id;
      Value  : Generation) return Boolean is
     (Handle.Id = Id and then Handle.Generation = Value);

   function Handle (Control : Generation_Control) return Child_Handle is
     (Control.State.Current_Handle);

   function Stopping
     (Control : aliased in out Generation_Control)
      return not null access Flyology.Cancellation.Token is
     (Control.Stop_Token'Access);

   procedure Mark_Ready (Control : in out Generation_Control) is
   begin
      Control.State.Publish_Ready;
   end Mark_Ready;

   function Stop_Requested
     (Control : Generation_Control) return Boolean is
     (Control.State.Is_Stopping);

   function Abort_Requested
     (Control : Generation_Control) return Boolean is
     (Control.State.Is_Abort_Requested);

   function Recovery_Incident
     (Control : Generation_Control) return Incident_Context is
     (Control.State.Current_Incident);

   procedure Report_Escalation
     (Control : in out Generation_Control;
      Context : Incident_Context) is
   begin
      Control.State.Publish_Escalation (Context);
   end Report_Escalation;

   procedure Report_Normal_Return (Control : in out Generation_Control) is
   begin
      Control.State.Publish_Termination (Base_Summary (Normal_Return));
   end Report_Normal_Return;

   procedure Report_Cancellation (Control : in out Generation_Control) is
   begin
      Control.State.Publish_Termination
        (Base_Summary
           (if Shutdown_Stop (Control)
            then Supervisor_Shutdown
            else Cancelled));
   end Report_Cancellation;

   procedure Report_Exception
     (Control    : in out Generation_Control;
      Occurrence : Ada.Exceptions.Exception_Occurrence)
   is
      Message : constant String :=
        Ada.Exceptions.Exception_Message (Occurrence);
      Length  : constant Diagnostic_Length :=
        Diagnostic_Length'Min
          (Diagnostic_Length'Last, Message'Length);
      Value   : Termination_Summary := Base_Summary (Unhandled_Exception);
   begin
      Value.Exception_Id := Ada.Exceptions.Exception_Identity (Occurrence);
      Value.Message_Length := Length;
      if Length > 0 then
         Value.Message (1 .. Length) :=
           Message (Message'First .. Message'First + Length - 1);
      end if;
      Control.State.Publish_Termination (Value);
   end Report_Exception;

   procedure Open
     (Control : in out Generation_Control;
      Value   : Child_Handle;
      Incident : Incident_Context := No_Incident) is
   begin
      Control.State.Open (Value, Incident);
   end Open;

   function New_Incident
     (Now      : Ada.Real_Time.Time;
      Deadline : Ada.Real_Time.Time) return Incident_Context
   is
      Id : Incident_Id;
   begin
      Incident_Source.Next (Id);
      return
        (Is_Active => True,
         Id        => Id,
         Number    => Incident_Attempt'First,
         Deadline  => (if Deadline < Now then Now else Deadline));
   end New_Incident;

   function Next_Attempt
     (Context : Incident_Context) return Incident_Context is
   begin
      if not Context.Is_Active then
         raise Program_Error with "recovery incident is inactive";
      elsif Context.Number = Incident_Attempt'Last then
         raise Program_Error with "recovery incident attempts exhausted";
      end if;
      return
        (Is_Active => True,
         Id        => Context.Id,
         Number    => Context.Number + 1,
         Deadline  => Context.Deadline);
   end Next_Attempt;

   procedure Close_Recovery_Incident
     (Control : in out Generation_Control) is
   begin
      Control.State.Close_Incident;
   end Close_Recovery_Incident;

   procedure Request_Stop
     (Control  : in out Generation_Control;
      Shutdown : Boolean) is
   begin
      --  Publish the scalar state first so a wake-source failure cannot hide
      --  the stop request from a polling child or the structured runner.
      Control.State.Publish_Stop (Shutdown);
      Control.Stop_Token.Request;
   end Request_Stop;

   procedure Request_Abort (Control : in out Generation_Control) is
   begin
      Control.State.Publish_Abort;
   end Request_Abort;

   function Is_Ready (Control : Generation_Control) return Boolean is
     (Control.State.Is_Ready);

   function Shutdown_Stop (Control : Generation_Control) return Boolean is
     (Control.State.Is_Shutdown);

   procedure Read_Termination
     (Control  : in out Generation_Control;
      Reported : out Boolean;
      Value    : out Termination_Summary) is
   begin
      Control.State.Read_Termination (Reported, Value);
   end Read_Termination;

end Flyology.Supervision;
