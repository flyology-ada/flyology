with Ada.Exceptions;
with Ada.Finalization;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.Wake_Sources;
with Interfaces;
with System;

--  Supplies an application-owned bounded native-task boundary. A fixed pool
--  runs CPU-heavy or blocking foreign work without occupying event-loop
--  pthreads. Admission is nonblocking and outstanding result storage is
--  bounded independently from worker count. Executor finalization joins every
--  worker. Execute must therefore honor its token/deadline when it can block;
--  foreign calls that cannot be interrupted require process isolation for a
--  bounded application shutdown.
--  @formal Input_Type Immutable operation input
--  @formal Result_Type Operation result
--  @formal Execute Native operation implementation
generic
   type Input_Type is private;
   type Result_Type is private;
   with procedure Execute
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
      Capacity : Positive) is
     limited new Ada.Finalization.Limited_Controlled with private;

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
   --  makes Ada reject a handle whose lifetime could exceed its executor.
   --  @field Owner Borrowed executor that must outlive the handle
   type Operation_Handle
     (Owner : not null access Executor) is limited private;

   --  Activate the fixed worker pool before concurrent submissions. Start is
   --  idempotent and must be called by the owning application during setup.
   --  @param Item Application-owned executor
   procedure Start (Item : aliased in out Executor);

   --  Stop admission, request cancellation for every outstanding operation,
   --  and join all native workers. Shutdown is terminal and idempotent; Start
   --  raises Program_Error afterward. Execute must observe its executor-owned
   --  token or deadline for this call to remain bounded. Call Shutdown before
   --  leaving an Ada task master that contains a started executor; controlled
   --  finalization performs the same operation only as a fallback.
   --  @param Item Application-owned executor
   procedure Shutdown (Item : in out Executor);

   --  Submit without waiting. Accepted is false when bounded storage is full
   --  or shutdown has begun. The executor samples Token at submission and
   --  gives Execute an executor-owned cancellation token; it never retains the
   --  caller's token. An accepted handle must not outlive Item.
   --  @param Item Application-owned executor
   --  @param Input Operation input copied into bounded storage
   --  @param Token Optional borrowed cancellation token
   --  @param Deadline Absolute monotonic deadline
   --  @param Handle Single-use result handle when accepted
   --  @param Accepted Whether bounded admission succeeded
   procedure Submit
     (Item     : aliased in out Executor;
      Input    : Input_Type;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Handle   : in out Operation_Handle;
      Accepted : out Boolean);

   --  Wait for one accepted operation, return its result, or re-raise its
   --  captured exception. Cancellation or deadline expiry abandons the result
   --  and requests the executor-owned operation token. Each handle is consumed
   --  exactly once; finalizing an unconsumed handle performs the same abandon.
   --  @param Item Application-owned executor
   --  @param Handle Previously accepted single-use handle
   --  @param Result Completed result
   --  @param Token Optional cancellation source for the waiting caller
   --  @param Deadline Absolute deadline for the waiting caller
   procedure Await
     (Item   : aliased in out Executor;
      Handle : in out Operation_Handle;
      Result : out Result_Type;
      Token  : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last);

   --  Relinquish one accepted result and request cooperative cancellation.
   --  Running foreign code may continue until it returns, but its slot is
   --  reclaimed automatically at completion.
   --  @param Item Owning executor
   --  @param Handle Accepted operation handle
   procedure Abandon
     (Item : aliased in out Executor; Handle : in out Operation_Handle);

   --  Read executor admission, execution, and occupancy counters atomically.
   --  This is an observability operation; it does not wait for work or change
   --  executor state.
   --  @param Item Executor to inspect
   --  @return Point-in-time executor statistics
   function Statistics (Item : Executor) return Executor_Statistics;

