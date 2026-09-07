with Ada.Exceptions;
with Ada.Finalization;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.Wake_Sources;
private with Flyology.Native_Executor_Policy;
with Interfaces;
with System;

--  Supplies an application-owned bounded native-task boundary. A fixed pool
--  runs CPU-heavy or blocking foreign work without occupying event-loop
--  pthreads. Admission is nonblocking and outstanding result storage is
--  bounded independently from worker count. Executor finalization joins every
--  worker. Execute must therefore honor its token/deadline when it can block;
--  foreign calls that cannot be interrupted require process isolation for a
--  bounded application shutdown.
--
--  An Operation_Handle is declared for one aliased Executor and may be reused
--  only after Await or Abandon consumes its accepted operation. Await keeps
--  ordinary synchronous Ada semantics: lightweight callers suspend on the
--  completion descriptor while native callers block only their pthread.
--  @formal Input_Type Immutable operation input
--  @formal Result_Type Operation result
--  @formal Execute Native operation implementation

generic
   type Input_Type is private;
   type Result_Type is private;
   with
     procedure Execute
       (Input    : Input_Type;
        Token    : access Flyology.Cancellation.Token;
        Deadline : Ada.Real_Time.Time;
        Result   : out Result_Type);
package Flyology.Native_Executors is

   --  Raised for a stale, rejected, or already consumed operation handle.
   Invalid_Handle : exception;

   --  Application-owned executor. Workers is the aggregate native pthread
   --  bound; Capacity bounds queued, running, and completed-but-unclaimed
   --  operations.
   type Executor
     (Workers  : Positive;
      Capacity : Positive)
   is limited new Ada.Finalization.Limited_Controlled with private;

   --  Point-in-time executor counters. Cumulative counters wrap modulo
   --  2**64. Outstanding includes queued, running, and completed results that
   --  have not yet been consumed or abandoned.
   --  @field Accepted_Submissions Operations admitted since initialization
   --  @field Rejected_Submissions Submissions refused by bounded admission
   --  @field Successful_Executions Execute calls that returned normally
   --  @field Failed_Executions Execute calls that raised an exception
   --  @field Abandoned_Operations Accepted handles relinquished by callers
   --  @field Outstanding_Operations Currently occupied operation slots
   --  @field Queued_Operations Operations awaiting a native worker
   --  @field Running_Operations Operations currently executing natively
   --  @field Peak_Outstanding Highest occupied-slot count observed
   type Executor_Statistics is record
      Accepted_Submissions   : Interfaces.Unsigned_64 := 0;
      Rejected_Submissions   : Interfaces.Unsigned_64 := 0;
      Successful_Executions  : Interfaces.Unsigned_64 := 0;
      Failed_Executions      : Interfaces.Unsigned_64 := 0;
      Abandoned_Operations   : Interfaces.Unsigned_64 := 0;
      Outstanding_Operations : Natural := 0;
      Queued_Operations      : Natural := 0;
      Running_Operations     : Natural := 0;
      Peak_Outstanding       : Natural := 0;
   end record;

   --  Single-use identity for one accepted operation. The access discriminant
   --  makes Ada reject a handle whose lifetime could exceed its executor. An
   --  inactive handle may be reused for another Submit to the same executor.
   --  @field Owner Borrowed executor that must outlive the handle
   type Operation_Handle (Owner : not null access Executor) is limited private;

   --  Activate the fixed worker pool before concurrent submissions. Start is
   --  idempotent while the executor remains open and must be called by the
   --  owning application during setup.
   --  @param Item Application-owned executor
   --  @exception Program_Error Shutdown has started
   --  @exception Storage_Error Worker storage allocation fails
   --  @exception Tasking_Error Native worker activation fails
   procedure Start (Item : aliased in out Executor);

   --  Stop admission, request cancellation for every outstanding operation,
   --  and join all native workers. Shutdown is terminal and idempotent; Start
   --  raises Program_Error afterward. Execute must observe its executor-owned
   --  token or deadline for this call to remain bounded. Explicit Shutdown
   --  reports cleanup errors before scope exit; controlled finalization
   --  performs the same cleanup when a started executor leaves its task master.
   --  If cancellation wake signaling fails, terminal cancellation remains
   --  recorded; cleanup completes before Shutdown propagates Program_Error.
   --  @param Item Application-owned executor
   --  @exception Program_Error An executor-owned cancellation wake could not
   --  be signaled
   procedure Shutdown (Item : in out Executor);

   --  Submit without waiting. Accepted is false when bounded storage is full,
   --  shutdown has begun, or an idle worker has not yet reached its dispatch
   --  rendezvous; Handle then remains inactive and reusable. The executor
   --  samples Token at submission and gives Execute an executor-owned
   --  cancellation token; it never retains the caller's token. Deadline is an
   --  absolute monotonic deadline passed to Execute. A worker converts a token
   --  already requested before dispatch to Operation_Cancelled and an already
   --  expired deadline to Flyology.IO.Timeout_Error. An accepted handle must
   --  not outlive Item.
   --  @param Item Application-owned executor
   --  @param Input Operation input copied into bounded storage
   --  @param Token Optional borrowed cancellation token
   --  @param Deadline Absolute monotonic deadline
   --  @param Handle Single-use result handle when accepted
   --  @param Accepted Whether bounded admission succeeded
   --  @exception Program_Error Start has not completed
   --  @exception Invalid_Handle Handle belongs to another executor or already
   --     identifies an accepted operation
   procedure Submit
     (Item     : aliased in out Executor;
      Input    : Input_Type;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Handle   : in out Operation_Handle;
      Accepted : out Boolean);

   --  Wait for one accepted operation, return its result, or re-raise its
   --  captured exception with the original exception identity and retained
   --  message. Copying a result into bounded storage runs Result_Type
   --  assignment, so an exception from that copy becomes the operation's
   --  captured outcome instead of a successful result.
   --  Deadline bounds only this wait; the operation receives the
   --  separate deadline supplied to Submit. Ada.Real_Time.Time_Last means no
   --  wait deadline. Cancellation or deadline expiry abandons the result and
   --  requests the executor-owned operation token. Each handle is consumed
   --  exactly once; finalizing an unconsumed handle performs the same abandon.
   --  @param Item Application-owned executor
   --  @param Handle Previously accepted single-use handle
   --  @param Result Completed result
   --  @param Token Optional cancellation source for the waiting caller
   --  @param Deadline Absolute deadline for the waiting caller
   --  @exception Invalid_Handle Handle is inactive, stale, or belongs to
   --     another executor
   --  @exception Operation_Cancelled
   --     Flyology.Cancellation.Operation_Cancelled is raised when Token is
   --     requested before the result is consumed
   --  @exception Timeout_Error Flyology.IO.Timeout_Error is raised when
   --     Deadline expires before the result is consumed
   --  @exception Device_Error Flyology.IO.Device_Error is raised when
   --     completion readiness polling fails
   --  @exception Program_Error A completion or cancellation wake source fails
   procedure Await
     (Item     : aliased in out Executor;
      Handle   : in out Operation_Handle;
      Result   : out Result_Type;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last);

   --  Relinquish one accepted result and request cooperative cancellation.
   --  Running foreign code may continue until it returns, but its slot is
   --  reclaimed automatically at completion.
   --  @param Item Owning executor
   --  @param Handle Accepted operation handle
   --  @exception Invalid_Handle Handle is inactive, stale, or belongs to
   --     another executor
   --  @exception Program_Error The operation's cancellation wake cannot be
   --     signalled; the handle is still consumed
   procedure Abandon (Item : aliased in out Executor; Handle : in out Operation_Handle);

   --  Read executor admission, execution, and occupancy counters atomically.
   --  This is an observability operation; it does not wait for work or change
   --  executor state.
   --  @param Item Executor to inspect
   --  @return Point-in-time executor statistics
   function Statistics (Item : Executor) return Executor_Statistics;

