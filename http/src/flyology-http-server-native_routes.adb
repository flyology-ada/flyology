package body Flyology.HTTP.Server.Native_Routes is

   procedure Handle
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange)
   is
      Input    : Input_Type;
      Result   : Result_Type;
      Work     : Operations.Operation_Handle (Executor);
      Accepted : Boolean;
   begin
      Prepare (Context, X, Input);
      Operations.Submit
        (Executor.all, Input, X.Cancellation, X.Deadline, Work, Accepted);
      if not Accepted then
         X.Problem
           (503, "native-executor-full",
            "Native route executor capacity is exhausted");
         return;
      end if;
      Operations.Await
        (Executor.all, Work, Result, X.Cancellation, X.Deadline);
      Render (Context, X, Result);
   end Handle;

end Flyology.HTTP.Server.Native_Routes;