private
   type Input_Array is array (Positive range <>) of Input_Type;
   type Result_Array is array (Positive range <>) of Result_Type;
   type Token_Access is access all Flyology.Cancellation.Token;
   type Token_Array is array (Positive range <>) of Token_Access;
   --  Zero remains the invalid-handle sentinel; modular increment keeps a
   --  heavily reused slot from becoming permanently unavailable.
   subtype Generation_Number is Interfaces.Unsigned_64;
   type Generation_Array is array (Positive range <>) of Generation_Number;
   type Wake_Array is array (Positive range <>) of
     Flyology.Wake_Sources.Source;
   type Time_Array is array (Positive range <>) of Ada.Real_Time.Time;
   type Natural_Array is array (Positive range <>) of Natural;
   type Boolean_Array is array (Positive range <>) of Boolean;
   type Slot_Status is (Free, Queued, Running, Completed);
   type Status_Array is array (Positive range <>) of Slot_Status;
   type Exception_Id_Array is array (Positive range <>) of
     Ada.Exceptions.Exception_Id;
   type Message_Array is array (Positive range <>) of
     Ada.Strings.Unbounded.Unbounded_String;

   protected type Shared_State (Capacity : Positive) is
      procedure Submit
        (Input      : Input_Type;
         Token      : Token_Access;
         Deadline   : Ada.Real_Time.Time;
         Slot       : out Positive;
         Generation : out Generation_Number;
         Replaced_Token : out Token_Access;
         Accepted   : out Boolean);
      entry Next
        (Slot : out Positive; Stop : out Boolean);
      procedure Operation_Data
        (Slot     : Positive;
         Input    : out Input_Type;
         Token    : out Token_Access;
         Deadline : out Ada.Real_Time.Time);
      procedure Complete (Slot : Positive; Result : Result_Type);
      procedure Fail
        (Slot : Positive; Error : Ada.Exceptions.Exception_Occurrence);
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
      procedure Abandon
        (Slot       : Positive;
         Generation : Generation_Number);
      procedure Shutdown;
      procedure Token_At (Slot : Positive; Token : out Token_Access);
      procedure Set_Expected_Workers (Count : Natural);
      procedure Worker_Stopped;
      entry Await_Stopped;
      procedure Take_Token (Slot : Positive; Token : out Token_Access);
      function Statistics return Executor_Statistics;
   private
      Inputs      : Input_Array (1 .. Capacity);
      Results     : Result_Array (1 .. Capacity);
      Tokens      : Token_Array (1 .. Capacity) := (others => null);
      Deadlines   : Time_Array (1 .. Capacity) :=
        (others => Ada.Real_Time.Time_Last);
      Generations : Generation_Array (1 .. Capacity) := (others => 0);
      Status      : Status_Array (1 .. Capacity) := (others => Free);
      Detached    : Boolean_Array (1 .. Capacity) := (others => False);
      Error_Ids   : Exception_Id_Array (1 .. Capacity) :=
        (others => Ada.Exceptions.Null_Id);
      Messages    : Message_Array (1 .. Capacity);
      Wakes       : Wake_Array (1 .. Capacity);
      Wake_Armed  : Boolean_Array (1 .. Capacity) := (others => False);
      Wake_Pending : Boolean_Array (1 .. Capacity) := (others => False);
      Queue       : Natural_Array (1 .. Capacity) := (others => 0);
      Head        : Positive := 1;
      Tail        : Positive := 1;
      Queue_Count : Natural := 0;
      Stopping    : Boolean := False;
      Stopped_Workers : Natural := 0;
      Expected_Workers : Natural := 0;
      Expected_Workers_Set : Boolean := False;
      Counters : Executor_Statistics;
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
   overriding procedure Finalize (Item : in out Handle_Guard);

   type Operation_Handle
     (Owner : not null access Executor) is limited record
      Guard : Handle_Guard;
   end record;

   task type Worker is
      pragma Task_Info (Flyology.Native_Task);
      entry Start (State : System.Address);
      entry Stop;
   end Worker;
   type Worker_Array is array (Positive range <>) of Worker;
   type Worker_Array_Access is access Worker_Array;

   type Executor
     (Workers  : Positive;
      Capacity : Positive) is
     limited new Ada.Finalization.Limited_Controlled with record
      State : aliased Shared_State (Capacity);
      Pool  : Worker_Array_Access;
      Started : Boolean := False;
      Shutdown_Complete : Boolean := False;
      Activated_Workers : Natural := 0;
   end record;

   --  @exclude
   --  @param Item Executor being initialized
   overriding procedure Initialize (Item : in out Executor);
   --  @exclude
   --  @param Item Executor being finalized
   overriding procedure Finalize (Item : in out Executor);

end Flyology.Native_Executors;
