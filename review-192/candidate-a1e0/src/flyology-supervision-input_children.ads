with System.Multiprocessors;

--  Convenience adapter that turns an application procedure into one
--  structured Ada task generation with a typed immutable input. Applications
--  that define their own task type use Supervision.Input_Task_Generations.
--  Each call owns a fresh task object and joins it before returning.
--  @formal Input_Type Typed generation input retained by the caller
--  @formal Application_Context Generation callback state
--  @formal Execute Application task body
--  @formal Task_Model Lightweight or native task designation
--  @formal Task_CPU CPU aspect for the generation task

generic
   type Input_Type is private;
   type Application_Context (<>) is limited private;

   --  Run one application generation with its family-owned input.
   --  @param Context State kept alive by the enclosing supervisor scope
   --  @param Input Immutable typed input retained through task join
   --  @param Control Borrowed generation-local readiness and stop channel
   with
     procedure Execute
       (Context : in out Application_Context;
        Input   : Input_Type;
        Control : not null access Generation_Control);

   Task_Model : Flyology.Execution_Model := Flyology.Project_Default;
   Task_CPU : System.Multiprocessors.CPU_Range := System.Multiprocessors.Not_A_Specific_CPU;

package Flyology.Supervision.Input_Children
is

   --  Create, activate, observe, and join one typed-input generation. Normal
   --  return, escaping exceptions, and abnormal completion are classified
   --  automatically from the task-owned terminal result.
   --  @param Context Application state retained through the complete call
   --  @param Input Immutable generation input
   --  @param Control Fresh generation control opened by the supervisor
   --  @param Result Bounded outcome available after task join
   --  @exception Tasking_Error Generation task activation failed
   procedure Run
     (Context : aliased in out Application_Context;
      Input   : Input_Type;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result);

end Flyology.Supervision.Input_Children;
