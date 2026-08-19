with Ada.Finalization;
with Ada.Task_Identification;
with Flyology.Execution_Groups;
with Interfaces;

--  Owns one application instance per shard and runs typed operations on the
--  owning shard's event loop.
--
--  Resident lightweight agent tasks are created for each shard. An agent
--  crosses to its shard, pins itself to that loop pthread, and then serves
--  operations through an ordinary Ada rendezvous. Callers therefore keep
--  normal synchronous call semantics: in and out values, exception
--  propagation, and abort behave exactly as for a direct call, from native
--  and lightweight tasks alike. A suspended caller frees its own event loop.
--
--  The instance is protected by shard ownership, not by a lock. Code that
--  reaches an instance directly through Borrow_Local must complete every
--  mutation sequence without a suspension point, because the group is
--  scheduled cooperatively and another task on the same loop may run at any
--  suspension.
--
--  Example:
--
--     type Bump is limited new Counters.Operation with record
--        Amount : Natural := 1;
--        Total  : Natural := 0;
--     end record;
--
--     Change : Bump;
--     Counters.Invoke_On (Table, Counters.Shard_For (Table, Key), Change);
--
--  @formal Service_Type Application state owned by exactly one shard
--  @formal Create Build-in-place constructor run on the owning shard
--  @formal Shut_Down Orderly instance teardown run on the owning shard
--  @formal Concurrency Operations that may be in progress on one shard
generic
   type Service_Type (<>) is limited private;

   --  Construct the instance owned by Shard. The call executes on Shard's
   --  event loop before the service publishes readiness. An exception
   --  propagates as a Startup_Failed service result and stops the shards
   --  that already started.
   --  @param Shard Shard that will own the returned instance
   --  @return Instance built in place inside the shard agent's frame
   with function Create (Shard : Shard_Id) return Service_Type;

   --  Release instance-owned resources on the owning shard during orderly
   --  shutdown. It runs after every in-flight operation has drained. An
   --  exception is recorded as Shard_Failed and does not prevent the
   --  remaining shards from stopping.
   --  @param Instance Instance leaving scope on its owning shard
   with procedure Shut_Down (Instance : in out Service_Type) is null;

   --  Number of operations that may be in progress on one shard at once.
   --  The default of one is a strict serialization guarantee: an operation
   --  runs to completion before the next one on that shard begins, even if
   --  it suspends. A larger value creates that many agent tasks per shard
   --  and admits that many concurrent operations, which may then interleave
   --  with each other at suspension points. It never introduces parallelism
   --  within a shard, because every agent of a shard runs on one
   --  cooperatively scheduled event loop.
   Concurrency : Positive := 1;

