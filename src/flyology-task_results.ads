with Ada.Finalization;
with Ada.Task_Identification;
with Flyology.Operations;
with Interfaces.C;
with System;

package Flyology.Task_Results
  with Preelaborate
is

   --  Provides fixed task-owned records of Ada task termination. The
   --  facility observes task exit only; it does not catch, resume, restart,
   --  or otherwise supervise a terminated task.

   --  Raised by Finish after a scoped task-result wait is cancelled.
   Operation_Cancelled : exception renames Flyology.Operations.Operation_Cancelled;

   --  Maximum retained exception-name bytes.
   Exception_Name_Capacity    : constant := 96;
   --  Maximum retained exception-message bytes.
   Exception_Message_Capacity : constant := 128;

   --  Terminal classification copied from GNARL's task wrapper.
   --  @enum Normal_Completion The task body and its master completed normally
   --  @enum Unhandled_Exception An exception escaped the task body
   --  @enum Abnormal_Completion GNARL classified task exit as abnormal
   type Exit_Cause is (Normal_Completion, Unhandled_Exception, Abnormal_Completion);

   --  Fixed exception identity copied into a terminal result.
   --  @field Length Number of meaningful characters in Data
   --  @field Truncated Whether the source name exceeded the fixed capacity
   --  @field Data Fixed storage; characters after Length are unspecified
   type Bounded_Exception_Name is record
      Length    : Natural range 0 .. Exception_Name_Capacity := 0;
      Truncated : Boolean := False;
      Data      : String (1 .. Exception_Name_Capacity) := (others => ' ');
   end record;

   --  Fixed exception message copied into a terminal result.
   --  @field Length Number of meaningful characters in Data
   --  @field Truncated Whether the source message exceeded the fixed capacity
   --  @field Data Fixed storage; characters after Length are unspecified
   type Bounded_Exception_Message is record
      Length    : Natural range 0 .. Exception_Message_Capacity := 0;
      Truncated : Boolean := False;
      Data      : String (1 .. Exception_Message_Capacity) := (others => ' ');
   end record;

   --  Return the meaningful exception-name characters.
   --  @param Item Bounded exception name
   --  @return Copied exception name without unused fixed storage
   function Text (Item : Bounded_Exception_Name) return String
   is (Item.Data (1 .. Item.Length));

   --  Return the meaningful exception-message characters.
   --  @param Item Bounded exception message
   --  @return Copied exception message without unused fixed storage
   function Text (Item : Bounded_Exception_Message) return String
   is (Item.Data (1 .. Item.Length));

   --  One immutable terminal observation. Exception fields are empty unless
   --  Cause is Unhandled_Exception.
   --  @field Cause GNARL terminal classification
   --  @field Exception_Name Bounded fully qualified exception identity
   --  @field Exception_Message Bounded message from the exception occurrence
   type Task_Result is record
      Cause             : Exit_Cause := Normal_Completion;
      Exception_Name    : Bounded_Exception_Name;
      Exception_Message : Bounded_Exception_Message;
   end record;

   --  Availability of a task-owned terminal result.
   --  @enum Not_Terminal The task has not reached its terminal publication
   --  point
   --  @enum Terminal A fixed result was copied from the task-owned sidecar
   type Observation_Status is (Not_Terminal, Terminal);

   --  One atomic observation. The discriminant prevents callers from reading
   --  a result that was not available.
   --  @field Status Whether a terminal result was copied
   --  @field Result Terminal result when Status is Terminal
   type Task_Observation (Status : Observation_Status := Not_Terminal) is record
      case Status is
         when Not_Terminal =>
            null;

         when Terminal =>
            Result : Task_Result;
      end case;
   end record;

   --  Atomically copy T's terminal result without waiting. The result remains
   --  available until the task object is reclaimed. The caller must keep T's
   --  task object alive and obey Ada.Task_Identification's Task_Id lifetime
   --  rules. The operation performs no allocation and invokes no user
   --  callback. Only a task that begins executing its body publishes a
   --  result, so a task whose activation failed stays Not_Terminal even
   --  though Ada already reports it as terminated.
   --  @param T Task whose terminal state is observed
   --  @return Terminal with a copied result, or Not_Terminal
   --  @exception Program_Error T is null, lacks Flyology-owned result
   --  storage, or the runtime and library result ABIs differ
   function Observe (T : Ada.Task_Identification.Task_Id) return Task_Observation;

   --  Wait up to Timeout for T's terminal result and return a copied
   --  observation. A negative timeout waits indefinitely, zero only checks,
   --  and a positive value is a relative duration. A native caller blocks
   --  through ordinary GNARL protected-entry machinery; a lightweight caller
   --  suspends only its fiber. The operation is abortable, performs no
   --  polling, and must not be called from an Ada protected action. The caller
   --  must keep T's task object alive throughout the call. A task whose
   --  activation failed never publishes, so waiting on it returns
   --  Not_Terminal at the timeout and an indefinite wait would not return;
   --  supply a bounded Timeout when a task may have failed activation. Every
   --  runtime-level wait failure, including reclamation of T while this call
   --  is waiting, is reported as Program_Error rather than propagating a
   --  runtime exception.
   --  @param T Task whose terminal result is awaited
   --  @param Timeout Maximum relative wait; negative means indefinitely
   --  @return Terminal with a copied result, or Not_Terminal on timeout
   --  @exception Program_Error T is null, lacks Flyology-owned result
   --  storage, or the runtime wait failed
   function Wait (T : Ada.Task_Identification.Task_Id; Timeout : Duration := -1.0) return Task_Observation;

   --  Limited exact-task observation handle. Attach retains only the fixed
   --  task-result sidecar; it neither retains the Ada task object nor follows
   --  another task that later occupies related application state. Finalization
   --  detaches automatically and never affects the observed task.
   type Monitor is tagged limited private;

   --  Attach Item to the exact task represented by T. The caller must keep
   --  T's task object alive for this call and obey Task_Id lifetime rules.
   --  After Attach returns, the task object may be reclaimed while Item keeps
   --  the copied terminal result and completion gate alive. A task that
   --  already published its result is immediately observable. A created task
   --  that never began its body still never publishes. The operation performs
   --  no allocation and invokes no user callback.
   --  @param Item Detached monitor to attach
   --  @param T Exact Ada task identity to observe
   --  @exception Program_Error Item is already attached, T is null, or T has
   --     no Flyology-owned task-result storage
   procedure Attach (Item : in out Monitor; T : Ada.Task_Identification.Task_Id);

   --  Report whether Item currently retains task-result storage.
   --  @param Item Monitor to inspect
   --  @return True between successful Attach and Detach or finalization
   function Attached (Item : Monitor) return Boolean;

   --  Release Item's observation reference. This is idempotent and does not
   --  cancel, abort, restart, or otherwise signal the observed task. A later
   --  Attach may reuse Item for another exact task.
   --  @param Item Monitor to detach
   procedure Detach (Item : in out Monitor);

   --  Atomically copy Item's terminal result without waiting. Unlike the
   --  Task_Id overload, this remains valid after target task-object
   --  reclamation. The operation performs no allocation or callback.
   --  @param Item Attached monitor
   --  @return Terminal with a copied result, or Not_Terminal
   --  @exception Program_Error Item is detached or the runtime and library
   --     result ABIs differ
   function Observe (Item : Monitor) return Task_Observation;

   --  Wait up to Timeout through Item's retained completion gate. Timeout,
   --  blocking, abortability, lane behavior, and protected-action restrictions
   --  match the Task_Id overload. Detaching or finalizing Item concurrently
   --  with this call is erroneous; structured ownership must keep the monitor
   --  alive for every borrower.
   --  @param Item Attached monitor kept alive throughout the call
   --  @param Timeout Maximum relative wait; negative means indefinitely
   --  @return Terminal with a copied result, or Not_Terminal on timeout
   --  @exception Program_Error Item is detached or the runtime wait failed
   function Wait (Item : Monitor; Timeout : Duration := -1.0) return Task_Observation;

   --  First-class wait for one retained task result. The operation owns a
   --  sidecar reference after initiation, so the target task object and a
   --  source Monitor need not remain alive while the operation is pending.
   type Wait_Operation is new Flyology.Operations.Operation with private;

   --  Start a task-result wait without suspending the owner.
   --  @param Set Completion set that owns the operation slot
   --  @param T Exact task identity, valid throughout this initiating call
   --  @param Timeout Maximum relative wait; negative means indefinitely
   --  @return Started limited task-result operation
   function Wait
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      T       : Ada.Task_Identification.Task_Id;
      Timeout : Duration := -1.0) return Wait_Operation;

   --  Start a task-result wait from an attached retained monitor.
   --  @param Set Completion set that owns the operation slot
   --  @param Item Attached source monitor retained by the new operation
   --  @param Timeout Maximum relative wait; negative means indefinitely
   --  @return Started limited task-result operation
   function Wait
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : Monitor'Class;
      Timeout : Duration := -1.0) return Wait_Operation;

   --  Start or restart a task-id wait in an established operation object.
   --  @param T Exact task identity, valid throughout this initiating call
   --  @param Timeout Maximum relative wait; negative means indefinitely
   --  @param Operation Fresh or consumed task-result operation
   procedure Wait
     (T : Ada.Task_Identification.Task_Id; Timeout : Duration := -1.0; Operation : in out Wait_Operation)
   with
     Pre =>
       not Flyology.Operations.Is_Active (Operation) and then not Flyology.Operations.Is_Terminal (Operation);

   --  Start or restart a retained-monitor wait in an established operation.
   --  @param Item Attached source monitor
   --  @param Timeout Maximum relative wait; negative means indefinitely
   --  @param Operation Fresh or consumed task-result operation
   procedure Wait (Item : Monitor'Class; Timeout : Duration := -1.0; Operation : in out Wait_Operation)
   with
     Pre =>
       not Flyology.Operations.Is_Active (Operation) and then not Flyology.Operations.Is_Terminal (Operation);

   --  Consume one terminal task-result operation. Timeout succeeds with a
   --  Not_Terminal observation; cancellation raises after consuming.
   --  @param Operation Terminal task-result operation
   --  @param Observation Copied terminal result or Not_Terminal on timeout
   --  @exception Program_Error Runtime observation or subscription failed
   --  @exception Operation_Cancelled Operation was cancelled
   procedure Finish (Operation : in out Wait_Operation; Observation : out Task_Observation);

private
   type Monitor is limited new Ada.Finalization.Limited_Controlled with record
      Storage : System.Address := System.Null_Address;
   end record;

   --  @exclude
   --  @param Item Monitor whose retained sidecar reference is released
   overriding
   procedure Finalize (Item : in out Monitor);

   type Subscription_Node is record
      Version           : Interfaces.C.unsigned := 1;
      Next              : System.Address := System.Null_Address;
      Signal_Descriptor : Interfaces.C.int := Interfaces.C.int (-1);
      Attached          : Interfaces.C.int := 0;
   end record
   with Convention => C;

   type Wait_Failure is (No_Failure, Attach_Failure, Subscription_Failure, Observation_Failure);

   type Wait_Operation is new Flyology.Operations.Operation with record
      Target       : Monitor;
      Subscription : aliased Subscription_Node;
      Status       : Observation_Status := Not_Terminal;
      Result       : Task_Result;
      Failure      : Wait_Failure := No_Failure;
   end record;

   --  @exclude
   --  @param Item Task-result operation to advance
   --  @param Event Driver event to process
   overriding
   procedure Drive (Item : in out Wait_Operation; Event : Flyology.Operations.Driver_Event);

   --  @exclude
   --  @param Item Task-result operation to cancel
   overriding
   procedure Request_Cancellation (Item : in out Wait_Operation);

end Flyology.Task_Results;
