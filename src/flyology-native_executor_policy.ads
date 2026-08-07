--  Internal, proved slot bookkeeping decisions for native executors. Worker
--  activation, cancellation tokens, wake sources, and result storage stay in
--  the generic executor implementation that consumes these decisions.
private package Flyology.Native_Executor_Policy
  with Preelaborate,
       SPARK_Mode
is
   --  @exclude Internal proof policy, not part of the public API.

   --  Lifecycle of one bounded operation slot.
   --  @enum Free Slot is reusable by a later submission
   --  @enum Queued Operation is admitted but not yet dispatched
   --  @enum Running Operation is owned by a native worker
   --  @enum Completed Slot holds a terminal outcome for its waiter
   type Slot_State is (Free, Queued, Running, Completed);

   --  Decide whether a worker may report a terminal outcome for one slot.
   --  Publishing a completion can propagate after the slot transition is
   --  already visible, and the worker then reports the same operation again;
   --  only the first report may perform the bookkeeping.
   --  @param State Current slot state
   --  @return True only while a native worker still owns the slot
   function Terminal_Report_Allowed (State : Slot_State) return Boolean
   with Post => Terminal_Report_Allowed'Result = (State = Running);

   --  Select the state one terminal report leaves behind. The result is never
   --  Running, so a repeated report is refused by Terminal_Report_Allowed.
   --  @param Relinquished Whether the waiter already abandoned the operation
   --  @return Free for an abandoned operation, otherwise Completed
   function State_After_Report (Relinquished : Boolean) return Slot_State
   with Post => State_After_Report'Result =
     (if Relinquished then Free else Completed)
     and then State_After_Report'Result /= Running;

   --  Decrement the running count claimed by one terminal report.
   --  @param Running Operations currently executing natively
   --  @return Running count after the report
   function Running_After_Report (Running : Positive) return Natural
   with Post => Running_After_Report'Result = Running - 1;

   --  Adjust the occupied slot count for one terminal report. Only an
   --  abandoned operation releases its slot; a claimed result stays
   --  outstanding until Await or Abandon consumes it.
   --  @param Outstanding Currently occupied operation slots
   --  @param Relinquished Whether the waiter already abandoned the operation
   --  @return Occupied slot count after the report
   function Outstanding_After_Report
     (Outstanding  : Positive;
      Relinquished : Boolean) return Natural
   with Post => Outstanding_After_Report'Result =
     (if Relinquished then Outstanding - 1 else Outstanding);
end Flyology.Native_Executor_Policy;
