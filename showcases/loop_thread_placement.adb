with Ada.Text_IO;
with Flyology;
with Flyology.Execution_Groups;

procedure Loop_Thread_Placement is
   use Ada.Text_IO;
   package Groups renames Flyology.Execution_Groups;

   use type Groups.Loop_Thread_Placement;
   use type Groups.Placement_Configuration_Result;

   Values : array (1 .. 2) of Groups.Placement_Value := (101, 202);
   Kind   : Groups.Loop_Thread_Placement := Groups.No_Placement;

   protected Output is
      procedure Report
        (Group     : Groups.Group_Id;
         Processor : Integer);
      entry Wait;
   private
      Reports : Natural := 0;
   end Output;

   protected body Output is
      procedure Report
        (Group     : Groups.Group_Id;
         Processor : Integer)
      is
         Status : constant Groups.Placement_Status :=
           Groups.Loop_Thread_Status (Group);
      begin
         Put_Line
           ("logical_group=" & Group'Image
            & " placement=" & Status.Kind'Image
            & " requested_value=" & Status.Value'Image
            & " state=" & Status.State'Image
            & " observed_linux_cpu=" & Processor'Image);
         Reports := Reports + 1;
      end Report;

      entry Wait when Reports = 2 is
      begin
         null;
      end Wait;
   end Output;

   task type First_Worker with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end First_Worker;
   task type Second_Worker with CPU => 2 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Second_Worker;

   task body First_Worker is
   begin
      Output.Report (Groups.Current, Groups.Current_Processor);
   end First_Worker;

   task body Second_Worker is
   begin
      Output.Report (Groups.Current, Groups.Current_Processor);
   end Second_Worker;

   type First_Access is access First_Worker;
   type Second_Access is access Second_Worker;
   First  : First_Access;
   Second : Second_Access;
   pragma Unreferenced (First, Second);

   procedure Select_Linux_CPUs is
      Candidate : Groups.Placement_Value := 0;
   begin
      for Index in Values'Range loop
         while Candidate < 4_096
           and then not Groups.Placement_Value_Available
             (Groups.Strict_CPU, Candidate)
         loop
            Candidate := Candidate + 1;
         end loop;
         if Candidate = 4_096 then
            if Index = Values'First then
               raise Program_Error with "no Linux CPU is available";
            end if;
            Values (Index) := Values (Index - 1);
         else
            Values (Index) := Candidate;
            Candidate := Candidate + 1;
         end if;
      end loop;
   end Select_Linux_CPUs;
begin
   Put_Line
     ("CPU => N selects logical event-loop group N; loop-thread placement "
      & "is a separate, explicit policy.");

   if Groups.Placement_Supported (Groups.Strict_CPU) then
      Kind := Groups.Strict_CPU;
      Select_Linux_CPUs;
      Put_Line
        ("Linux strict mode requests and verifies one zero-based OS logical "
         & "CPU per scheduler pthread.");
   elsif Groups.Placement_Supported (Groups.Advisory_Tag) then
      Kind := Groups.Advisory_Tag;
      Put_Line
        ("Darwin advisory mode supplies cache-locality tags; tags are not "
         & "physical CPU numbers.");
   else
      Put_Line
        ("This host exposes neither Linux strict affinity nor a supported "
         & "Darwin advisory tag policy; groups remain distinct pthreads "
         & "scheduled by the OS.");
   end if;

   if Kind /= Groups.No_Placement then
      for Index in Values'Range loop
         if Groups.Configure_Loop_Thread
           (Groups.Group_Id (Index), Kind, Values (Index)) /= Groups.Configured
         then
            raise Program_Error with "cannot configure showcase loop";
         end if;
      end loop;
   end if;

   First := new First_Worker;
   Second := new Second_Worker;
   Output.Wait;
end Loop_Thread_Placement;
