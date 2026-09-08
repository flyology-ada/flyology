with Ada.Interrupts;
with Ada.Interrupts.Names;
with Flyology;
with Flyology.Execution_Groups;
with GNAT.OS_Lib;
with Interrupt_Service_Handler;

procedure Interrupt_Service_Native_Smoke is
   use type Flyology.Execution_Groups.Group_Id;

   protected Progress is
      procedure Release;
      entry Await_Release;
      procedure Step;
      entry Await_Completion;
   private
      Released   : Boolean := False;
      Step_Count : Natural := 0;
   end Progress;

   protected body Progress is
      procedure Release is
      begin
         Released := True;
      end Release;

      entry Await_Release when Released is
      begin
         null;
      end Await_Release;

      procedure Step is
      begin
         Step_Count := Step_Count + 1;
      end Step;

      entry Await_Completion when Step_Count = 3 is
      begin
         null;
      end Await_Completion;
   end Progress;

   task Lightweight_Worker is
      pragma Task_Info (Flyology.Project_Default);
   end Lightweight_Worker;

   task body Lightweight_Worker is
   begin
      Progress.Await_Release;
      if Flyology.Execution_Groups.Current /= 0 then
         GNAT.OS_Lib.OS_Exit (2);
      end if;
      for Iteration in 1 .. 3 loop
         Progress.Step;
         delay 0.01;
      end loop;
   end Lightweight_Worker;

   Signal : constant Ada.Interrupts.Interrupt_ID :=
     Ada.Interrupts.Names.SIGUSR1;
begin
   Ada.Interrupts.Attach_Handler
     (Interrupt_Service_Handler.Handler.Handle'Access, Signal);

   --  Let the interrupt server reach its blocking wait before making the
   --  single execution group's application worker runnable.
   delay 0.20;
   Progress.Release;
   select
      Progress.Await_Completion;
   or
      delay 1.0;
      GNAT.OS_Lib.OS_Exit (1);
   end select;

   Ada.Interrupts.Detach_Handler (Signal);
end Interrupt_Service_Native_Smoke;
