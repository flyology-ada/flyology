with Ada.Task_Identification;
with Flyology.Supervision.Input_Task_Generations;

package body Flyology.Supervision.Input_Children is

   task type Subject_Task
     (Context : not null access Application_Context;
      Input   : not null access constant Input_Type;
      Control : not null access Generation_Control)
   with CPU => Task_CPU is
      pragma Task_Info (Task_Model);
   end Subject_Task;

   task body Subject_Task is
   begin
      Execute (Context.all, Input.all, Control);
   end Subject_Task;

   function Create
     (Context : not null access Application_Context;
      Input   : not null access constant Input_Type;
      Control : not null access Generation_Control) return Subject_Task
   is
   begin
      return Subject : Subject_Task (Context, Input, Control);
   end Create;

   function Identity
     (Subject : in out Subject_Task)
      return Ada.Task_Identification.Task_Id is
     (Subject'Identity);

   procedure Abort_Subject (Subject : in out Subject_Task) is
   begin
      abort Subject;
   end Abort_Subject;

   package Generations is new Flyology.Supervision.Input_Task_Generations
     (Input_Type          => Input_Type,
      Application_Context => Application_Context,
      Generation_Task     => Subject_Task,
      Create              => Create,
      Task_Identity       => Identity,
      Abort_Task          => Abort_Subject);

   procedure Run
     (Context : aliased in out Application_Context;
      Input   : Input_Type;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result) renames Generations.Run;

end Flyology.Supervision.Input_Children;
