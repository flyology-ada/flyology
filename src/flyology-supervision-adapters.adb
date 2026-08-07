with Ada.Task_Identification;
with Flyology.Task_Results;

package body Flyology.Supervision.Adapters is
   use type Ada.Task_Identification.Task_Id;
   use type Flyology.Task_Results.Observation_Status;

   procedure Run
     (Context : aliased in out Application_Context;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      Item : Service := Create (Context'Access);

      task Service_Owner with CPU => Generation_CPU is
         pragma Task_Info (Generation_Model);
      end Service_Owner;

      task body Service_Owner is
      begin
         Run_Service (Item, Context);
      end Service_Owner;

      Stop_Forwarded  : Boolean := False;
      Ready_Published : Boolean := False;
      Abort_Forwarded : Boolean := False;
      Observation : Flyology.Task_Results.Task_Observation;
      Reported : Boolean;
      Summary  : Termination_Summary;

      procedure Forward_Stop is
      begin
         if not Stop_Forwarded then
            Stop_Forwarded := True;
            Request_Shutdown (Item);
         end if;
      end Forward_Stop;
   begin
      loop
         Observation := Flyology.Task_Results.Wait
           (Service_Owner'Identity, Timeout => Poll_Interval);
         exit when Observation.Status = Flyology.Task_Results.Terminal;

         if not Ready_Published and then Ready (Item) then
            Mark_Ready (Control);
            Ready_Published := True;
         end if;
         if Stop_Requested (Control) then
            Forward_Stop;
         end if;
         if Abort_Requested (Control) and then not Abort_Forwarded then
            Abort_Forwarded := True;
            abort Service_Owner;
         end if;
      end loop;

      Read_Termination (Control, Reported, Summary);
      if not Reported then
         Summary := From_Task_Result
           (Control, Service_Owner'Identity, Observation.Result);
      end if;
      if Summary.Task_Id = Ada.Task_Identification.Null_Task_Id then
         Summary.Task_Id := Service_Owner'Identity;
      end if;
      Result :=
        (Termination    => Summary,
         Reported_Ready => Is_Ready (Control),
         Incident       => Recovery_Incident (Control));
   exception
      when others =>
         begin
            Forward_Stop;
         exception
            when others =>
               null;
         end;
         raise;
   end Run;

begin
   if Generation_Model not in
     Flyology.Lightweight_Task | Flyology.Native_Task
   then
      raise Program_Error with
        "supervision adapter requires a concrete execution model";
   elsif Poll_Interval <= 0.0 then
      raise Program_Error with
        "supervision adapter poll interval must be positive";
   end if;
end Flyology.Supervision.Adapters;
