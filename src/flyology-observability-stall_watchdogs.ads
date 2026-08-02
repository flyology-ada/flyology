with Ada.Finalization;

--  Samples scheduler progress from a native monitor task to identify stalls.
--
--  Example:
--
--     Flyology.Observability.Stall_Watchdogs.Start (Monitor);
package Flyology.Observability.Stall_Watchdogs is

   --  Periodic sampling configuration for one execution group.
   --  @field Group Group to observe without starting it
   --  @field Sample_Interval Seconds between samples
   --  @field Stall_Threshold Seconds without progress before suspicion
   type Watchdog_Config is record
      Group           : Group_Id := 0;
      Sample_Interval : Duration := 0.050;
      Stall_Threshold : Duration := 0.250;
   end record;

   --  Raised when a watchdog interval is nonpositive or threshold is shorter
   --  than the sample interval.
   Invalid_Configuration : exception;

   --  Interpretation of the latest pair of periodic samples.
   --  @enum Not_Started Start has not yet created a monitor
   --  @enum Group_Absent The observed group has never been created
   --  @enum Group_Starting The scheduler thread is starting
   --  @enum Idle No task is runnable or waiting
   --  @enum Waiting Tasks are suspended and none is runnable
   --  @enum Advancing Runnable work and scheduler counters advanced
   --  @enum Runnable_Not_Progressing Runnable work has not crossed threshold
   --  @enum Suspected_Stall Runnable work did not progress for the threshold
   --  @enum Group_Failed The scheduler thread reports failure
   --  @enum Monitor_Stopped Stop terminated the monitor normally
   --  @enum Monitor_Failed The native monitor task raised an exception
   type Group_Condition is
     (Not_Started,
      Group_Absent,
      Group_Starting,
      Idle,
      Waiting,
      Advancing,
      Runnable_Not_Progressing,
      Suspected_Stall,
      Group_Failed,
      Monitor_Stopped,
      Monitor_Failed);

   --  Latest sampled condition and diagnostic counters.
   --  @field Group Observed execution group
   --  @field Condition Interpretation of the sample pair
   --  @field Sample_Sequence Cumulative samples by this monitor run
   --  @field Snapshot_Available Whether the group snapshot existed
   --  @field Observed_For Seconds runnable work lacked observed progress
   --  @field Ready Ready count from the latest snapshot
   --  @field Waiting Waiting count from the latest snapshot
   --  @field Running Running count from the latest snapshot
   --  @field Dispatches Cumulative dispatches from the latest snapshot
   --  @field Poll_Batches Cumulative poll batches from the latest snapshot
   --  @field Stall_Episodes Distinct suspected-stall episodes in this run
   type Watchdog_Report is record
      Group              : Group_Id := 0;
      Condition          : Group_Condition := Not_Started;
      Sample_Sequence    : Counter := 0;
      Snapshot_Available : Boolean := False;
      Observed_For       : Duration := 0.0;
      Ready              : Counter := 0;
      Waiting            : Counter := 0;
      Running            : Counter := 0;
      Dispatches         : Counter := 0;
      Poll_Batches       : Counter := 0;
      Stall_Episodes     : Counter := 0;
   end record;

   --  Controlled owner of one native monitor task. Declaration is inert.
   --  Start and Stop must not run concurrently on the same object; callers
   --  must also serialize those lifecycle calls with Is_Running. Latest_Report
   --  is safe during monitoring. Finalize stops and releases the monitor.
   type Watchdog is new Ada.Finalization.Limited_Controlled with private;

   --  Start sampling Config.Group from one native task. The operation creates
   --  no observed group. A stopped Watchdog may be restarted.
   --  @param Object Stopped watchdog to start
   --  @param Config Positive sampling configuration
   --  @exception Invalid_Configuration Intervals violate the stated rules
   --  @exception Program_Error Object is already running
   --  @exception Storage_Error Monitor state or task allocation fails
   --  @exception Tasking_Error Native monitor task activation fails
   procedure Start
     (Object : in out Watchdog;
      Config : Watchdog_Config := (others => <>));

   --  Stop and join the native monitor task. The final Monitor_Stopped report
   --  remains queryable. Calling before Start or after Stop is harmless.
   --  @param Object Watchdog to stop
   procedure Stop (Object : in out Watchdog);

   --  Query monitor task liveness; serialize this with Start and Stop.
   --  @param Object Watchdog to inspect
   --  @return True while its native monitor task has not terminated
   function Is_Running (Object : Watchdog) return Boolean;

   --  Copy the latest protected report. A report compares periodic samples,
   --  not an atomic history; Suspected_Stall is evidence, not deadlock proof.
   --  Stall_Episodes increments once per observed episode.
   --  @param Object Watchdog to inspect
   --  @return Latest report, or default Not_Started report before Start
   function Latest_Report
     (Object : Watchdog) return Watchdog_Report;

private
   type Watchdog_State;
   type Watchdog_State_Access is access all Watchdog_State;
   type Monitor_Task;
   type Monitor_Task_Access is access Monitor_Task;

   type Watchdog is new Ada.Finalization.Limited_Controlled with record
      State   : Watchdog_State_Access := null;
      Monitor : Monitor_Task_Access := null;
   end record;

   --  Stop Object and free its protected state without propagating cleanup
   --  errors.
   --  @param Object Watchdog being finalized
   overriding procedure Finalize (Object : in out Watchdog);

end Flyology.Observability.Stall_Watchdogs;
