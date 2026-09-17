with Ada.Exceptions;
with Flyology.IO;
with Flyology.Operations;
with Flyology.Task_Results;

package body Flyology.Supervision.Task_Generations is
   use type Ada.Task_Identification.Task_Id;

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
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      Subject            : Generation_Task := Create (Context'Access, Control'Access);
      Identity           : constant Ada.Task_Identification.Task_Id := Task_Identity (Subject);
      Reported           : Boolean := False;
      Summary            : Termination_Summary;
      Aborted            : Boolean := False;
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
         Abort_FD          : Flyology.IO.Descriptor;
         Already_Requested : Boolean;
      begin
         Control.Abort_Token.Wait_Source (Abort_FD, Already_Requested);
         if Already_Requested then
            Abort_Task (Subject);
            Aborted := True;
            Automatic_Result := Flyology.Task_Results.Wait (Identity).Result;
         else
            declare
               Set         : aliased Flyology.Operations.Completion_Set (2);
               Task_Wait   : Flyology.Task_Results.Wait_Operation :=
                 Flyology.Task_Results.Wait (Set'Access, Identity);
               Abort_Wait  : Flyology.IO.Readiness_Operation :=
                 Flyology.IO.Wait (Set'Access, Abort_FD, Flyology.IO.For_Read);
               Batch       : Flyology.Operations.Completion_Batch (Set.Capacity);
               Observation : Flyology.Task_Results.Task_Observation;
            begin
               loop
                  Flyology.Operations.Wait_Some (Set, Batch);
                  exit when Batch.Count > 0 and then Flyology.Operations.Is_Terminal (Task_Wait);
                  if Flyology.Operations.Is_Terminal (Abort_Wait) and then not Aborted then
                     Abort_Task (Subject);
                     Aborted := True;
                  end if;
               end loop;
               Flyology.Task_Results.Finish (Task_Wait, Observation);
               Automatic_Result := Observation.Result;
               if Flyology.Operations.Is_Active (Abort_Wait) then
                  Flyology.Operations.Cancel (Abort_Wait);
                  Flyology.Operations.Wait_All (Set);
               end if;
               Flyology.Operations.Consume (Abort_Wait);
            end;
         end if;
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

end Flyology.Supervision.Task_Generations;
