with System.Multiprocessors;

--  Convenience adapter that turns an application procedure into one
--  structured Ada task generation with a fixed execution model. Applications
--  that define their own task type use Supervision.Task_Generations instead.
--  Each call owns a fresh task object and returns only after its Ada master
--  has joined the task and completed task-body finalization.
--  @formal Application_Context Generation callback state
--  @formal Execute Application task body
--  @formal Task_Model Lightweight or native task designation
--  @formal Task_CPU CPU aspect for the generation task

generic
   type Application_Context (<>) is limited private;

   --  Run one application generation. Execute must call Mark_Ready only after
   --  it has acquired and validated every resource it publishes. It should
   --  pass Stopping (Control.all) to task-aware I/O and observe cancellation
   --  during CPU-only work.
   --  @param Context State kept alive by the enclosing supervisor scope
   --  @param Control Borrowed generation-local readiness and stop channel
   with
     procedure Execute (Context : in out Application_Context; Control : not null access Generation_Control);

   Task_Model : Flyology.Execution_Model := Flyology.Project_Default;
   Task_CPU : System.Multiprocessors.CPU_Range := System.Multiprocessors.Not_A_Specific_CPU;

package Flyology.Supervision.Children
is

   --  Create, activate, observe, and join one generation. Unhandled callback
   --  exceptions are copied automatically into Result rather than propagated.
   --  Tasking_Error from activation is propagated because no generation body
   --  began and therefore no task result exists. An optional abort request is
   --  issued only when Control says so and remains subject to ordinary Ada
   --  abort deferral.
   --  @param Context Application state kept alive through the complete call
   --  @param Control Fresh generation control opened by the supervisor
   --  @param Result Bounded outcome available after the task has joined
   --  @exception Tasking_Error Generation task activation failed
   procedure Run
     (Context : aliased in out Application_Context;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result);

end Flyology.Supervision.Children;
