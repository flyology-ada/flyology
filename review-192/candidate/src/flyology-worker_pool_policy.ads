--  Internal, proved lifecycle decisions for structured worker pools. Task
--  creation, exception retention, cancellation, and queue ownership stay in
--  the generic worker-pool implementation that consumes these decisions.

private package Flyology.Worker_Pool_Policy
  with Preelaborate, SPARK_Mode
is
   type Completion_Action is (Count_Completed, Count_Cancelled, Count_Neither);

   --  Admit exactly one Run call.
   function Begin_Allowed (Begun : Boolean) return Boolean
   with Post => Begin_Allowed'Result = not Begun;

   --  Terminalize a run only on behalf of the caller that claimed it. A
   --  refused caller, or one abandoned before its claim completed, must leave
   --  the claiming caller's pool state alone.
   function Teardown_Allowed (Claimed : Boolean) return Boolean
   with Post => Teardown_Allowed'Result = Claimed;

   --  Admit callback execution only while a worker slot is available.
   function Job_Start_Allowed (Running : Boolean; Active : Natural; Expected : Natural) return Boolean
   with Post => Job_Start_Allowed'Result = (Running and then Active < Expected);

   --  Increment the active callback count within the worker bound.
   function Active_After_Start (Active : Natural; Expected : Positive) return Positive
   with
     Pre  => Active < Expected,
     Post => Active_After_Start'Result = Active + 1 and then Active_After_Start'Result <= Expected;

   --  Reject completion bookkeeping without a matching active callback.
   function Job_Completion_Allowed (Active : Natural) return Boolean
   with Post => Job_Completion_Allowed'Result = (Active > 0);

   --  Decrement a nonzero active callback count.
   function Active_After_Completion (Active : Positive) return Natural
   with Post => Active_After_Completion'Result = Active - 1;

   --  Give cancellation precedence and avoid double-counting failures.
   function Classify_Completion (Cancelled : Boolean; Failed : Boolean) return Completion_Action
   with
     Post =>
       (if Cancelled
        then Classify_Completion'Result = Count_Cancelled
        elsif Failed
        then Classify_Completion'Result = Count_Neither
        else Classify_Completion'Result = Count_Completed);

   --  Bound worker completion bookkeeping by the created task count.
   function Worker_Finish_Allowed
     (Running : Boolean; Workers_Done : Natural; Expected : Natural) return Boolean
   with Post => Worker_Finish_Allowed'Result = (Running and then Workers_Done < Expected);

   --  Increment the completed worker count within the expected bound.
   function Workers_After_Finish (Workers_Done : Natural; Expected : Positive) return Positive
   with
     Pre  => Workers_Done < Expected,
     Post => Workers_After_Finish'Result = Workers_Done + 1 and then Workers_After_Finish'Result <= Expected;

   --  Open the join barrier only for a nonempty, fully joined worker set.
   function All_Workers_Done (Workers_Done : Natural; Expected : Natural) return Boolean
   with Post => All_Workers_Done'Result = (Expected > 0 and then Workers_Done = Expected);

   --  Terminalization zeroes Expected, which closes the join barrier for
   --  every completion count. A teardown run for an unclaimed caller would
   --  therefore strand the claiming caller in Await_All_Workers, which is why
   --  Teardown_Allowed admits only the claimer.
   procedure Teardown_Closes_Join_Barrier (Workers_Done : Natural)
   with Ghost, Post => not All_Workers_Done (Workers_Done, 0);

   --  Permit terminalization only after callbacks and workers drain.
   function Finish_Allowed
     (Running : Boolean; Active : Natural; Workers_Done : Natural; Expected : Natural) return Boolean
   with
     Post =>
       Finish_Allowed'Result
       = (Running and then Active = 0 and then Expected > 0 and then Workers_Done = Expected);
end Flyology.Worker_Pool_Policy;
