with Ada.Exceptions;
with Flyology.Task_Results;

package body Flyology.Supervision.Input_Task_Generations is
   use type Ada.Task_Identification.Task_Id;
   use type Flyology.Task_Results.Observation_Status;

   function Exception_Summary
     (Occurrence : Ada.Exceptions.Exception_Occurrence; Task_Id : Ada.Task_Identification.Task_Id)
      return Termination_Summary
   is
      Name        : constant String :=
        Ada.Exceptions.Exception_Name (Ada.Exceptions.Exception_Identity (Occurrence));
      Message     : constant String := Ada.Exceptions.Exception_Message (Occurrence);
      Name_Length : constant Exception_Name_Length :=
        Exception_Name_Length'Min (Exception_Name_Length'Last, Name'Length);
      Length      : constant Diagnostic_Length :=
        Diagnostic_Length'Min (Diagnostic_Length'Last, Message'Length);
      Value       : Termination_Summary :=
        (Kind                     => Unhandled_Exception,
         Exception_Id             => Ada.Exceptions.Exception_Identity (Occurrence),
         Exception_Name_Length    => Name_Length,
         Exception_Name_Truncated => Name'Length > Name_Length,
         Exception_Name           => (others => ' '),
         Task_Id                  => Task_Id,
         Message_Length           => Length,
         Message_Truncated        => Message'Length > Length,
         Message                  => (others => ' '));
   begin
      if Name_Length > 0 then
         Value.Exception_Name (1 .. Name_Length) := Name (Name'First .. Name'First + Name_Length - 1);
      end if;
      if Length > 0 then
         Value.Message (1 .. Length) := Message (Message'First .. Message'First + Length - 1);
      end if;
      return Value;
   end Exception_Summary;

   procedure Run
     (Context : aliased in out Application_Context;
      Input   : Input_Type;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      Stable_Input       : aliased constant Input_Type := Input;
      Subject            : Generation_Task := Create (Context'Access, Stable_Input'Access, Control'Access);
      Identity           : constant Ada.Task_Identification.Task_Id := Task_Identity (Subject);
      Reported           : Boolean := False;
      Summary            : Termination_Summary;
      Initialize_Failed  : Boolean := False;
      Initialize_Summary : Termination_Summary;
      Automatic_Result   : Flyology.Task_Results.Task_Result;
   begin
      begin
         Initialize (Subject, Control);
      exception
         when Occurrence : others =>
            Initialize_Failed := True;
            Initialize_Summary := Exception_Summary (Occurrence, Identity);
            Request_Stop (Control, Shutdown => False);
      end;
      declare
         Observation     : Flyology.Task_Results.Task_Observation;
         Abort_Triggered : Boolean := False;
      begin
         select
            Control.State.Await_Abort;
            Abort_Triggered := True;
         then abort
            Observation := Flyology.Task_Results.Wait (Identity);
         end select;
         if Abort_Triggered then
            Observation := Flyology.Task_Results.Wait (Identity, Timeout => 0.0);
            if Observation.Status /= Flyology.Task_Results.Terminal then
               Abort_Task (Subject);
               Observation := Flyology.Task_Results.Wait (Identity);
            end if;
         end if;
         Automatic_Result := Observation.Result;
      end;

      Read_Termination (Control, Reported, Summary);
      if Initialize_Failed then
         Summary := Initialize_Summary;
      elsif not Reported then
         Summary := From_Task_Result (Control, Identity, Automatic_Result);
      end if;
      if Summary.Task_Id = Ada.Task_Identification.Null_Task_Id then
         Summary.Task_Id := Identity;
      end if;
      Result :=
        (Termination    => Summary,
         Reported_Ready => Is_Ready (Control),
         Incident       => Recovery_Incident (Control));
   end Run;

end Flyology.Supervision.Input_Task_Generations;
