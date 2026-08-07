with Ada.Exceptions;
with Ada.Finalization;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Interfaces;
with System;

--  Runs a bounded homogeneous group of child operations with structured Ada
--  task lifetime. Configure creates Capacity lightweight worker tasks; Spawn
--  copies operations into fixed scope storage and may start them immediately.
--  Join or scope finalization closes admission and joins every worker, so
--  Execute must observe its token and deadline when it can block indefinitely.
--  @formal Input_Type Immutable operation input
--  @formal Result_Type Operation result
--  @formal Execute Child operation implementation
generic
   type Input_Type is private;
   type Result_Type is private;
   with procedure Execute
     (Input    : Input_Type;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Result_Type);
package Flyology.Task_Scopes is

   --  Raised when a handle does not identify a spawned operation.
   Invalid_Handle : exception;

   --  Stable identity for one submitted operation. Handles are bound to the
   --  originating scope and are rejected by every other scope.
   type Operation_Handle is private;

   --  Bounded one-shot structured task group. Capacity is both the number of
   --  lightweight worker tasks created by Configure and the total number of
   --  operations accepted during the scope lifetime. The Parent token is
   --  borrowed and may be null; when present, cancellation is linked downward
   --  to the scope-owned token. Join closes admission. Finalization requests
   --  local cancellation, closes admission, and joins when Join was omitted.
   type Scope
     (Capacity : Positive;
      Parent   : access Flyology.Cancellation.Token) is
     limited new Ada.Finalization.Limited_Controlled with private;

   --  Install inherited cancellation and an absolute monotonic deadline before
   --  Spawn. Ada.Real_Time.Time_Last means no deadline. Children always
   --  receive a scope-owned token. Parent cancellation is linked downward
   --  asynchronously, while failure and finalization cancel only this scope.
   --  The call allocates and activates Capacity lightweight workers; it is the
   --  only operation that may configure Item. When allocation or activation
   --  fails part way through, finalization of Item still stops and releases
   --  the workers that were already created.
   --  Parent is the scope's access discriminant, so Ada enforces that the
   --  borrowed token outlives Item.
   --  @param Item Task scope
   --  @param Deadline Inherited absolute monotonic deadline
   --  @param Cancel_Siblings_On_Failure Whether one failure cancels siblings
   --  @exception Program_Error Item was already configured or its identity
   --     space is exhausted
   --  @exception Storage_Error Worker or cancellation-monitor allocation fails
   --  @exception Tasking_Error Worker or cancellation-monitor activation fails
   procedure Configure
     (Item       : in out Scope;
      Deadline   : Ada.Real_Time.Time;
      Cancel_Siblings_On_Failure : Boolean := True);

   --  Submit one operation without exceeding Capacity. Input is copied before
   --  admission is committed; an exception from that copy propagates without
   --  consuming a slot or defining Handle. A worker may begin Execute before
   --  Spawn returns. Before invoking Execute, the worker records an already
   --  requested scope token as Operation_Cancelled and an expired deadline as
   --  Flyology.IO.Timeout_Error.
   --  @param Item Configured task scope
   --  @param Input Operation input copied into scope storage
   --  @param Handle Stable result handle
   --  @exception Program_Error Item is not configured or admission was closed
   --  @exception Constraint_Error Capacity operations were already accepted
   procedure Spawn
     (Item   : in out Scope;
      Input  : Input_Type;
      Handle : out Operation_Handle);

   --  Close admission and wait for every submitted operation and worker.
   --  Exceptions are retained per operation and re-raised by Result. A second
   --  call after a successful Join is harmless. The caller waits through
   --  ordinary Ada tasking: a lightweight caller suspends cooperatively and a
   --  native caller blocks only its task's pthread.
   --  @param Item Configured task scope
   --  @exception Program_Error Item was not configured
   procedure Join (Item : in out Scope);

   --  Report whether an operation completed without exception.
   --  Join must have completed.
   --  @param Item Joined task scope
   --  @param Handle Operation handle
   --  @return True when Execute returned normally
   --  @exception Program_Error Join has not completed
   --  @exception Invalid_Handle Handle belongs to another scope or does not
   --     identify a submitted operation
   function Succeeded
     (Item   : Scope;
      Handle : Operation_Handle) return Boolean;

   --  Return an operation result or re-raise its captured exception with the
   --  original exception identity and retained message. Join must have
   --  completed.
   --  @param Item Joined task scope
   --  @param Handle Operation handle
   --  @return Operation result
   --  @exception Program_Error Join has not completed
   --  @exception Invalid_Handle Handle belongs to another scope or does not
   --     identify a submitted operation
   function Result
     (Item   : Scope;
      Handle : Operation_Handle) return Result_Type;

