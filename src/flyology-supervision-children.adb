with Ada.Exceptions;
with Ada.Task_Identification;
with Flyology.Cancellation;

package body Flyology.Supervision.Children is

   function Base_Summary
     (Kind    : Termination_Kind;
      Task_Id : Ada.Task_Identification.Task_Id :=
        Ada.Task_Identification.Current_Task) return Termination_Summary is
     ((Kind           => Kind,
       Exception_Id   => Ada.Exceptions.Null_Id,
       Task_Id        => Task_Id,
       Message_Length => 0,
       Message        => (others => ' ')));

   function Exception_Summary
     (Occurrence : Ada.Exceptions.Exception_Occurrence)
      return Termination_Summary
   is
      Message : constant String :=
        Ada.Exceptions.Exception_Message (Occurrence);
      Length  : constant Diagnostic_Length :=
        Diagnostic_Length'Min
          (Diagnostic_Length'Last, Message'Length);
      Result  : Termination_Summary :=
        Base_Summary (Unhandled_Exception);
   begin
      Result.Exception_Id := Ada.Exceptions.Exception_Identity (Occurrence);
      Result.Message_Length := Length;
      if Length > 0 then
         Result.Message (1 .. Length) :=
           Message (Message'First .. Message'First + Length - 1);
      end if;
      return Result;
   end Exception_Summary;

   procedure Run
     (Context : aliased in out Application_Context;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      task Subject with CPU => Task_CPU is
         pragma Task_Info (Task_Model);
         entry Collect (Value : out Termination_Summary);
      end Subject;

      task body Subject is
         Summary : Termination_Summary;
      begin
         begin
            Execute (Context, Control'Access);
            Summary := Base_Summary (Normal_Return);
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Summary :=
                 Base_Summary
                   (if Shutdown_Stop (Control)
                    then Supervisor_Shutdown
                    else Cancelled);
            when Occurrence : others =>
               Summary := Exception_Summary (Occurrence);
         end;
         accept Collect (Value : out Termination_Summary) do
            Value := Summary;
         end Collect;
      end Subject;

      Done    : Boolean := False;
      Summary : Termination_Summary;
      Aborted : Boolean := False;
   begin
      loop
         select
            Subject.Collect (Summary);
            Done := True;
         else
            null;
         end select;
         exit when Done;
         exit when Aborted
           and then Ada.Task_Identification.Is_Terminated
             (Subject'Identity);
         if Abort_Requested (Control) and then not Aborted then
            Aborted := True;
            abort Subject;
         end if;
         delay 0.001;
      end loop;

      while Done
        and then not Ada.Task_Identification.Is_Terminated (Subject'Identity)
      loop
         delay 0.001;
      end loop;
      if not Done then
         Summary := Base_Summary (Abnormal_Completion, Subject'Identity);
      end if;
      Result :=
        (Termination    => Summary,
         Reported_Ready => Is_Ready (Control),
         Incident       => Recovery_Incident (Control));
   exception
      when others =>
         --  An abort may prevent Subject from reaching its wrapper handler.
         --  The enclosing master still joins it before this handler runs.
         if not Done then
            Summary := Base_Summary
              (Abnormal_Completion, Subject'Identity);
         end if;
         Result :=
           (Termination    => Summary,
            Reported_Ready => Is_Ready (Control),
            Incident       => Recovery_Incident (Control));
   end Run;

end Flyology.Supervision.Children;
