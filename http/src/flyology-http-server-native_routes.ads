with Flyology.HTTP.Server.Applications;
with Flyology.Native_Executors;

--  Adapts a routed HTTP handler to a bounded native executor while retaining
--  request parsing, routing, cancellation, and response I/O on the request
--  owner task. Prepare must copy all worker input out of the borrowed
--  exchange;
--  Execute never receives the exchange or connection; Render runs only after
--  native completion on the original request task.
--
--  The application owns, sizes, starts, and outlives Executor. Several adapter
--  instances may share it when they use the same Operations instantiation.
--  Short handlers should remain inline because submission and wakeup have a
--  measurable fixed cost.
--  @formal App_Context Application context used by the router
--  @formal Input_Type Detached operation input
--  @formal Result_Type Detached operation result
--  @formal Operations Typed native executor instance
--  @formal Executor Borrowed application-owned bounded executor
--  @formal Prepare Detach immutable input on the request owner task
--  @formal Render Emit the completed result on the request owner task
generic
   type App_Context is limited private;
   type Input_Type is private;
   type Result_Type is private;
   with package Operations is new Flyology.Native_Executors
     (Input_Type  => Input_Type,
      Result_Type => Result_Type,
      Execute     => <>);
   Executor : not null access Operations.Executor;
   with procedure Prepare
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Input   : out Input_Type);
   with procedure Render
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Result  : Result_Type);
package Flyology.HTTP.Server.Native_Routes is

   --  Prepare detached input, submit it without waiting for capacity, suspend
   --  until native completion, then render on the request owner. A full or
   --  stopping executor receives HTTP 503. Caller cancellation and the current
   --  absolute exchange deadline are propagated to Submit and Await. Native
   --  exceptions are re-raised with their original identity for the router's
   --  normal exception mapper. An unwound or cancelled call abandons its
   --  single-use result handle, which requests cooperative worker cancellation
   --  and reclaims the slot after completion.
   --  @param Context Router application context
   --  @param X Borrowed exchange owned by the current request task
   procedure Handle
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange);

end Flyology.HTTP.Server.Native_Routes;