package Flyology.Sharding.Services is

   --  ------------------------------------------------------------------
   --  Operations
   --  ------------------------------------------------------------------

   --  Unit of work executed on an instance's owning shard. Extend it with
   --  the inputs and outputs of one call; the caller keeps the object on
   --  its own stack and reads the outputs after the call returns.
   type Operation is limited interface;

   --  Apply Op to the shard's instance. The call runs on Shard's event
   --  loop with the agent pinned to that loop, so it must not migrate. It
   --  may suspend. An exception propagates to the submitting caller
   --  unchanged and leaves the agent serving.
   --  @param Op Operation object owned by the submitting caller
   --  @param Instance Shard-owned application state
   --  @param Shard Shard executing the operation
   procedure Execute
     (Op       : in out Operation;
      Instance : in out Service_Type;
      Shard    : Shard_Id) is abstract;

   --  ------------------------------------------------------------------
   --  Lifecycle
   --  ------------------------------------------------------------------

   --  One-shot sharded service owner. Serve is the Ada master boundary:
   --  shard agents and instances cannot outlive it.
   type Service is limited private;

   --  Grow the automatic pool to Shards, start the agents, invoke On_Ready
   --  once every instance exists, and return after shutdown joins every
   --  agent. Growing the pool changes the modulus used by
   --  Execution_Groups.Topology.Shard_For_Hash for the whole process; use
   --  Shard_For to keep this service's routing independent of that.
   --  A stuck operation prevents return, exactly as a stuck supervised
   --  child does. Every exit path stops the agents, so an exception from
   --  On_Ready propagates rather than stranding them; it also marks the
   --  service failed, which releases callers waiting in Await_Ready.
   --  @param Item One-shot service owner kept alive for the whole call
   --  @param Shards Number of shards, mapped to groups 0 .. Shards - 1
   --  @param Result Terminal result after every agent joins
   --  @param On_Ready Optional callback run once on Serve's task after all
   --     instances exist and before any operation is admitted; use it to
   --     publish Supervision readiness
   --  @exception Configuration_Error Item was already served
   --  @exception Tasking_Error A shard agent could not activate
   procedure Serve
     (Item     : aliased in out Service;
      Shards   : Shard_Count;
      Result   : out Service_Result;
      On_Ready : access procedure := null);

   --  Idempotently close admission and stop every shard. The call is
   --  nonblocking; Serve remains the join boundary. A request made before
   --  Serve is sticky and prevents agent activation.
   --  @param Item Service to shut down
   procedure Request_Shutdown (Item : in out Service);

   --  Wait until every shard instance exists, or until Timeout expires. A
   --  negative timeout waits indefinitely, zero only checks, and a positive
   --  value is a relative duration. The call is abortable and must not be
   --  made from a protected action.
   --  @param Item Service to observe
   --  @param Timeout Maximum relative wait; negative means indefinitely
   --  @return True when the service is admitting operations
   function Await_Ready
     (Item    : in out Service;
      Timeout : Duration := -1.0) return Boolean;

   --  Report whether the service is currently admitting operations.
   --  @param Item Service to inspect
   --  @return True between readiness and the first shutdown request
   function Running (Item : Service) return Boolean;

   --  Return the configured shard count, or zero before readiness.
   --  @param Item Service to inspect
   --  @return Number of shards owned by this service
   function Shards (Item : Service) return Natural;

   --  Map Hash across this service's own shard count.
   --  @param Item Ready service
   --  @param Hash Application key or hash to partition
   --  @return Shard that owns Hash
   --  @exception Not_Running The service has no shard count yet
   function Shard_For
     (Item : Service;
      Hash : Interfaces.Unsigned_64) return Shard_Id;

   --  ------------------------------------------------------------------
   --  Invocation
   --  ------------------------------------------------------------------

   --  Run Op on Shard's instance and return when it completes. The calling
   --  task suspends and stays where it is; a lightweight caller frees its
   --  event loop for other tasks while it waits. Exceptions raised by
   --  Execute propagate here unchanged.
   --  @param Item Ready service
   --  @param Shard Target shard
   --  @param Op Caller-owned operation object
   --  @exception Not_Running The service is not admitting operations
   --  @exception Constraint_Error Shard is outside 0 .. Shards - 1
   --  @exception Reentrant_Operation The caller is one of Shard's agents
   --  @exception Tasking_Error Shard's agent has terminated
   procedure Invoke_On
     (Item  : in out Service;
      Shard : Shard_Id;
      Op    : in out Operation'Class);

   --  Run Op on every shard in ascending order and return when the last
   --  one completes. The same Op object is reused, so it may accumulate
   --  across shards. Execution is sequential; an exception stops the sweep
   --  and leaves Op applied to the preceding shards only.
   --  @param Item Ready service
   --  @param Op Caller-owned operation object reused for every shard
   --  @exception Not_Running The service is not admitting operations
   procedure Invoke_On_All
     (Item : in out Service;
      Op   : in out Operation'Class);

   --  Run Op on every shard except the caller's own. A caller that does not
   --  own a shard of this service reaches every shard, so this is
   --  Invoke_On_All for a native caller.
   --  @param Item Ready service
   --  @param Op Caller-owned operation object reused for every shard
   --  @exception Not_Running The service is not admitting operations
   procedure Invoke_On_Others
     (Item : in out Service;
      Op   : in out Operation'Class);

   --  ------------------------------------------------------------------
   --  Owning-shard fast path
   --  ------------------------------------------------------------------

   --  Scoped borrow of the calling task's own instance. The borrow holds an
   --  Execution_Groups.Thread_Pin, so the borrower cannot migrate while it
   --  is live, and it keeps the service from completing shutdown. Declare
   --  it, use it, and let it finalize in the borrowing task.
   --
   --     Ref : Local_Reference := Borrow_Local (Table);
   type Local_Reference (<>) is limited private;

   --  Borrow the instance owned by the calling task's current shard. The
   --  pin is acquired before the shard is resolved, so the answer cannot
   --  become stale.
   --  @param Item Ready service
   --  @return Scoped borrow released during finalization
   --  @exception Not_Running The service is not admitting operations
   --  @exception Not_Owner The caller is native, or is on a group this
   --     service does not own
   function Borrow_Local (Item : in out Service) return Local_Reference;

   --  Return the borrowed instance.
   --  @param Ref Live borrow
   --  @return Instance owned by the borrowing task's shard
   function Instance
     (Ref : Local_Reference) return not null access Service_Type;

   --  Return the shard that issued Ref.
   --  @param Ref Live borrow
   --  @return Owning shard
   function Owner (Ref : Local_Reference) return Shard_Id;

   --  ------------------------------------------------------------------
   --  Map and reduce
   --  ------------------------------------------------------------------

   --  Run Map on every shard's instance and fold the results on the
   --  caller. Map runs on the owning shard; Reduce runs on the calling
   --  task and never touches an instance. Shards are visited in ascending
   --  order, one at a time.
   --  @formal Mapped Value produced on one shard
   --  @formal Accumulator Caller-owned fold state
   --  @formal Map Per-shard producer executed on the owning shard
   --  @formal Reduce Caller-side fold, executed outside every shard
   generic
      type Mapped is private;
      type Accumulator is private;

      --  Produce one shard's contribution. This runs on the owning shard
      --  under the same rules as Execute.
      --  @param Instance Shard-owned application state
      --  @param Shard Shard executing the producer
      --  @param Value Contribution copied back to the caller
      with procedure Map
        (Instance : in out Service_Type;
         Shard    : Shard_Id;
         Value    : out Mapped);

      --  Fold one shard's contribution into the caller's accumulator.
      --  @param Into Caller-owned fold state
      --  @param Shard Shard that produced Value
      --  @param Value Contribution copied from the shard
      with procedure Reduce
        (Into  : in out Accumulator;
         Shard : Shard_Id;
         Value : Mapped);

   package Map_Reduce is

      --  Visit every shard in ascending order and fold the results.
      --  @param Item Ready service
      --  @param Into Caller-owned accumulator
      --  @exception Not_Running The service is not admitting operations
      procedure Run
        (Item : in out Service;
         Into : in out Accumulator);

   private
      type Map_Operation is limited new Operation with record
         Value : Mapped;
      end record;

      --  @exclude
      --  @param Op Producer wrapper submitted to one shard
      --  @param Instance Shard-owned application state
      --  @param Shard Shard executing the producer
      overriding procedure Execute
        (Op       : in out Map_Operation;
         Instance : in out Service_Type;
         Shard    : Shard_Id);
   end Map_Reduce;

private

   type Instance_Access is access all Service_Type;

   subtype Lane_Index is Positive range 1 .. Concurrency;

   --  Completed by the protected type below. The agent needs the registry
   --  and the registry needs the agent, so one of them is named first.
   type Registry;
   type Registry_Access is access all Registry;

   --  Resident executor for one lane of one shard. Lane 1 constructs and
   --  owns the instance in its own frame; further lanes, if any, borrow the
   --  published pointer. An agent crosses to its shard once and never
   --  migrates again.
   task type Agent is
      pragma Task_Info (Flyology.Lightweight_Task);
      --  Bind the agent to its shard before it leaves its home group.
      entry Assign
        (Shard : Shard_Id;
         Lane  : Lane_Index;
         Owner : Registry_Access);
      --  Execute one caller-owned operation to completion.
      entry Run_Operation (Op : in out Operation'Class);
      --  Leave the serving loop and finalize an owned instance.
      entry Leave;
   end Agent;

   type Agent_Access is access all Agent;
   --  Serve declares one of these, sized at run time, and publishes an
   --  Unchecked_Access to each element. Serve joins every element before
   --  leaving the frame, and the registry proves that no caller still holds
   --  a published pointer before that happens.
   type Lane_Group is array (Lane_Index) of aliased Agent;
   type Agent_Array is array (Shard_Id range <>) of Lane_Group;

   type Lane_Agents is array (Lane_Index) of Agent_Access;
   type Agent_Table is array (Shard_Id) of Lane_Agents;
   type Lane_Identities is array (Lane_Index) of
     Ada.Task_Identification.Task_Id;
   type Identity_Table is array (Shard_Id) of Lane_Identities;
   type Instance_Table is array (Shard_Id) of Instance_Access;

   --  Admission, publication, readiness, and in-flight accounting. Every
   --  borrow and every invocation enters and leaves this object, so
   --  shutdown can prove that no caller still holds a reference into an
   --  agent frame before the agents are allowed to leave.
   protected type Registry is
      procedure Begin_Service
        (Count    : Shard_Count;
         Accepted : out Boolean;
         Stopped  : out Boolean);
      procedure Publish_Agent
        (Shard    : Shard_Id;
         Lane     : Lane_Index;
         Executor : Agent_Access);
      procedure Publish_Instance
        (Shard    : Shard_Id;
         Lane     : Lane_Index;
         State    : Instance_Access;
         Identity : Ada.Task_Identification.Task_Id);
      procedure Publish_Lane
        (Shard    : Shard_Id;
         Lane     : Lane_Index;
         Identity : Ada.Task_Identification.Task_Id);
      procedure Publish_Failure (Failure : Service_Result);
      entry Await_Startup (Ready : out Boolean);
      entry Await_Admission (Ready : out Boolean);
      function Instance_Of (Shard : Shard_Id) return Instance_Access;
      procedure Open_Admission;
      entry Await_Stop_Request;
      procedure Request_Shutdown;
      entry Await_Quiescent;
      procedure Enter
        (Shard     : Shard_Id;
         Caller    : Ada.Task_Identification.Task_Id;
         Executors : out Lane_Agents;
         Admitted  : out Boolean;
         Reentry   : out Boolean;
         Armed     : not null access Boolean);
      procedure Borrow
        (Shard    : Shard_Id;
         State    : out Instance_Access;
         Admitted : out Boolean;
         Armed    : not null access Boolean);
      procedure Leave (Armed : not null access Boolean);
      function Running return Boolean;
      function Count return Natural;
      function Result return Service_Result;
   private
      Configured  : Boolean := False;
      Admitting   : Boolean := False;
      Stopping    : Boolean := False;
      Resolved    : Boolean := False;
      Failed      : Boolean := False;
      Shard_Total : Natural := 0;
      Published   : Natural := 0;
      In_Flight   : Natural := 0;
      Executors   : Agent_Table := (others => (others => null));
      States      : Instance_Table := (others => null);
      Identities  : Identity_Table :=
        (others =>
           (others => Ada.Task_Identification.Null_Task_Id));
      Outcome     : Service_Result;
   end Registry;

   --  Hands out one free lane of one shard. It exists only when
   --  Concurrency is greater than one; with the default of one lane the
   --  index range below is null, the array is empty, and every invocation
   --  relies on the agent's own entry queue for serialization.
   type Lane_Free_Set is array (Lane_Index) of Boolean;

   protected type Lane_Dispatcher is
      entry Acquire (Lane : out Lane_Index; Admitted : out Boolean);
      procedure Release (Lane : Lane_Index);
      procedure Open;
      procedure Close;
   private
      Free      : Lane_Free_Set := (others => True);
      Available : Natural := Concurrency;
      Opened    : Boolean := False;
   end Lane_Dispatcher;

   subtype Dispatcher_Range is Integer range
     0 .. (if Concurrency = 1 then -1 else Integer (Shard_Id'Last));
   type Dispatcher_Array is
     array (Dispatcher_Range) of aliased Lane_Dispatcher;

   type Service is limited record
      State       : aliased Registry;
      Dispatchers : Dispatcher_Array;
   end record;

   --  Releases one lane reservation and one in-flight registration. The
   --  registration is armed inside the same protected action that admits
   --  the caller, so an abort between admission and the entry call cannot
   --  strand the count.
   type Invocation_Guard is
     limited new Ada.Finalization.Limited_Controlled with record
      Home       : Registry_Access := null;
      Lanes      : access Lane_Dispatcher := null;
      Lane       : Lane_Index := Lane_Index'First;
      Lane_Held  : Boolean := False;
      Held       : aliased Boolean := False;
   end record;

   --  @exclude
   --  @param Item Invocation registration released on scope exit
   overriding procedure Finalize (Item : in out Invocation_Guard);

   --  Borrow_Local initializes Pin through the extended return's aggregate
   --  and resolves the shard afterwards, so the pin is already held when
   --  Execution_Groups.Current is read.
   type Local_Reference is limited record
      Pin    : Flyology.Execution_Groups.Thread_Pin;
      Guard  : Invocation_Guard;
      Target : Instance_Access := null;
      Shard  : Shard_Id := Shard_Id'First;
   end record;

end Flyology.Sharding.Services;
