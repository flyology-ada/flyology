with Ada.Command_Line;
with Ada.Text_IO;

with Flyology;
with System.Multiprocessors;

procedure Native_CPU_Activation_Failure_Smoke is
   subtype CPU_Range is System.Multiprocessors.CPU_Range;

   function Selected_CPU return CPU_Range is
   begin
      if Ada.Command_Line.Argument_Count /= 1 then
         raise Program_Error with "expected one excluded Ada CPU";
      end if;

      return CPU_Range'Value (Ada.Command_Line.Argument (1));
   end Selected_CPU;

   task type Rejected_Task (Assigned_CPU : CPU_Range)
     with CPU => Assigned_CPU is
      pragma Task_Info (Flyology.Native_Task);
   end Rejected_Task;

   task body Rejected_Task is
   begin
      null;
   end Rejected_Task;

   Excluded_CPU           : constant CPU_Range := Selected_CPU;
   Tasking_Error_Observed : Boolean := False;

begin
   begin
      declare
         Subject : Rejected_Task (Excluded_CPU);
         pragma Unreferenced (Subject);

      begin
         null;
      end;
   exception
      when Tasking_Error =>
         Tasking_Error_Observed := True;
   end;

   if not Tasking_Error_Observed then
      raise Program_Error with "native task on an excluded CPU did not fail activation";
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

   Ada.Text_IO.Put_Line ("native excluded-CPU activation reported Tasking_Error without deadlock");
end Native_CPU_Activation_Failure_Smoke;