private
   package Policy renames Flyology.Native_Executor_Policy;
   subtype Slot_Status is Policy.Slot_State;
   Free      : constant Slot_Status := Policy.Free;
   Queued    : constant Slot_Status := Policy.Queued;
   Running   : constant Slot_Status := Policy.Running;
   Completed : constant Slot_Status := Policy.Completed;

   type Input_Array is array (Positive range <>) of Input_Type;
   type Result_Array is array (Positive range <>) of Result_Type;
   type Token_Access is access all Flyology.Cancellation.Token;
   type Token_Array is array (Positive range <>) of Token_Access;
   type Token_Owner is new Ada.Finalization.Limited_Controlled with record
      Value : Token_Access := null;
   end record;
   --  @exclude
   --  @param Owner Token holder being finalized
   overriding
   procedure Finalize (Owner : in out Token_Owner);
   --  Zero remains the invalid-handle sentinel; modular increment keeps a
   --  heavily reused slot from becoming permanently unavailable.
   subtype Generation_Number is Interfaces.Unsigned_64;
   type Generation_Array is array (Positive range <>) of Generation_Number;
   type Wake_Array is array (Positive range <>) of Flyology.Wake_Sources.Source;
   type Time_Array is array (Positive range <>) of Ada.Real_Time.Time;
   type Natural_Array is array (Positive range <>) of Natural;
   type Boolean_Array is array (Positive range <>) of Boolean;
   type Status_Array is array (Positive range <>) of Slot_Status;
   type Worker_Status is (Worker_Starting, Worker_Idle, Worker_Dispatching, Worker_Active, Worker_Terminated);
   type Worker_Status_Array is array (Positive range <>) of Worker_Status;
   type Exception_Id_Array is array (Positive range <>) of Ada.Exceptions.Exception_Id;
   type Message_Array is array (Positive range <>) of Ada.Strings.Unbounded.Unbounded_String;

   protected type Shared_State (Capacity, Workers : Positive) is
      procedure Submit
        (Input            : Input_Type;
         Token            : Token_Access;
         Deadline         : Ada.Real_Time.Time;
         Slot             : out Positive;
         Generation       : out Generation_Number;
         Prior_Generation : out Generation_Number;
         Prior_Peak       : out Natural;
         Replaced_Token   : out Token_Access;
         Dispatch_Worker  : out Natural;
         Accepted         : out Boolean);
      procedure Rollback_Dispatch
        (Slot             : Positive;
         Generation       : Generation_Number;
         Prior_Generation : Generation_Number;
         Prior_Peak       : Natural;
         Worker           : Positive;
         Replaced_Token   : Token_Access;
         Rolled_Back      : out Boolean);
      procedure Try_Next (Worker : Positive; Slot : out Positive; Stop, Available : out Boolean);
      procedure Worker_Started (Worker : Positive);
      procedure Dispatch_Accepted (Worker : Positive);
      procedure Operation_Data
        (Slot     : Positive;
         Input    : out Input_Type;
         Token    : out Token_Access;
         Deadline : out Ada.Real_Time.Time);
      procedure Complete (Slot : Positive; Result : Result_Type);
      procedure Fail (Slot : Positive; Error : Ada.Exceptions.Exception_Occurrence);
      procedure Try_Await
        (Slot       : Positive;
         Generation : Generation_Number;
         Result     : out Result_Type;
         Error_Id   : out Ada.Exceptions.Exception_Id;
         Message    : out Ada.Strings.Unbounded.Unbounded_String;
         Ready      : out Boolean);
      procedure Wait_Source
        (Slot       : Positive;
         Generation : Generation_Number;
         FD         : out Flyology.IO.Descriptor;
         Ready      : out Boolean);
      procedure Abandon (Slot : Positive; Generation : Generation_Number);
      --  Elect one cleanup owner; later callers wait for Complete_Shutdown.
      procedure Begin_Shutdown (Owner : out Boolean);
      entry Await_Dispatch_Resolution;
      procedure Signal_Shutdown_Completion (Slot : Positive);
      procedure Request_Cancellation (Slot : Positive);
      procedure Set_Expected_Workers (Count : Natural);
      function Needs_Stop (Worker : Positive) return Boolean;
      procedure Worker_Stopped (Worker : Positive; Selected_Terminate : Boolean);
      entry Await_Stopped;
      function Master_Owns_Worker_Storage return Boolean;
      procedure Take_Token (Slot : Positive; Owner : not null access Token_Owner);
      procedure Complete_Shutdown;
      entry Await_Shutdown;
      function Shutdown_Started return Boolean;
      function Statistics return Executor_Statistics;
   private
      Inputs                  : Input_Array (1 .. Capacity);
      Results                 : Result_Array (1 .. Capacity);
      Tokens                  : Token_Array (1 .. Capacity) := (others => null);
      Deadlines               : Time_Array (1 .. Capacity) := (others => Ada.Real_Time.Time_Last);
      Generations             : Generation_Array (1 .. Capacity) := (others => 0);
      Status                  : Status_Array (1 .. Capacity) := (others => Free);
      Detached                : Boolean_Array (1 .. Capacity) := (others => False);
      Error_Ids               : Exception_Id_Array (1 .. Capacity) := (others => Ada.Exceptions.Null_Id);
      Messages                : Message_Array (1 .. Capacity);
      Wakes                   : Wake_Array (1 .. Capacity);
      Wake_Armed              : Boolean_Array (1 .. Capacity) := (others => False);
      Wake_Pending            : Boolean_Array (1 .. Capacity) := (others => False);
      Queue                   : Natural_Array (1 .. Capacity) := (others => 0);
      Head                    : Positive := 1;
      Tail                    : Positive := 1;
      Queue_Count             : Natural := 0;
      Pending_Dispatch_Slot   : Natural := 0;
      Pending_Dispatch_Worker : Natural := 0;
      Worker_States           : Worker_Status_Array (1 .. Workers) := (others => Worker_Starting);
      Stopping                : Boolean := False;
      Stopped_Workers         : Natural := 0;
      Master_Terminations     : Natural := 0;
      Expected_Workers        : Natural := 0;
      Expected_Workers_Set    : Boolean := False;
      Shutdown_Complete       : Boolean := False;
      Counters                : Executor_Statistics;
   end Shared_State;

   type Shared_State_Access is access all Shared_State;
   type Handle_Guard is new Ada.Finalization.Limited_Controlled with record
      State      : Shared_State_Access := null;
      Slot       : Positive := 1;
      Generation : Generation_Number := 0;
      Active     : Boolean := False;
   end record;

   --  @exclude
   --  @param Item Automatically abandoned operation handle
   overriding
   procedure Finalize (Item : in out Handle_Guard);

   type Operation_Handle (Owner : not null access Executor) is limited record
      Guard : Handle_Guard;
   end record;

   task type Worker is
      pragma Task_Info (Flyology.Native_Task);
      entry Start (State : System.Address; Index : Positive);
      entry Dispatch;
      entry Stop;
   end Worker;
   type Worker_Array is array (Positive range <>) of Worker;
   type Worker_Array_Access is access Worker_Array;

   type Executor
     (Workers  : Positive;
      Capacity : Positive)
   is limited new Ada.Finalization.Limited_Controlled with record
      State             : aliased Shared_State (Capacity, Workers);
      Pool              : Worker_Array_Access;
      Started           : Boolean := False;
      Activated_Workers : Natural := 0;
   end record;

   --  @exclude
   --  @param Item Executor being initialized
   overriding
   procedure Initialize (Item : in out Executor);
   --  @exclude
   --  @param Item Executor being finalized
   overriding
   procedure Finalize (Item : in out Executor);

end Flyology.Native_Executors;
