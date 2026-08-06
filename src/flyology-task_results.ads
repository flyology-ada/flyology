with Ada.Task_Identification;

package Flyology.Task_Results with Preelaborate is

   --  Provides fixed task-owned records of Ada task termination. The
   --  facility observes task exit only; it does not catch, resume, restart,
   --  or otherwise supervise a terminated task.

   --  Maximum retained exception-name bytes.
   Exception_Name_Capacity : constant := 96;
   --  Maximum retained exception-message bytes.
   Exception_Message_Capacity : constant := 128;

   --  Terminal classification copied from GNARL's task wrapper.
   --  @enum Normal_Completion The task body and its master completed normally
   --  @enum Unhandled_Exception An exception escaped the task body
   --  @enum Abnormal_Completion GNARL classified task exit as abnormal
   type Exit_Cause is
     (Normal_Completion,
      Unhandled_Exception,
      Abnormal_Completion);

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
   function Text (Item : Bounded_Exception_Name) return String is
     (Item.Data (1 .. Item.Length));

   --  Return the meaningful exception-message characters.
   --  @param Item Bounded exception message
   --  @return Copied exception message without unused fixed storage
   function Text (Item : Bounded_Exception_Message) return String is
     (Item.Data (1 .. Item.Length));

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
   type Task_Observation
     (Status : Observation_Status := Not_Terminal)
   is record
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
   --  callback.
   --  @param T Task whose terminal state is observed
   --  @return Terminal with a copied result, or Not_Terminal
   --  @exception Program_Error T is null, lacks Flyology-owned result
   --  storage, or the runtime and library result ABIs differ
   function Observe
     (T : Ada.Task_Identification.Task_Id) return Task_Observation;

   --  Wait up to Timeout for T's terminal result and return a copied
   --  observation. A negative timeout waits indefinitely, zero only checks,
   --  and a positive value is a relative duration. A native caller blocks
   --  through ordinary GNARL protected-entry machinery; a lightweight caller
   --  suspends only its fiber. The operation is abortable, performs no
   --  polling, and must not be called from an Ada protected action. The caller
   --  must keep T's task object alive throughout the call.
   --  @param T Task whose terminal result is awaited
   --  @param Timeout Maximum relative wait; negative means indefinitely
   --  @return Terminal with a copied result, or Not_Terminal on timeout
   --  @exception Program_Error T is null, lacks Flyology-owned result
   --  storage, or the runtime wait failed
   function Wait
     (T       : Ada.Task_Identification.Task_Id;
      Timeout : Duration := -1.0) return Task_Observation;

end Flyology.Task_Results;
