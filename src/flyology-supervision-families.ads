with Ada.Finalization;
with Ada.Real_Time;
with Flyology.Execution_Groups;
with Flyology.Wake_Sources;
with Interfaces.C;

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
--  @formal Control_Group Exact shared lightweight group for managers
--  @formal Event_Capacity Maximum retained supervisor events
--  @formal Monitor_Capacity Maximum concurrent exact-generation waiters

generic
   type Request is private;
   type Application_Context (<>) is limited private;

   with
     procedure Run_One_Generation
       (Context : aliased in out Application_Context;
        Input   : Request;
        Control : aliased in out Generation_Control;
        Result  : out Generation_Result);

   Policy : Child_Specification;
   First_Child_Id : Child_Id;
   Maximum_Children : Positive;
   Control_Group : Flyology.Execution_Groups.Group_Selecting_CPU := 127;
   Event_Capacity : Positive := 256;
   Monitor_Capacity : Positive := 64;

package Flyology.Supervision.Families
is

   --  Raised before admission opens when the common policy, id range, or
   --  control-plane placement is invalid.
   Configuration_Error : exception;

   --  Raised when a generation-qualified handle no longer names its slot's
   --  current generation.
   Stale_Handle : exception;

   --  One-shot family owner. Run is the Ada master boundary; admitted manager
   --  and generation tasks cannot outlive it. Admissions, copied requests,
   --  handles, recovery state, and events belong to this family incarnation.
   --  Reconstructing an owner creates an empty family with new controller
   --  authority; desired requests that must persist belong outside the family
   --  and must be reconciled and admitted again.
   type Family is limited private;

   --  Validate and run until explicit shutdown or terminal policy escalation.
   --  Start, Stop, Current, and Request_Shutdown may be called concurrently.
   --  A shutdown requested before Run is sticky and keeps admission closed.
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

   --  Run a family under Parent's exact recovery incident. A stop request on
   --  Parent closes admission and begins family shutdown. A terminal family
   --  outcome reports the same incident through Parent rather than minting a
   --  second hierarchical attempt. Restarting Parent creates a new one-shot
   --  family; this operation does not replay admissions or preserve handles.
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
      Parent  : aliased in out Generation_Control;
      Result  : out Supervisor_Result);

   --  Copy Input into a reserved slot and publish admission only after the
   --  copy succeeds. Copy or finalization work is never performed while the
   --  family lock is held. Admission records current controller state rather
   --  than persistent application intent and is not replayed into another
   --  Family object.
   --  @param Item Running family with open admission
   --  @param Input Typed generation input copied into family-owned storage
   --  @param Handle Exact logical child and first generation
   --  @exception Program_Error Family is not running or is shutting down
   --  @exception Constraint_Error Every fixed slot is occupied
   procedure Start (Item : in out Family; Input : Request; Handle : out Child_Handle);

   --  Cooperatively stop the exact admitted or live generation. A terminated
   --  generation awaiting replacement backoff cannot stop its replacement.
   --  @param Item Running family
   --  @param Handle Exact generation to stop
   --  @exception Stale_Handle Handle does not identify an admitted/live task
   procedure Stop (Item : in out Family; Handle : Child_Handle);

   --  Request bounded replacement of the exact running family generation.
   --  The common policy must be restart safe, locally recoverable, and not
   --  Never. Recovery budgets and backoff apply exactly as they do to
   --  automatic recovery.
   --  @param Item Running family
   --  @param Handle Exact current generation
   --  @exception Stale_Handle Handle is foreign, stale, or not running
   --  @exception Program_Error The family policy does not permit local
   --     replacement
   procedure Restart (Item : in out Family; Handle : Child_Handle);

   --  Reject the exact running generation after a failed external health
   --  probe. Diagnostic is copied before entering controller state.
   --  @param Item Running family
   --  @param Handle Exact current generation
   --  @param Diagnostic Bounded application health diagnostic
   --  @exception Stale_Handle Handle is foreign, stale, or not running
   procedure Report_Unhealthy (Item : in out Family; Handle : Child_Handle; Diagnostic : String);

   --  Close admission and cooperatively stop every occupied slot. A request
   --  made before Run is retained through configuration. The call is
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
   function Current (Item : Family; Handle : Child_Handle) return Child_Snapshot;

   --  Observe the latest generation for one stable logical child id. This
   --  overload is read-only and does not authorize a generation operation.
   --  @param Item Family to inspect
   --  @param Child Logical child id within this family
   --  @return Latest fixed snapshot for the occupied slot
   --  @exception Stale_Handle Child is outside the family or currently free
   function Current (Item : Family; Child : Child_Id) return Child_Snapshot;

   --  Sample a generation-qualified handle for one occupied logical child.
   --  A concurrent restart may make the returned handle stale before use.
   --  @param Item Family to inspect
   --  @param Child Logical child id within this family
   --  @return Latest exact generation handle
   --  @exception Stale_Handle Child is outside the family or currently free
   function Latest (Item : Family; Child : Child_Id) return Child_Handle;

   --  Wait for Handle's exact generation to terminate or be replaced. The
   --  registration and current-generation check are atomic with respect to
   --  family lifecycle changes, so a rapid restart cannot be lost. A negative
   --  timeout waits indefinitely, zero only checks, and a positive value is
   --  relative. The call is abortable, must not be made from a protected
   --  action, and neither stops the child nor follows its replacement. Item
   --  must outlive the call.
   --  @param Item Family that issued Handle
   --  @param Handle Exact admitted generation to observe
   --  @param Timeout Maximum relative wait; negative means indefinitely
   --  @return Terminal, replaced, or timed-out fixed observation
   --  @exception Stale_Handle Handle is outside this family or predates any
   --     generation retained in its slot
   --  @exception Constraint_Error Monitor_Capacity waiters are already active
   function Wait_Termination
     (Item : in out Family; Handle : Child_Handle; Timeout : Duration := -1.0) return Generation_Observation;

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
   type Termination_Array is array (Slot_Index) of Termination_Summary;
   type Time_Array is array (Slot_Index) of Ada.Real_Time.Time;
   type Incident_Id_Array is array (Slot_Index) of Incident_Id;
   type Incident_Attempt_Array is array (Slot_Index) of Incident_Attempt;
   type Incident_Context_Array is array (Slot_Index) of Incident_Context;
   type Event_Buffer is array (Positive range 1 .. Event_Capacity) of Supervisor_Event;
   subtype Monitor_Index is Positive range 1 .. Monitor_Capacity;
   subtype Monitor_Token is Interfaces.Unsigned_64;
   type Monitor_State is
     (Monitor_Free,
      Monitor_Prepared_Reserved,
      Monitor_Prepared_Dormant,
      Monitor_Pending,
      Monitor_Termination_Signal_Pending,
      Monitor_Replacement_Signal_Pending,
      Monitor_Termination_Signal_Claimed,
      Monitor_Replacement_Signal_Claimed,
      Monitor_Immediate_Replaced_Claimed,
      Monitor_Immediate_Terminal_As_Replacement_Claimed,
      Monitor_Immediate_Terminated_Claimed,
      Monitor_Terminated,
      Monitor_Replaced,
      Monitor_Prepared_Ended);
   type Monitor_Kind is
     (Monitor_Ordinary,
      Monitor_Admission_Transient,
      Monitor_Admission_Prepared);
   type Deferred_Monitor_Fact is
     (No_Deferred_Monitor_Fact,
      Deferred_Monitor_Replaced,
      Deferred_Monitor_Terminated);
   type Monitor_Kind_Array is array (Monitor_Index) of Monitor_Kind;
   type Prepared_Monitor_Reserve_Status is
     (Prepared_Monitor_Reserved,
      Prepared_Monitor_Admission_Closed,
      Prepared_Monitor_Capacity_Exhausted,
      Prepared_Monitor_Identity_Exhausted);
   type Monitor_State_Array is array (Monitor_Index) of Monitor_State;
   type Monitor_Token_Array is array (Monitor_Index) of Monitor_Token;
   type Monitor_Handle_Array is array (Monitor_Index) of Child_Handle;
   type Monitor_Snapshot_Array is array (Monitor_Index) of Child_Snapshot;
   type Deferred_Monitor_Fact_Array is array (Monitor_Index) of Deferred_Monitor_Fact;
   type Monitor_Signal_Guard (Owner : not null access Family) is new Ada.Finalization.Limited_Controlled
   with record
      Ticket     : aliased Monitor_Index := Monitor_Index'First;
      Token      : aliased Monitor_Token := 0;
      Descriptor : aliased Interfaces.C.int := Interfaces.C.int (-1);
      Claimed    : aliased Boolean := False;
      Armed      : aliased Boolean := False;
   end record;

   --  @exclude
   --  @param Item Claimed monitor signal publication to drain
   procedure Flush_Monitor_Signals (Item : in out Monitor_Signal_Guard);
   --  @exclude
   --  @param Item Claimed monitor signal publication finalized on unwinding
   overriding
   procedure Finalize (Item : in out Monitor_Signal_Guard);

   --  Prepared-admission states share the existing fixed slot array.  The
   --  additional literals do not add a second capacity or side allocation.
   type Slot_State is
     (Free,
      Reserved,
      Preparing,
      Prepared,
      Committed_Blocked,
      Queued,
      Released_Queued,
      Managed,
      Released_Managed,
      Reapable,
      Released_Reapable);
   for Slot_State'Size use 8;
   type Slot_State_Array is array (Slot_Index) of Slot_State;

   type Prepared_Reserve_Status is
     (Prepared_Reserved,
      Prepared_Admission_Closed,
      Prepared_Capacity_Exhausted,
      Prepared_Generation_Exhausted);
   type Prepared_Commit_Status is (Prepared_Committed, Prepared_Commit_Closed);
   protected type Family_State is
      procedure Configure (Identity : Controller_Id; Inherited : Incident_Context);
      procedure Reserve (Slot : out Slot_Index; Handle : out Child_Handle);
      procedure Commit (Slot : Slot_Index; Handle : Child_Handle);
      procedure Rollback (Slot : Slot_Index; Handle : Child_Handle);
      procedure Reserve_Prepared
        (Slot   : not null access Slot_Index;
         Handle : not null access Child_Handle;
         Active : not null access Boolean;
         Status : out Prepared_Reserve_Status);
      procedure Publish_Prepared (Slot : Slot_Index; Handle : Child_Handle);
      procedure Rollback_Prepared
        (Slot : Slot_Index; Handle : Child_Handle; Active : not null access Boolean);
      procedure Commit_Prepared
        (Slot             : Slot_Index;
         Handle           : Child_Handle;
         Claim_Active     : not null access Boolean;
         Admission_Slot   : not null access Slot_Index;
         Admission_Handle : not null access Child_Handle;
         Admission_Active : not null access Boolean;
         Status           : out Prepared_Commit_Status);
      procedure Release_Prepared
        (Slot      : Slot_Index;
         Handle    : Child_Handle;
         Released  : not null access Boolean;
         Succeeded : not null access Boolean;
         Completed : not null access Boolean);
      procedure Begin_Admission_Cancel
        (Slot      : Slot_Index;
         Handle    : Child_Handle;
         Active    : not null access Boolean;
         Released  : not null access Boolean;
         Signals   : not null access Monitor_Signal_Guard;
         Completed : out Boolean);
      entry Await_Admission_Cancel (Slot_Index)
        (Handle : Child_Handle; Active : not null access Boolean; Released : not null access Boolean);
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
         Shutdown : out Boolean;
         Override : out Termination_Summary);
      procedure Request_Intervention
        (Handle : Child_Handle; Termination : Termination_Summary; Valid : out Boolean);
      procedure Publish_Starting
        (Slot     : Slot_Index;
         Handle   : Child_Handle;
         Incident : Incident_Context;
         Signals  : not null access Monitor_Signal_Guard;
         Accepted : out Boolean);
      function Replacement_Wait_Allowed (Slot : Slot_Index) return Boolean;
      procedure Publish_Ready (Slot : Slot_Index; Handle : Child_Handle; Now : Ada.Real_Time.Time);
      procedure Publish_Stuck (Slot : Slot_Index; Handle : Child_Handle);
      procedure Publish_Termination
        (Slot        : Slot_Index;
         Handle      : Child_Handle;
         Termination : Termination_Summary;
         Incident    : Incident_Context;
         Now         : Ada.Real_Time.Time;
         Restart     : out Boolean;
         Backoff     : out Ada.Real_Time.Time_Span;
         Next        : out Child_Handle;
         Recovery    : out Incident_Context;
         Signals     : not null access Monitor_Signal_Guard);
      function Incident_Can_Close
        (Slot : Slot_Index; Handle : Child_Handle; Now : Ada.Real_Time.Time) return Boolean;
      procedure Manager_Done
        (Slot : Slot_Index; Handle : Child_Handle; Signals : not null access Monitor_Signal_Guard);
      procedure Manager_Failed
        (Slot        : Slot_Index;
         Handle      : Child_Handle;
         Termination : Termination_Summary;
         Signals     : not null access Monitor_Signal_Guard);
      procedure Request_Stop;
      function Is_Finished return Boolean;
      function Admission_Is_Open return Boolean;
      function Read_Result return Supervisor_Result;
      function Read_Snapshot (Handle : Child_Handle; Valid : out Boolean) return Child_Snapshot;
      function Read_Logical_Snapshot (Child : Child_Id; Valid : out Boolean) return Child_Snapshot;
      function Read_Latest (Child : Child_Id; Valid : out Boolean) return Child_Handle;
      procedure Register_Monitor
        (Handle    : Child_Handle;
         Immediate : out Boolean;
         Status    : out Generation_Observation_Status;
         Snapshot  : out Child_Snapshot;
         Ticket    : not null access Monitor_Index;
         Token     : not null access Monitor_Token;
         Active    : not null access Boolean;
         Valid     : out Boolean);
      procedure Register_Admission_Monitor
        (Admission : Child_Handle;
         Observed  : Child_Handle;
         Signal    : Interfaces.C.int;
         Immediate : out Boolean;
         Status    : out Generation_Observation_Status;
         Snapshot  : out Child_Snapshot;
         Ticket    : not null access Monitor_Index;
         Token     : not null access Monitor_Token;
         Active    : not null access Boolean;
         Valid     : out Boolean);
      procedure Reserve_Prepared_Admission_Monitor
        (Admission : Child_Handle;
         Ticket    : not null access Monitor_Index;
         Token     : not null access Monitor_Token;
         Active    : not null access Boolean;
         Status    : out Prepared_Monitor_Reserve_Status);
      procedure Activate_Prepared_Admission_Monitor
        (Admission : Child_Handle;
         Ticket    : Monitor_Index;
         Token     : Monitor_Token;
         Observed  : Child_Handle;
         Signal    : Interfaces.C.int;
         Immediate : out Boolean;
         Status    : out Generation_Observation_Status;
         Snapshot  : out Child_Snapshot;
         Active    : not null access Boolean;
         Immediate_Claimed : not null access Boolean;
         Valid     : out Boolean);
      procedure Resolve_Prepared_Immediate_Claim
        (Ticket   : Monitor_Index;
         Token    : Monitor_Token;
         Commit   : Boolean;
         Active   : not null access Boolean;
         Resolved : out Boolean);
      procedure Commit_Prepared_Current_Fact
        (Ticket           : Monitor_Index;
         Status           : Generation_Observation_Status;
         Primary_Terminal : Boolean);
      procedure Restore_Prepared_Prior_Fact
        (Ticket           : Monitor_Index;
         Retain_Current   : Boolean;
         Current_Terminal : Boolean;
         Current_Snapshot : Child_Snapshot);
      procedure Take_Prepared_Monitor
        (Ticket    : Monitor_Index;
         Token     : Monitor_Token;
         Preserve_Fact : Boolean;
         Released  : out Boolean;
         Completed : out Boolean;
         Status    : out Generation_Observation_Status;
         Snapshot  : out Child_Snapshot);
      entry Await_Prepared_Monitor (Monitor_Index)
        (Token         : Monitor_Token;
         Preserve_Fact : Boolean;
         Status        : out Generation_Observation_Status;
         Snapshot      : out Child_Snapshot);
      procedure Release_Prepared_Monitor
        (Ticket    : Monitor_Index;
         Token     : Monitor_Token;
         Active    : not null access Boolean;
         Released  : out Boolean);
      entry Await_Prepared_Monitor_Release (Monitor_Index)
        (Token : Monitor_Token; Active : not null access Boolean);
      procedure Claim_Monitor_Signal (Signals : not null access Monitor_Signal_Guard);
      procedure Try_Acknowledge_Monitor_Signal
        (Signals : not null access Monitor_Signal_Guard;
         Result  : out Flyology.Wake_Sources.Signal_Attempt_Result);
      entry Await_Monitor (Monitor_Index)
        (Token : Monitor_Token; Status : out Generation_Observation_Status; Snapshot : out Child_Snapshot);
      procedure Cancel_Monitor
        (Ticket    : Monitor_Index;
         Token     : Monitor_Token;
         Released  : out Boolean;
         Completed : out Boolean;
         Status    : out Generation_Observation_Status;
         Snapshot  : out Child_Snapshot);
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
         Backoff     : Ada.Real_Time.Time_Span := Ada.Real_Time.Time_Span_Zero);
      procedure Complete_Monitors
        (Slot    : Slot_Index;
         Status  : Generation_Observation_Status;
         Signals : not null access Monitor_Signal_Guard);
      Configured               : Boolean := False;
      Identity                 : Controller_Id := Controller_Id'First;
      Run_Used                 : Boolean := False;
      Shutdown                 : Boolean := False;
      Terminal                 : Boolean := False;
      Slots                    : Slot_State_Array := (others => Free);
      Snapshots                : Snapshot_Array;
      Has_Generation           : Boolean_Array := (others => False);
      Stop_Requested           : Boolean_Array := (others => False);
      Recovery_Requested       : Boolean_Array := (others => False);
      Intervention             : Termination_Array;
      Queue                    : Slot_Order := (others => Slot_Index'First);
      Queue_Head               : Slot_Index := Slot_Index'First;
      Queue_Tail               : Slot_Index := Slot_Index'First;
      Queue_Length             : Natural := 0;
      Reserved_Children        : Natural := 0;
      Live_Managers            : Natural := 0;
      Total_Used               : Natural_Array := (others => 0);
      Window_Used              : Natural_Array := (others => 0);
      Consecutive              : Natural_Array := (others => 0);
      Incident_Since           : Time_Array := (others => Ada.Real_Time.Time_First);
      Window_Since             : Time_Array := (others => Ada.Real_Time.Time_First);
      Ready_Since              : Time_Array := (others => Ada.Real_Time.Time_First);
      Last_Incident            : Incident_Id_Array := (others => Incident_Id'First);
      Last_Attempt             : Incident_Attempt_Array := (others => Incident_Attempt'First);
      Has_Incident             : Boolean_Array := (others => False);
      Active_Incidents         : Incident_Context_Array := (others => No_Incident);
      Inherited_Incident       : Incident_Context := No_Incident;
      Events                   : Event_Buffer;
      Event_First              : Positive := Event_Buffer'First;
      Event_Length             : Natural := 0;
      Event_Last_Sequence      : Event_Sequence := 0;
      Event_Sequence_Exhausted : Boolean := False;
      Monitor_States           : Monitor_State_Array := (others => Monitor_Free);
      Monitor_Kinds            : Monitor_Kind_Array := (others => Monitor_Ordinary);
      Monitor_Tokens           : Monitor_Token_Array := (others => 0);
      Monitor_Handles          : Monitor_Handle_Array;
      Monitor_Admissions       : Monitor_Handle_Array;
      Monitor_Snapshots        : Monitor_Snapshot_Array;
      Monitor_Deferred_Facts   : Deferred_Monitor_Fact_Array := (others => No_Deferred_Monitor_Fact);
      Monitor_Deferred_Snapshots : Monitor_Snapshot_Array;
      Monitor_Prior_Facts      : Deferred_Monitor_Fact_Array := (others => No_Deferred_Monitor_Fact);
      Monitor_Prior_Handles    : Monitor_Handle_Array;
      Monitor_Prior_Snapshots  : Monitor_Snapshot_Array;
      Result                   : Supervisor_Result;
   end Family_State;

   type Family_State_Access is access all Family_State;
   type Monitor_Guard is limited new Ada.Finalization.Limited_Controlled with record
      State  : Family_State_Access := null;
      Ticket : aliased Monitor_Index := Monitor_Index'First;
      Token  : aliased Monitor_Token := 0;
      Active : aliased Boolean := False;
   end record;

   --  @exclude
   --  @param Item In-flight family monitor registration canceled on unwinding
   overriding
   procedure Finalize (Item : in out Monitor_Guard);

   type Family is limited record
      State  : aliased Family_State;
      Inputs : Request_Array;
   end record;

end Flyology.Supervision.Families;
