with Ada.Exceptions;
with Ada.Finalization;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Interfaces;
with System;

--  Runs a bounded homogeneous group of child operations with structured Ada
--  task lifetime. Scope exit cancels and joins unfinished children.
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

   --  Bounded one-shot structured task group. Capacity bounds both child Ada
   --  tasks and total operations. Join closes admission. Finalization requests
   --  cancellation, closes admission, and joins when Join was omitted.
   type Scope
     (Capacity : Positive;
      Parent   : access Flyology.Cancellation.Token) is
     limited new Ada.Finalization.Limited_Controlled with private;

   --  Install inherited cancellation and absolute deadline before Spawn.
   --  Children always receive a scope-owned token. Parent cancellation is
   --  linked downward while failure and finalization cancel only this scope.
   --  Parent is the scope's access discriminant, so Ada enforces that the
   --  borrowed token outlives Item.
   --  @param Item Task scope
   --  @param Deadline Inherited absolute monotonic deadline
   --  @param Cancel_Siblings_On_Failure Whether one failure cancels siblings
   procedure Configure
     (Item       : in out Scope;
      Deadline   : Ada.Real_Time.Time;
      Cancel_Siblings_On_Failure : Boolean := True);

   --  Submit one operation without exceeding Capacity.
   --  @param Item Configured task scope
   --  @param Input Operation input copied into scope storage
   --  @param Handle Stable result handle
   procedure Spawn
     (Item   : in out Scope;
      Input  : Input_Type;
      Handle : out Operation_Handle);

   --  Close admission and wait for every submitted operation. Exceptions are
   --  retained per operation and re-raised by Result.
   --  @param Item Configured task scope
   procedure Join (Item : in out Scope);

   --  Report whether an operation completed without exception.
   --  Join must have completed.
   --  @param Item Joined task scope
   --  @param Handle Operation handle
   --  @return True when Execute returned normally
   function Succeeded
     (Item   : Scope;
      Handle : Operation_Handle) return Boolean;

   --  Return an operation result or re-raise its captured exception.
   --  Join must have completed.
   --  @param Item Joined task scope
   --  @param Handle Operation handle
   --  @return Operation result
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
   type Worker_Array is array (Positive range <>) of Worker;
   type Worker_Array_Access is access Worker_Array;

   task type Cancellation_Monitor is
      pragma Task_Info (Flyology.Lightweight_Task);
      entry Start
        (Parent : Cancellation_Access;
         Child  : Cancellation_Access);
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
      Token       : Cancellation_Access;
      Is_Configured : Boolean := False;
      Cleanup_Required : Boolean := False;
      Is_Joined     : Boolean := False;
      Monitor_Stopped : Boolean := False;
      Activated_Workers : Natural := 0;
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
