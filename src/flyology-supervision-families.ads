with Ada.Real_Time;
with System.Multiprocessors;

--  Runs a bounded homogeneous dynamic child family as one synchronous Ada
--  scope. Storage is linear in Maximum_Children, no dependency matrix is
--  allocated, and at most one manager is allocated lazily for each slot that
--  is used. Allocated managers remain dependent on the Run scope for reuse
--  and their storage is reclaimed after they terminate at the join boundary.
--  @formal Request Typed input copied before admission is published
--  @formal Application_Context Shared family state
--  @formal Run_One_Generation Typed synchronous generation factory, normally
--  an instance of Supervision.Input_Task_Generations.Run
--  @formal Policy Common restart, stop, readiness, and task-model policy
--  @formal First_Child_Id First logical id in the family's contiguous range
--  @formal Maximum_Children Fixed slot and admission capacity
--  @formal Control_Group Shared lightweight execution group for managers
--  @formal Event_Capacity Maximum retained supervisor events
generic
   type Request is private;
   type Application_Context (<>) is limited private;

   with procedure Run_One_Generation
     (Context : aliased in out Application_Context;
      Input   : Request;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result);

   Policy           : Child_Specification;
   First_Child_Id   : Child_Id;
   Maximum_Children : Positive;
   Control_Group    : System.Multiprocessors.CPU_Range := 127;
   Event_Capacity   : Positive := 256;

package Flyology.Supervision.Families is

   --  Raised before admission opens when the common policy, id range, or
   --  control-plane placement is invalid.
   Configuration_Error : exception;

   --  Raised when a generation-qualified handle no longer names its slot's
   --  current generation.
   Stale_Handle : exception;

   --  One-shot family owner. Run is the Ada master boundary; admitted manager
   --  and generation tasks cannot outlive it.
   type Family is limited private;

   --  Validate and run until explicit shutdown or terminal policy escalation.
   --  Start, Stop, Current, and Request_Shutdown may be called concurrently.
   --  @param Item One-shot family owner
   --  @param Context Application state retained by every live generation
   --  @param Result Terminal result after every terminable child joins
   --  @exception Configuration_Error Family configuration is invalid
   --  @exception Program_Error Item was already run
   --  @exception Tasking_Error A manager task could not activate
   procedure Run
     (Item    : aliased in out Family;
      Context : aliased in out Application_Context;
      Result  : out Supervisor_Result);

   --  Run a family under Parent's exact recovery incident. A terminal family
   --  outcome reports the same incident through Parent rather than minting a
   --  second hierarchical attempt.
   --  @param Item One-shot nested family owner
   --  @param Context Application state retained by every live generation
   --  @param Parent Owning generation control and incident propagation path
   --  @param Result Terminal result after every terminable child joins
   --  @exception Configuration_Error Family configuration is invalid
   --  @exception Program_Error Item was already run or Parent is inactive
   --  @exception Tasking_Error A manager task could not activate
   procedure Run_Nested
     (Item    : aliased in out Family;
      Context : aliased in out Application_Context;
      Parent  : in out Generation_Control;
      Result  : out Supervisor_Result);

   --  Copy Input into a reserved slot and publish admission only after the
   --  copy succeeds. Copy or finalization work is never performed while the
   --  family lock is held.
   --  @param Item Running family with open admission
   --  @param Input Typed generation input copied into family-owned storage
   --  @param Handle Exact logical child and first generation
   --  @exception Program_Error Family is not running or is shutting down
   --  @exception Constraint_Error Every fixed slot is occupied
   procedure Start
     (Item   : in out Family;
      Input  : Request;
      Handle : out Child_Handle);

   --  Cooperatively stop the exact generation. A stale handle cannot stop a
   --  replacement that reused the same slot.
   --  @param Item Running family
   --  @param Handle Exact generation to stop
   --  @exception Stale_Handle Handle no longer identifies the slot
   procedure Stop
     (Item   : in out Family;
      Handle : Child_Handle);

   --  Close admission and cooperatively stop every occupied slot. The call is
   --  nonblocking; Run remains the join boundary.
   --  @param Item Family to shut down
   procedure Request_Shutdown (Item : in out Family);

   --  Report whether Run validated the family and admission remains open.
   --  @param Item Family to inspect
   --  @return True when Start may reserve a slot
   function Accepting (Item : Family) return Boolean;

   --  Copy the current snapshot for an exact generation-qualified handle.
   --  @param Item Family to inspect
   --  @param Handle Exact logical child and generation
   --  @return Fixed current snapshot
   --  @exception Stale_Handle Handle no longer identifies the slot
   function Current
     (Item   : Family;
      Handle : Child_Handle) return Child_Snapshot;

   --  Observe the latest generation for one stable logical child id. This
   --  overload is read-only and does not authorize a generation operation.
   --  @param Item Family to inspect
   --  @param Child Logical child id within this family
   --  @return Latest fixed snapshot for the occupied slot
   --  @exception Stale_Handle Child is outside the family or currently free
   function Current
     (Item  : Family;
      Child : Child_Id) return Child_Snapshot;

   --  Sample a generation-qualified handle for one occupied logical child.
   --  A concurrent restart may make the returned handle stale before use.
   --  @param Item Family to inspect
   --  @param Child Logical child id within this family
   --  @return Latest exact generation handle
   --  @exception Stale_Handle Child is outside the family or currently free
   function Latest
     (Item  : Family;
      Child : Child_Id) return Child_Handle;

   --  Copy events after Cursor in ascending sequence order. Cursor advances
   --  to the last copied event, and Dropped reports an overwritten sequence
   --  gap. No formatting or callback occurs under the family lock.
   --  @param Item Family to inspect
   --  @param Cursor Last sequence already consumed, or zero initially
   --  @param Events Caller-owned fixed destination
   --  @param Count Number of initialized leading elements in Events
   --  @param Dropped Number of unavailable events before the copied range
   procedure Read_Events
     (Item    : in out Family;
      Cursor  : in out Event_Sequence;
      Events  : out Supervisor_Event_Array;
      Count   : out Natural;
      Dropped : out Event_Sequence);

