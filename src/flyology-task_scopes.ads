with Ada.Exceptions;
with Ada.Finalization;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with System;

--  Runs a bounded homogeneous group of child operations with structured Ada
--  task lifetime. Scope exit cancels and joins unfinished children.
--  @formal Input_Type Immutable operation input
--  @formal Result_Type Operation result
--  @formal Execute Child operation implementation
--  @formal Model Fixed task designation selected at child activation
generic
   type Input_Type is private;
   type Result_Type is private;
   with procedure Execute
     (Input    : Input_Type;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Result_Type);
   Model : Flyology.Execution_Model := Flyology.Lightweight_Task;
package Flyology.Task_Scopes is

   --  Raised when a handle does not identify a spawned operation.
   Invalid_Handle : exception;

   --  Stable index identifying one submitted operation.
   type Operation_Handle is new Positive;

   --  Bounded one-shot structured task group. Capacity bounds both child Ada
   --  tasks and total operations. Join closes admission. Finalization requests
   --  cancellation, closes admission, and joins when Join was omitted.
   type Scope (Capacity : Positive) is
     limited new Ada.Finalization.Limited_Controlled with private;

   --  Install inherited cancellation and absolute deadline before Spawn.
   --  A null token selects a scope-owned token. When sibling cancellation is
   --  enabled, a child failure requests the inherited token.
   --  @param Item Task scope
   --  @param Token Borrowed parent token, or null
   --  @param Deadline Inherited absolute monotonic deadline
   --  @param Cancel_Siblings_On_Failure Whether one failure cancels siblings
   procedure Configure
     (Item       : in out Scope;
      Token      : access Flyology.Cancellation.Token;
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
        (Index    : out Positive;
         Input    : out Input_Type;
         Stop     : out Boolean;
         Token    : out Cancellation_Access;
         Deadline : out Ada.Real_Time.Time;
         Cancel_On_Failure : out Boolean);
      procedure Complete (Index : Positive; Value : Result_Type);
      procedure Fail
        (Index : Positive; Occurrence : Ada.Exceptions.Exception_Occurrence);
      procedure Close_Admission;
      entry Await_All;
      procedure Shutdown;
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
   end Shared_State;

   task type Worker is
      pragma Task_Info (Model);
      entry Start (State_Address : System.Address);
      entry Stop;
   end Worker;
   type Worker_Array is array (Positive range <>) of Worker;

   type Scope (Capacity : Positive) is
     limited new Ada.Finalization.Limited_Controlled with record
      State       : aliased Shared_State (Capacity);
      Workers     : Worker_Array (1 .. Capacity);
      Local_Stop  : aliased Flyology.Cancellation.Token;
      Token       : Cancellation_Access;
      Is_Configured : Boolean := False;
      Is_Joined     : Boolean := False;
   end record;

   --  @exclude
   --  @param Item Task scope being finalized
   overriding procedure Finalize (Item : in out Scope);

end Flyology.Task_Scopes;
