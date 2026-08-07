with Ada.Exceptions;

package body Flyology.Supervision.Task_Generations is

   function Abnormal_Summary
     (Task_Id : Ada.Task_Identification.Task_Id) return Termination_Summary is
     ((Kind           => Abnormal_Completion,
       Exception_Id   => Ada.Exceptions.Null_Id,
       Task_Id        => Task_Id,
       Message_Length => 0,
       Message        => (others => ' ')));

   function Exception_Summary
     (Occurrence : Ada.Exceptions.Exception_Occurrence;
      Task_Id    : Ada.Task_Identification.Task_Id)
      return Termination_Summary
   is
      Message : constant String :=
        Ada.Exceptions.Exception_Message (Occurrence);
      Length  : constant Diagnostic_Length :=
        Diagnostic_Length'Min
          (Diagnostic_Length'Last, Message'Length);
      Value   : Termination_Summary :=
        (Kind           => Unhandled_Exception,
         Exception_Id   => Ada.Exceptions.Exception_Identity (Occurrence),
         Task_Id        => Task_Id,
         Message_Length => Length,
         Message        => (others => ' '));
   begin
      if Length > 0 then
         Value.Message (1 .. Length) :=
           Message (Message'First .. Message'First + Length - 1);
      end if;
      return Value;
   end Exception_Summary;

   procedure Run
     (Context : aliased in out Application_Context;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      Subject  : Generation_Task :=
        Create (Context'Access, Control'Access);
      Identity : constant Ada.Task_Identification.Task_Id :=
        Task_Identity (Subject);
      Reported           : Boolean := False;
      Summary            : Termination_Summary;
      Aborted            : Boolean := False;
      Initialize_Failed  : Boolean := False;
      Initialize_Summary : Termination_Summary;
   begin
      begin
         Initialize (Subject, Control);
      exception
         when Occurrence : others =>
            Initialize_Failed := True;
            Initialize_Summary := Exception_Summary (Occurrence, Identity);
            Request_Stop (Control, Shutdown => False);
      end;
      loop
         exit when Ada.Task_Identification.Is_Terminated (Identity);
         if Abort_Requested (Control) and then not Aborted then
            Abort_Task (Subject);
            Aborted := True;
         end if;
         delay 0.001;
      end loop;

      Read_Termination (Control, Reported, Summary);
      if Initialize_Failed then
         Summary := Initialize_Summary;
      elsif not Reported then
         Summary := Abnormal_Summary (Identity);
      end if;
      Result :=
        (Termination    => Summary,
         Reported_Ready => Is_Ready (Control),
         Incident       => Recovery_Incident (Control));
   end Run;

end Flyology.Supervision.Task_Generations;