private
   subtype Slot_Index is Positive range 1 .. Maximum_Children;
   type Request_Array is array (Slot_Index) of Request;
   type Snapshot_Array is array (Slot_Index) of Child_Snapshot;
   type Boolean_Array is array (Slot_Index) of Boolean;
   type Slot_Order is array (Slot_Index) of Slot_Index;
   type Natural_Array is array (Slot_Index) of Natural;
   type Time_Array is array (Slot_Index) of Ada.Real_Time.Time;
   type Incident_Id_Array is array (Slot_Index) of Incident_Id;
   type Incident_Attempt_Array is array (Slot_Index) of Incident_Attempt;
   type Incident_Context_Array is array (Slot_Index) of Incident_Context;
   type Event_Buffer is array (Positive range 1 .. Event_Capacity) of
     Supervisor_Event;

   type Slot_State is (Free, Reserved, Queued, Managed, Reapable);
   type Slot_State_Array is array (Slot_Index) of Slot_State;

   protected type Family_State is
      procedure Configure (Inherited : Incident_Context);
      procedure Reserve
        (Slot   : out Slot_Index;
         Handle : out Child_Handle);
      procedure Commit (Slot : Slot_Index; Handle : Child_Handle);
      procedure Rollback (Slot : Slot_Index; Handle : Child_Handle);
      procedure Take_Start
        (Available : out Boolean;
         Slot      : out Slot_Index;
         Handle    : out Child_Handle;
         Incident  : out Incident_Context);
      procedure Stop_One (Handle : Child_Handle; Valid : out Boolean);
      procedure Stop_Status
        (Slot     : Slot_Index;
         Handle   : Child_Handle;
         Stop     : out Boolean;
         Shutdown : out Boolean);
      procedure Publish_Starting
        (Slot   : Slot_Index;
         Handle : Child_Handle;
         Incident : Incident_Context);
      procedure Publish_Ready
        (Slot   : Slot_Index;
         Handle : Child_Handle;
         Now    : Ada.Real_Time.Time);
      procedure Publish_Stuck
        (Slot   : Slot_Index;
         Handle : Child_Handle);
      procedure Publish_Termination
        (Slot        : Slot_Index;
         Handle      : Child_Handle;
         Termination : Termination_Summary;
         Incident    : Incident_Context;
         Now         : Ada.Real_Time.Time;
         Restart     : out Boolean;
         Backoff     : out Ada.Real_Time.Time_Span;
         Next        : out Child_Handle;
         Recovery    : out Incident_Context);
      function Incident_Can_Close
        (Slot   : Slot_Index;
         Handle : Child_Handle;
         Now    : Ada.Real_Time.Time) return Boolean;
      procedure Manager_Done (Slot : Slot_Index; Handle : Child_Handle);
      procedure Manager_Failed
        (Slot        : Slot_Index;
         Handle      : Child_Handle;
         Termination : Termination_Summary);
      procedure Request_Stop;
      function Is_Finished return Boolean;
      function Admission_Is_Open return Boolean;
      function Read_Result return Supervisor_Result;
      function Read_Snapshot
        (Handle : Child_Handle;
         Valid  : out Boolean) return Child_Snapshot;
      function Read_Logical_Snapshot
        (Child : Child_Id;
         Valid : out Boolean) return Child_Snapshot;
      function Read_Latest
        (Child : Child_Id;
         Valid : out Boolean) return Child_Handle;
      procedure Copy_Events
        (Cursor  : in out Event_Sequence;
         Target  : out Supervisor_Event_Array;
         Count   : out Natural;
         Dropped : out Event_Sequence);
   private
      procedure Begin_Terminal
        (Outcome     : Supervisor_Outcome;
         Slot        : Slot_Index;
         Termination : Termination_Summary;
         Incident    : Incident_Context);
      procedure Record_Event
        (Slot        : Slot_Index;
         Kind        : Event_Kind;
         Before      : Child_State;
         After       : Child_State;
         Now         : Ada.Real_Time.Time;
         Termination : Termination_Kind := No_Termination;
         Incident    : Incident_Context := No_Incident;
         Backoff     : Ada.Real_Time.Time_Span :=
           Ada.Real_Time.Time_Span_Zero);
      Configured : Boolean := False;
      Run_Used   : Boolean := False;
      Admission_Open : Boolean := False;
      Shutdown  : Boolean := False;
      Terminal  : Boolean := False;
      Slots     : Slot_State_Array := (others => Free);
      Snapshots : Snapshot_Array;
      Has_Generation : Boolean_Array := (others => False);
      Stop_Requested : Boolean_Array := (others => False);
      Queue     : Slot_Order := (others => Slot_Index'First);
      Queue_Head : Slot_Index := Slot_Index'First;
      Queue_Tail : Slot_Index := Slot_Index'First;
      Queue_Length : Natural := 0;
      Reserved_Children : Natural := 0;
      Live_Managers : Natural := 0;
      Total_Used : Natural_Array := (others => 0);
      Window_Used : Natural_Array := (others => 0);
      Consecutive : Natural_Array := (others => 0);
      Incident_Since : Time_Array :=
        (others => Ada.Real_Time.Time_First);
      Window_Since : Time_Array :=
        (others => Ada.Real_Time.Time_First);
      Ready_Since : Time_Array :=
        (others => Ada.Real_Time.Time_First);
      Last_Incident : Incident_Id_Array :=
        (others => Incident_Id'First);
      Last_Attempt : Incident_Attempt_Array :=
        (others => Incident_Attempt'First);
      Has_Incident : Boolean_Array := (others => False);
      Active_Incidents : Incident_Context_Array := (others => No_Incident);
      Inherited_Incident : Incident_Context := No_Incident;
      Events : Event_Buffer;
      Event_First : Positive := Event_Buffer'First;
      Event_Length : Natural := 0;
      Event_Last_Sequence : Event_Sequence := 0;
      Event_Sequence_Exhausted : Boolean := False;
      Result : Supervisor_Result;
   end Family_State;

   type Family is limited record
      State  : Family_State;
      Inputs : Request_Array;
   end record;

end Flyology.Supervision.Families;
