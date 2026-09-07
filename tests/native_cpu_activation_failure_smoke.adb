with Ada.Text_IO;

with Flyology;
with Native_CPU_Activation_Failure_Hook;
with System.Multiprocessors;

procedure Native_CPU_Activation_Failure_Smoke is
   subtype CPU_Range is System.Multiprocessors.CPU_Range;

   task type Rejected_Task
     (Assigned_CPU : CPU_Range)
     with CPU => Assigned_CPU
   is
      pragma Task_Info (Flyology.Native_Task);
   end Rejected_Task;

   task body Rejected_Task is
   begin
      null;
   end Rejected_Task;

   --  Exercise GNARL's explicit-affinity setup before the wrapped creation.
   Assigned_CPU           : constant CPU_Range :=
     CPU_Range'Succ (System.Multiprocessors.Not_A_Specific_CPU);
   Tasking_Error_Observed : Boolean := False;

begin
   Native_CPU_Activation_Failure_Hook.Arm;

   begin
      declare
         Subject : Rejected_Task (Assigned_CPU);
         pragma Unreferenced (Subject);

      begin
         null;
      end;
   exception
      when Tasking_Error =>
         Tasking_Error_Observed := True;
   end;

   if not Tasking_Error_Observed then
      raise Program_Error
        with "rejected native pthread creation did not fail activation";
   end if;

   declare
      task Follow_Up_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Follow_Up_Task;

      task body Follow_Up_Task is
      begin
         null;
      end Follow_Up_Task;

   begin
      null;
   end;

   Ada.Text_IO.Put_Line
     ("rejected native pthread creation reported Tasking_Error without deadlock");
end Native_CPU_Activation_Failure_Smoke;
