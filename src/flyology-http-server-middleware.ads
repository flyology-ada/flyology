with Ada.Exceptions;
with Ada.Task_Identification;
with Flyology.HTTP.Server.Applications;

--  Supplies bounded, synchronous around-handler composition for applications.
--  @formal App_Context Application-owned context passed to every component
generic
   --  Application context shared by middleware and endpoints.
   type App_Context is limited private;
package Flyology.HTTP.Server.Middleware is

   package App renames Flyology.HTTP.Server.Applications;

   --  Terminal application endpoint.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   type Handler_Access is access procedure
     (Context : in out App_Context;
      X       : in out App.Exchange);

   --  Single-use continuation for one around-handler invocation. The value
   --  borrows its pipeline and must not escape the middleware call.
   type Next_Handler is tagged limited private;

   --  Around-handler component. Call Next exactly once to continue, omit the
   --  call to short circuit, and perform post-response work after it returns.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Next Borrowed single-use downstream continuation
   type Middleware_Access is access procedure
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Next    : in out Next_Handler);

   --  Fixed-capacity middleware sequence. Configure it before concurrent use.
   --  @field Capacity Maximum registered components
   type Pipeline (Capacity : Positive := 16) is tagged limited private;

   --  Append one component in deterministic outer-to-inner order.
   --  @param Item Pipeline being configured
   --  @param Component Around-handler component
   --  @exception Constraint_Error Pipeline capacity is exhausted
   procedure Add
     (Item      : in out Pipeline;
      Component : not null Middleware_Access);

   --  Execute the pipeline and terminal endpoint synchronously. Item, X, and
   --  every continuation remain borrowed until this call returns.
   --  @param Item Configured middleware pipeline
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Terminal Final application endpoint
   procedure Execute
     (Item     : aliased in out Pipeline;
      Context  : in out App_Context;
      X        : in out App.Exchange;
      Terminal : not null Handler_Access);

   --  Invoke the next component once. A second invocation raises
   --  Program_Error instead of running application work twice.
   --  @param Item Borrowed continuation
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   procedure Call
     (Item    : in out Next_Handler;
      Context : in out App_Context;
      X       : in out App.Exchange);

   --  Report whether a continuation has already been invoked.
   --  @param Item Borrowed continuation
   --  @return True after Call
   function Invoked (Item : Next_Handler) return Boolean;

   --  Failure category supplied to application logging.
   --  @enum Protocol_Failure Invalid HTTP protocol state
   --  @enum Timeout_Failure Absolute deadline expired
   --  @enum Cancellation_Failure Cancellation was requested
   --  @enum Resource_Failure Bounded server resource was unavailable
   --  @enum Transport_Failure Socket or TLS transport failed
   --  @enum Application_Failure Application or middleware raised unexpectedly
   type Failure_Kind is
     (Protocol_Failure,
      Timeout_Failure,
      Cancellation_Failure,
      Resource_Failure,
      Transport_Failure,
      Application_Failure);

   --  Default no-op error logger.
   --  @param Kind Failure category
   --  @param Error Captured exception occurrence
   --  @param X Borrowed request exchange
   procedure No_Error_Log
     (Kind  : Failure_Kind;
      Error : Ada.Exceptions.Exception_Occurrence;
      X     : in out App.Exchange);

   --  Default application exception mapper, which leaves Handled false.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   --  @param Error Captured exception occurrence
   --  @param Handled Set true only after safely mapping the exception
   procedure No_Error_Map
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Error   : Ada.Exceptions.Exception_Occurrence;
      Handled : in out Boolean);

private
   type Middleware_Array is
     array (Positive range <>) of Middleware_Access;

   type Pipeline (Capacity : Positive := 16) is tagged limited record
      Components : Middleware_Array (1 .. Capacity);
      Count      : Natural := 0;
   end record;

   type Pipeline_Access is access all Pipeline;

   type Next_Handler is tagged limited record
      Owner    : Pipeline_Access;
      Position : Positive := 1;
      Terminal : Handler_Access;
      Owner_Task : Ada.Task_Identification.Task_Id;
      Was_Called : Boolean := False;
   end record;

end Flyology.HTTP.Server.Middleware;
