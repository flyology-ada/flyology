with Ada.Task_Identification;

--  Owns one generation of an application-defined Ada task type with a typed
--  immutable input. The input copy, task object, and task finalization remain
--  under the Run call's local Ada master.
--  @formal Input_Type Typed generation input
--  @formal Application_Context State kept alive by the supervisor scope
--  @formal Generation_Task Application-defined input task type
--  @formal Create Build-in-place constructor, inferred by name when omitted
--  @formal Initialize Synchronous application initialization for the newly
--  activated task object
--  @formal Task_Identity Return actual task identity, inferred by name when
--  omitted
--  @formal Abort_Task Issue Ada abort, inferred by name when omitted
generic
   type Input_Type is private;
   type Application_Context (<>) is limited private;
   type Generation_Task (<>) is limited private;

   --  Construct the exact application task object by limited build-in-place
   --  return. Create may choose any task discriminants from the stable typed
   --  input and context, while the returned task remains under Run's master.
   --  Create should only construct the object; an exception from Create or
   --  task activation propagates from Run for the enclosing controller to
   --  classify. A directly visible profile-conformant Create is inferred by
   --  name when the generic actual is omitted.
   with function Create
     (Context : not null access Application_Context;
      Input   : not null access constant Input_Type;
      Control : not null access Generation_Control) return Generation_Task
      is <>;

   --  Invoke task-specific entries or package operations immediately after
   --  activation. Initialize runs outside supervisor locks, must not retain an
   --  access to Subject, and must return for readiness and stop deadlines to
   --  remain observable.
   --  @param Subject Newly activated application task object
   --  @param Control Borrowed generation control
   with procedure Initialize
     (Subject : in out Generation_Task;
      Control : aliased in out Generation_Control) is null;

   --  Return Subject'Identity without retaining Subject or performing a
   --  potentially blocking operation. A directly visible profile-conformant
   --  Task_Identity is inferred by name when omitted.
   with function Task_Identity
     (Subject : in out Generation_Task)
      return Ada.Task_Identification.Task_Id is <>;

   --  Perform "abort Subject" without retaining Subject. The adapter must
   --  return promptly; Ada may still defer the task's response to abort. A
   --  directly visible profile-conformant Abort_Task is inferred by name when
   --  omitted.
   with procedure Abort_Task (Subject : in out Generation_Task) is <>;

package Flyology.Supervision.Input_Task_Generations is

   --  Copy Input, construct the application-defined task, and return only
   --  after its termination and task-body finalization. The task body reports
   --  its terminal outcome through Control. Tasking_Error from activation
   --  propagates, as does any other Create exception. An Initialize exception
   --  is copied as an Unhandled_Exception and requests cooperative stop.
   --  Abort_Task is called at most once after an abort request.
   --  @param Context Application state retained through task finalization
   --  @param Input Immutable value retained until the generation joins
   --  @param Control Fresh generation readiness, stop, and outcome channel
   --  @param Result Bounded outcome returned only after task termination
   --  @exception Tasking_Error Generation task activation failed
   procedure Run
     (Context : aliased in out Application_Context;
      Input   : Input_Type;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result);

end Flyology.Supervision.Input_Task_Generations;
