with Flyology.Cancellation;
with Flyology.Channels.Bounded;
with System.Multiprocessors;

--  Runs bounded queued work in a lexical set of ordinary Ada tasks.
--
--  Run is deliberately a blocking structured scope. No worker outlives Run,
--  its shared Context, or the Pool object. Submit may be called before or
--  concurrently with Run. Request_Shutdown closes admission, requests the
--  shared stopping token, and drains jobs accepted before closure.
--  @formal Job_Type Definite value transferred by copy to one worker
--  @formal Worker_Context Shared callback state with caller-defined safety
--  @formal Process Per-job callback invoked by a worker task
--  @formal Worker_Model Fixed lightweight or native worker designation
--  @formal Worker_CPU CPU aspect applied to every worker task
generic
   --  Definite value transferred by copy to one worker.
   type Job_Type is private;

   --  State shared by concurrent Process calls. Mutable state must provide
   --  its own synchronization.
   type Worker_Context (<>) is limited private;

   --  Process one job. Stopping is requested when shutdown begins or a worker
   --  reports a failure. A callback may pass it to task-aware I/O or inspect
   --  it during CPU-only work.
   --  @param Context Shared instance supplied to Run
   --  @param Job One value removed from the bounded FIFO
   --  @param Stopping Shared one-shot shutdown source
   with procedure Process
     (Context  : in out Worker_Context;
      Job      : Job_Type;
      Stopping : not null access Flyology.Cancellation.Token);

   --  Fixed task designation for every worker in this generic instance.
   Worker_Model : Flyology.Execution_Model := Flyology.Project_Default;

   --  CPU aspect for every worker. For lightweight tasks, 0 .. 127 selects an
   --  execution group; for native tasks it retains Ada affinity semantics.
   Worker_CPU : System.Multiprocessors.CPU_Range :=
     System.Multiprocessors.Not_A_Specific_CPU;

package Flyology.Worker_Pools is

   --  Raised by Run after all workers join when at least one callback or
   --  worker-lifecycle failure was recorded.
   Pool_Failed : exception;

   --  Outcome of a timed submission.
   --  @enum Job_Accepted The job entered the bounded FIFO
   --  @enum Pool_Closed Shutdown rejected the job
   --  @enum Submit_Timed_Out Capacity remained full through the deadline
   type Submit_Result is (Job_Accepted, Pool_Closed, Submit_Timed_Out);

   --  Current pool lifecycle and work counters. Pending_Jobs is sampled from
   --  the channel separately from the remaining protected lifecycle fields;
   --  it may therefore reflect an immediately adjacent state transition.
   --  @field Running Run currently owns its worker scope
   --  @field Shutdown_Requested Admission has been closed or is closing
   --  @field Active_Workers Callbacks currently executing
   --  @field Pending_Jobs Jobs currently buffered
   --  @field Completed_Jobs Callbacks that returned normally, saturating
   --  @field Cancelled_Jobs Callbacks that propagated Operation_Cancelled,
   --     saturating
   --  @field Failures Callback or lifecycle failures, saturating
   type Snapshot is record
      Running            : Boolean;
      Shutdown_Requested : Boolean;
      Active_Workers     : Natural;
      Pending_Jobs       : Natural;
      Completed_Jobs     : Natural;
      Cancelled_Jobs     : Natural;
      Failures           : Natural;
   end record;

   --  One-shot structured pool with a fixed worker count and bounded FIFO.
   --  The object must outlive Run and every concurrent Submit or shutdown
   --  call. Jobs may be preloaded before Run up to Queue_Capacity.
   --  @field Worker_Count Tasks created by Run
   --  @field Queue_Capacity Maximum buffered jobs
   type Pool
     (Worker_Count   : Positive;  --  Tasks created by Run
      Queue_Capacity : Positive)  --  Maximum buffered jobs
   is limited private;

   --  Submit one job, waiting for bounded queue capacity. Accepted is False
   --  after shutdown; no exception is used for this expected terminal state.
   --  @param Item Pool whose queue receives Job
   --  @param Job Value copied into the queue
   --  @param Accepted Whether the job was accepted
   procedure Submit
     (Item     : in out Pool;
      Job      : Job_Type;
      Accepted : out Boolean);

   --  Submit one job within a relative deadline. Negative Timeout waits
   --  indefinitely and zero is an immediate attempt.
   --  @param Item Pool whose queue receives Job
   --  @param Job Value copied into the queue
   --  @param Timeout Deadline interval in seconds
   --  @param Result Acceptance, closure, or timeout outcome
   procedure Submit
     (Item    : in out Pool;
      Job     : Job_Type;
      Timeout : Duration;
      Result  : out Submit_Result);

   --  Idempotently close admission and request the shared stopping token.
   --  Workers continue removing all jobs accepted before closure, then join.
   --  Once shutdown mutation begins, caller abort is deferred until the
   --  lifecycle flag, queue closure, and token wake have all been attempted.
   --  @param Item Pool to stop
   --  @exception Program_Error A borrowed cancellation source cannot be woken
   procedure Request_Shutdown (Item : in out Pool);

   --  Create exactly Worker_Count dependent tasks and wait for shutdown. Run
   --  returns only after the closed queue drains and all workers terminate.
   --  The call and Pool are one-shot even after an exceptional return or
   --  caller abort; abnormal exit closes admission and terminalizes the pool.
   --  @param Item Pool kept alive for the complete worker scope
   --  @param Context Shared callback state kept alive for the complete scope
   --  @exception Program_Error Run was already called
   --  @exception Pool_Failed One or more callback or worker failures occurred
   --  @exception Tasking_Error Worker activation fails
   procedure Run
     (Item    : aliased in out Pool;
      Context : aliased in out Worker_Context);

   --  Sample current lifecycle, work, and queue state.
   --  @param Item Pool to inspect
   --  @return Current snapshot
   function Current (Item : Pool) return Snapshot;

   --  Return retained information for the first failure, or an empty string.
   --  The text remains available after Run raises Pool_Failed.
   --  @param Item Pool to inspect
   --  @return First exception information, truncated to 2,048 characters
   function First_Failure_Information (Item : Pool) return String;

private
   package Job_Channels is new Flyology.Channels.Bounded (Job_Type);

   protected type Lifecycle is
      procedure Begin_Run (Expected_Workers : Positive);
      procedure Request_Stop;
      procedure Job_Started;
      procedure Job_Completed (Cancelled, Failed : Boolean);
      procedure Worker_Finished;
      procedure Record_Failure (Information : String);
      entry Await_All_Workers;
      procedure Finish_Run;
      procedure Abandon_Run;
      function Read_Snapshot return Snapshot;
      function Failure_Information return String;
   private
      Begun            : Boolean := False;
      Is_Running       : Boolean := False;
      Stop_Requested   : Boolean := False;
      Active           : Natural := 0;
      Completed        : Natural := 0;
      Cancelled_Total  : Natural := 0;
      Failure_Total    : Natural := 0;
      Workers_Done     : Natural := 0;
      Expected         : Natural := 0;
      Failure_Recorded : Boolean := False;
      Failure_Length   : Natural := 0;
      Failure_Text     : String (1 .. 2_048) := (others => ' ');
   end Lifecycle;

   type Pool
     (Worker_Count   : Positive;
      Queue_Capacity : Positive)
   is limited record
      Jobs     : Job_Channels.Channel (Queue_Capacity);
      State    : Lifecycle;
      Stopping : aliased Flyology.Cancellation.Token;
   end record;

end Flyology.Worker_Pools;
