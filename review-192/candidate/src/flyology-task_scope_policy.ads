--  Internal, proved worker-accounting decisions for task scopes. Created
--  counts the worker tasks a scope allocated and Activated counts the ones
--  that accepted Start; a Configure that failed part way through leaves
--  Activated below Created. Task creation, cancellation, joining, and storage
--  release remain in Flyology.Task_Scopes.

private package Flyology.Task_Scope_Policy
  with Preelaborate, SPARK_Mode
is
   --  Workers that accepted Start report their exit through Await_Workers.
   function Awaited_Workers (Created : Natural; Activated : Natural) return Natural
   with
     Pre  => Activated <= Created,
     Post => Awaited_Workers'Result = Activated and then Awaited_Workers'Result <= Created;

   --  Workers that were created but never started; they can only leave their
   --  initial select through the stop rendezvous.
   function Unstarted_Workers (Created : Natural; Activated : Natural) return Natural
   with Pre => Activated <= Created, Post => Unstarted_Workers'Result = Created - Activated;

   --  First index of the stop range. A scope creates at most Capacity
   --  workers, so Created stays below Natural'Last.
   function First_Unstarted (Created : Natural; Activated : Natural) return Positive
   with
     Pre  => Activated <= Created and then Created < Natural'Last,
     Post => First_Unstarted'Result = Activated + 1;

   --  Last index of the stop range, which is empty when nothing was left
   --  unstarted.
   function Last_Unstarted (Created : Natural; Activated : Natural) return Natural
   with Pre => Activated <= Created, Post => Last_Unstarted'Result = Created;

   --  Every created worker is accounted for exactly once: it is either
   --  awaited or stopped, and the stop range holds precisely the workers that
   --  were never started.
   function Accounts_For_Every_Worker (Created : Natural; Activated : Natural) return Boolean
   with
     Pre  => Activated <= Created and then Created < Natural'Last,
     Post =>
       Accounts_For_Every_Worker'Result
       and then Awaited_Workers (Created, Activated) + Unstarted_Workers (Created, Activated) = Created
       and then Last_Unstarted (Created, Activated) - First_Unstarted (Created, Activated) + 1
                = Unstarted_Workers (Created, Activated);
end Flyology.Task_Scope_Policy;