private
   type Input_Array is array (Positive range <>) of Input_Type;
   type Result_Array is array (Positive range <>) of Result_Type;
   type Boolean_Array is array (Positive range <>) of Boolean;
   type Exception_Id_Array is array (Positive range <>) of
     Ada.Exceptions.Exception_Id;
   type Exception_Message_Array is array (Positive range <>) of
     Ada.Strings.Unbounded.Unbounded_String;
   type Cancellation_Access is access all Flyology.Cancellation.Token;

   protected type Shared_State (Capacity : Positive) is
      procedure Configure
        (Token      : Cancellation_Access;
         Deadline   : Ada.Real_Time.Time;
         Cancel_On_Failure : Boolean);
      procedure Submit (Input : Input_Type; Index : out Positive);
      entry Next
        (Index : out Positive; Stop : out Boolean);
      procedure Operation_Context
        (Index    : Positive;
         Token    : out Cancellation_Access;
         Deadline : out Ada.Real_Time.Time;
         Cancel_On_Failure : out Boolean);
      procedure Operation_Input
        (Index : Positive; Input : out Input_Type);
      procedure Complete (Index : Positive; Value : Result_Type);
      procedure Fail
        (Index : Positive; Occurrence : Ada.Exceptions.Exception_Occurrence);
      procedure Close_Admission;
      entry Await_All;
      procedure Shutdown;
      procedure Set_Expected_Workers (Count : Natural);
      procedure Worker_Stopped;
      entry Await_Workers;
      function Submitted_Count return Natural;
      function Was_Successful (Index : Positive) return Boolean;
      function Result_Value (Index : Positive) return Result_Type;
      function Failure_Id
        (Index : Positive) return Ada.Exceptions.Exception_Id;
      function Failure_Message
        (Index : Positive) return Ada.Strings.Unbounded.Unbounded_String;
   private
      Inputs      : Input_Array (1 .. Capacity);
      Results     : Result_Array (1 .. Capacity);
      Successes   : Boolean_Array (1 .. Capacity) := (others => False);
      Failure_Ids : Exception_Id_Array (1 .. Capacity) :=
        (others => Ada.Exceptions.Null_Id);
      Failure_Messages : Exception_Message_Array (1 .. Capacity);
      Submitted   : Natural := 0;
      Next_Index  : Natural := 1;
      Completed   : Natural := 0;
      Closed      : Boolean := False;
      Stopping    : Boolean := False;
      Configured  : Boolean := False;
      Parent_Stop : Cancellation_Access;
      End_Time    : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Cancel_On_Failure_Value : Boolean := True;
      Stopped_Workers : Natural := 0;
      Expected_Workers : Natural := 0;
      Expected_Workers_Set : Boolean := False;
   end Shared_State;

   task type Worker is
      pragma Task_Info (Flyology.Lightweight_Task);
      entry Start (State_Address : System.Address);
      entry Stop;
   end Worker;
   --  Workers are held one access value each. An array of task objects is
   --  created by a single allocator, so a failed activation would leave the
   --  successfully activated siblings unreachable and unstoppable; creating
   --  one task at a time keeps every created worker recorded in the scope.
   type Worker_Access is access Worker;
   type Worker_Array is array (Positive range <>) of Worker_Access;
   type Worker_Array_Access is access Worker_Array;

   task type Cancellation_Monitor is
      pragma Task_Info (Flyology.Lightweight_Task);
      --  Release is the scope-owned one-shot signal that ends the wait on
      --  Parent; Stop is the rendezvous that acknowledges it.
      entry Start
        (Parent  : Cancellation_Access;
         Child   : Cancellation_Access;
         Release : Cancellation_Access);
      entry Stop;
   end Cancellation_Monitor;
   type Cancellation_Monitor_Access is access Cancellation_Monitor;

   type Scope
     (Capacity : Positive;
      Parent   : access Flyology.Cancellation.Token) is
     limited new Ada.Finalization.Limited_Controlled with record
      State       : aliased Shared_State (Capacity);
      Workers     : Worker_Array_Access;
      Monitor     : Cancellation_Monitor_Access;
      Local_Stop  : aliased Flyology.Cancellation.Token;
      --  One-shot release signal for the cancellation monitor. No operation
      --  ever borrows its wake descriptor, so requesting it cannot fail.
      Monitor_Release : aliased Flyology.Cancellation.Token;
      Token       : Cancellation_Access;
      Is_Configured : Boolean := False;
      Cleanup_Required : Boolean := False;
      Is_Joined     : Boolean := False;
      Monitor_Stopped : Boolean := False;
      Created_Workers : Natural := 0;    --  Workers allocated and activated
      Activated_Workers : Natural := 0;  --  Workers that accepted Start
      Identity : Interfaces.Unsigned_64 := 0;
   end record;

   type Operation_Handle is record
      Owner : Interfaces.Unsigned_64 := 0;
      Index : Positive := 1;
   end record;

   --  @exclude
   --  @param Item Task scope being finalized
   overriding procedure Finalize (Item : in out Scope);

end Flyology.Task_Scopes;
