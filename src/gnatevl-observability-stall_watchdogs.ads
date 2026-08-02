with Ada.Finalization;

package Gnatevl.Observability.Stall_Watchdogs is

   type Watchdog_Config is record
      Group           : Group_Id := 0;
      Sample_Interval : Duration := 0.050;
      Stall_Threshold : Duration := 0.250;
   end record;

   Invalid_Configuration : exception;

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

   --  A Watchdog is inert until Start: declaring one does not create an event
   --  group, a poller, or a monitor task. Start creates one native Ada task so
   --  it can continue sampling while the observed event-loop thread is
   --  monopolized. Start and Stop are lifecycle operations and must not be
   --  called concurrently on the same object; Latest_Report is safe to call
   --  concurrently with the monitor.
   type Watchdog is new Ada.Finalization.Limited_Controlled with private;

   --  Sample_Interval and Stall_Threshold must both be positive, and the
   --  threshold must be at least the sampling interval. A stopped Watchdog may
   --  be started again. Starting an already-running Watchdog raises
   --  Program_Error.
   procedure Start
     (Object : in out Watchdog;
      Config : Watchdog_Config := (others => <>));

   --  Stop waits for the native monitor task to terminate and releases its
   --  task resources. The final Monitor_Stopped report remains queryable until
   --  the object is restarted or finalized. Stop is harmless before Start or
   --  after a previous Stop.
   procedure Stop (Object : in out Watchdog);

   function Is_Running (Object : Watchdog) return Boolean;

   --  Each report describes a pair of periodic samples, not an atomic history.
   --  Work may become runnable or finish between samples. Suspected_Stall thus
   --  means only that runnable work was repeatedly observed without a dispatch
   --  or poll counter advancing for Stall_Threshold; it is not proof of a hard
   --  deadlock. Stall_Episodes is latched and increments once per observed
   --  episode.
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

   overriding procedure Finalize (Object : in out Watchdog);

end Gnatevl.Observability.Stall_Watchdogs;
