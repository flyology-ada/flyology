with System.Multiprocessors;

--  Adapts a one-shot structured blocking service to one supervised
--  generation. The application retains a typed service object and operations;
--  the adapter adds a generation owner that observes readiness and forwards
--  cooperative shutdown while the service's blocking Run operation executes.
--  This is suitable for Worker_Pools, IO.Structured_Servers, and application
--  listener loops that already expose Run, Request_Shutdown, and Current-like
--  readiness operations.
--  @formal Application_Context State borrowed for the generation scope
--  @formal Service Application-defined one-shot structured service type
--  @formal Create Build-in-place fresh service constructor
--  @formal Run_Service Blocking structured service scope
--  @formal Request_Shutdown Idempotent nonblocking service stop request
--  @formal Ready Report whether the service is usable
--  @formal Generation_Model Execution model of the generation owner task
--  @formal Generation_CPU CPU aspect of the generation owner task
--  @formal Poll_Interval Readiness and shutdown observation interval

generic
   --  Application state kept alive by the enclosing supervisor Run scope.
   type Application_Context (<>) is limited private;
   --  Fresh one-shot structured service object constructed per generation.
   type Service (<>) is limited private;

   --  Construct a fresh limited service using generation-stable context.
   --  @param Context Context retained through service join
   --  @return Fresh service object by limited build-in-place return
   with function Create (Context : not null access Application_Context) return Service is <>;

   --  Execute the service's existing synchronous structured scope.
   --  @param Item Fresh service retained through the call
   --  @param Context Application context retained through the call
   with procedure Run_Service (Item : in out Service; Context : aliased in out Application_Context) is <>;

   --  Request idempotent nonblocking service shutdown. This operation runs
   --  concurrently with Run_Service and must provide its own synchronization.
   --  @param Item Live service to stop
   with procedure Request_Shutdown (Item : in out Service) is <>;

   --  Report whether the service completed application initialization. This
   --  operation runs concurrently with Run_Service and must be task safe and
   --  nonblocking.
   --  @param Item Service to inspect
   --  @return True only when dependents may use the service
   with function Ready (Item : Service) return Boolean is <>;

   --  Concrete execution model for the service-owner task.
   Generation_Model : Flyology.Execution_Model;
   --  CPU aspect applied to the service-owner task.
   Generation_CPU : System.Multiprocessors.CPU_Range := System.Multiprocessors.Not_A_Specific_CPU;
   --  Positive relative interval for readiness and stop observation.
   Poll_Interval : Duration := 0.001;

package Flyology.Supervision.Adapters
is

   --  Construct one fresh service, run it in a dependent task, publish
   --  readiness only after Ready returns True, and forward generation stop to
   --  Request_Shutdown. The call joins the service task and never allows its
   --  object, context, or resources to outlive the generation. A service that
   --  ignores shutdown remains subject to the supervisor's ordinary stuck
   --  semantics; the adapter does not promise forced termination.
   --  @param Context Application state retained through service join
   --  @param Control Fresh generation readiness and cancellation channel
   --  @param Result Terminal result after the generation owner joins
   --  @exception Program_Error Adapter configuration or a service operation
   --     is invalid
   --  @exception Tasking_Error Service task activation failed
   procedure Run
     (Context : aliased in out Application_Context;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result);

end Flyology.Supervision.Adapters;
