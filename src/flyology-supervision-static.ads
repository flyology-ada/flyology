with Ada.Real_Time;
with System.Multiprocessors;

--  Runs a typed, fixed static topology as a synchronous structured scope.
--  Recovery is coordinated as one stop, join, backoff, start, and readiness
--  transaction over an isolated child, a named cohort, or declared dependent
--  closure. Nested calls retain one incident and attempt identity.
--  @formal Child_Kind Application enumeration of static children
--  @formal Application_Context Shared topology state
--  @formal Logical_Id Stable nonzero public identity for each child
--  @formal Specification Static policy for each child
--  @formal Depends_On Declared startup dependency relation
--  @formal Cohort_Member Named directed recovery membership
--  @formal Run_One_Generation Typed synchronous generation factory
--  @formal Control_Group Shared lightweight execution group for managers
--  @formal Subtree_Recovery Recovery limits shared by the complete node
--  @formal Event_Capacity Maximum retained supervisor events
generic
   type Child_Kind is (<>);
   type Application_Context (<>) is limited private;

   with function Logical_Id (Child : Child_Kind) return Child_Id;
   with function Specification
     (Child : Child_Kind) return Child_Specification;
   with function Depends_On
     (Child        : Child_Kind;
      Prerequisite : Child_Kind) return Boolean;
   with function Cohort_Member
     (Trigger : Child_Kind;
      Member  : Child_Kind) return Boolean;

   --  Construct and join exactly one new Ada task generation. Applications
   --  normally dispatch to an instance of Flyology.Supervision.Children.
   --  The operation must not return while its generation task or resources
   --  remain live.
   --  @param Context Application state owned by the enclosing Run call
   --  @param Child Logical static child kind
   --  @param Control Fresh generation readiness and cancellation channel
   --  @param Result Terminal value available only after the generation joins
   with procedure Run_One_Generation
     (Context : aliased in out Application_Context;
      Child   : Child_Kind;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result);

   Control_Group : System.Multiprocessors.CPU_Range := 127;
   Subtree_Recovery : Recovery_Limits := Default_Recovery_Limits;
   Event_Capacity : Positive := 256;

package Flyology.Supervision.Static is

   --  Raised before task creation when ids, policies, dependencies, cohorts,
   --  recovery limits, or control-plane placement are invalid.
   Configuration_Error : exception;

   --  One-shot static supervisor. Run is the ownership boundary and must be
   --  called from one task. Current and Request_Shutdown may be called safely
   --  by other tasks while Run is active. Storage is fixed by Child_Kind; no
   --  per-restart allocation is performed by the controller.
   type Supervisor is limited private;

   --  Validate configuration, create bounded lightweight manager tasks, and
   --  run until explicit shutdown or a terminal child outcome. The call
   --  returns only after every terminable child generation and manager joins.
   --  A stuck child remains observable and necessarily prevents return.
   --  @param Item One-shot supervisor object kept alive for the complete call
   --  @param Context Application state kept alive for every generation
   --  @param Result Typed terminal result
   --  @exception Configuration_Error Static configuration is invalid
   --  @exception Program_Error Run was already called
   --  @exception Tasking_Error A manager task could not activate
   procedure Run
     (Item    : aliased in out Supervisor;
      Context : aliased in out Application_Context;
      Result  : out Supervisor_Result);

   --  Run a nested supervisor under Parent's exact recovery incident. If the
   --  nested node escalates, the same incident is reported through Parent so
   --  the owning node does not mint or count another attempt.
   --  @param Item One-shot nested supervisor object
   --  @param Context Application state kept alive for every generation
   --  @param Parent Owning generation control and incident propagation path
   --  @param Result Typed terminal result
   --  @exception Configuration_Error Static configuration is invalid
   --  @exception Program_Error Item was already run or Parent is inactive
   --  @exception Tasking_Error A manager task could not activate
   procedure Run_Nested
     (Item    : aliased in out Supervisor;
      Context : aliased in out Application_Context;
      Parent  : in out Generation_Control;
      Result  : out Supervisor_Result);

   --  Idempotently begin reverse dependency order shutdown. Each live child
   --  first receives cooperative cancellation, followed by its configured
   --  optional abort request. Deadlines classify progress but do not bound
   --  this call or guarantee termination.
   --  @param Item Supervisor whose Run call should stop
   procedure Request_Shutdown (Item : in out Supervisor);

   --  Sample one logical child. The snapshot contains only fixed copied state
   --  and may describe an immediately adjacent transition. Before Run has
   --  installed its validated configuration, this returns a Configured view
   --  constructed outside the controller lock.
   --  @param Item Supervisor to inspect
   --  @param Child Static child kind
   --  @return Current bounded child snapshot
   function Current
     (Item  : Supervisor;
      Child : Child_Kind) return Child_Snapshot;

   --  Copy events after Cursor in ascending sequence order. Cursor advances to
   --  the last copied event. If older events were overwritten, Dropped is the
   --  exact sequence gap before the first copied event. The caller controls
   --  the destination bound and no callback or logging occurs in the lock.
   --  @param Item Supervisor to inspect
   --  @param Cursor Last sequence already consumed, or zero initially
   --  @param Events Caller-owned fixed destination
   --  @param Count Number of initialized leading elements in Events
   --  @param Dropped Number of unavailable events before the copied range
   procedure Read_Events
     (Item    : in out Supervisor;
      Cursor  : in out Event_Sequence;
      Events  : out Supervisor_Event_Array;
      Count   : out Natural;
      Dropped : out Event_Sequence);

private
   Child_Total : constant Positive := Child_Kind'Pos (Child_Kind'Last) + 1;
   subtype Order_Position is Positive range 1 .. Child_Total;

   type Specification_Array is
     array (Child_Kind) of Child_Specification;
   type Logical_Id_Array is array (Child_Kind) of Child_Id;
   type Dependency_Matrix is
     array (Child_Kind, Child_Kind) of Boolean;
   type Cohort_Matrix is
     array (Child_Kind, Child_Kind) of Boolean;
   type Child_Order is array (Order_Position) of Child_Kind;
   type Snapshot_Array is array (Child_Kind) of Child_Snapshot;
   type Boolean_Array is array (Child_Kind) of Boolean;
   type Time_Array is array (Child_Kind) of Ada.Real_Time.Time;
   type Natural_Array is array (Child_Kind) of Natural;
   type Event_Buffer is array (Positive range 1 .. Event_Capacity) of
     Supervisor_Event;

   type Lifecycle_Phase is
     (Unconfigured,
      Starting_Children,
      Running_Children,
      Recovery_Stopping,
      Recovery_Backing_Off,
      Recovery_Starting,
      Stopping_Children,
      Finished);

   protected type Lifecycle is
      procedure Configure
        (Specs       : Specification_Array;
         Ids         : Logical_Id_Array;
         Dependencies : Dependency_Matrix;
         Cohorts     : Cohort_Matrix;
         Start_Order : Child_Order;
         Stop_Order  : Child_Order;
         Inherited   : Incident_Context);
      procedure Try_Start
        (Child   : Child_Kind;
         Now     : Ada.Real_Time.Time;
         Started : out Boolean;
         Value   : out Child_Handle;
         Spec    : out Child_Specification;
         Incident : out Incident_Context);
      procedure Publish_Ready
        (Child : Child_Kind;
         Value : Child_Handle;
         Now   : Ada.Real_Time.Time);
      procedure Stop_Decision
        (Child    : Child_Kind;
         Value    : Child_Handle;
         Stop     : out Boolean;
         Shutdown : out Boolean;
         Spec     : out Stop_Policy);
      procedure Publish_Stuck
        (Child : Child_Kind;
         Value : Child_Handle);
      procedure Publish_Termination
        (Child       : Child_Kind;
         Value       : Child_Handle;
         Termination : Termination_Summary;
         Incident    : Incident_Context;
         Now         : Ada.Real_Time.Time);
      procedure Request_Stop;
      function Manager_Should_Exit return Boolean;
      procedure Manager_Finished;
      entry Await_Finished;
      entry Await_Managers;
      function Has_Configuration return Boolean;
      function Read_Result return Supervisor_Result;
      function Read_Snapshot (Child : Child_Kind) return Child_Snapshot;
      procedure Copy_Events
        (Cursor  : in out Event_Sequence;
         Target  : out Supervisor_Event_Array;
         Count   : out Natural;
         Dropped : out Event_Sequence);
   private
      procedure Begin_Terminal_Stop
        (Outcome     : Supervisor_Outcome;
         Child       : Child_Kind;
         Termination : Termination_Summary);
      procedure Advance_Stop_Order;
      procedure Advance_Recovery_Stop_Order;
      procedure Advance_Recovery_Start_Order;
      procedure Compute_Affected
        (Trigger : Child_Kind;
         Impact  : Restart_Impact;
         Result  : out Boolean_Array);
      procedure Begin_Recovery
        (Trigger     : Child_Kind;
         Termination : Termination_Summary;
         Incident    : Incident_Context;
         Now         : Ada.Real_Time.Time);
      procedure Classify_Restart
        (Child    : Child_Kind;
         Incident : Incident_Context;
         Now      : Ada.Real_Time.Time;
         Admitted : out Boolean;
         Backoff  : out Ada.Real_Time.Time_Span);
      procedure Record_Restart
        (Child    : Child_Kind;
         Incident : Incident_Context;
         Now      : Ada.Real_Time.Time;
         Backoff : Ada.Real_Time.Time_Span);
      procedure Record_Event
        (Child       : Child_Kind;
         Kind        : Event_Kind;
         Before      : Child_State;
         After       : Child_State;
         Now         : Ada.Real_Time.Time;
         Termination : Termination_Kind := No_Termination;
         Incident    : Incident_Context := No_Incident;
         Backoff     : Ada.Real_Time.Time_Span :=
           Ada.Real_Time.Time_Span_Zero);

      Phase         : Lifecycle_Phase := Unconfigured;
      Configured    : Boolean := False;
      Run_Used      : Boolean := False;
      Child_Specs   : Specification_Array;
      Child_Ids     : Logical_Id_Array;
      Child_Dependencies : Dependency_Matrix;
      Child_Cohorts : Cohort_Matrix;
      Starts        : Child_Order;
      Stops         : Child_Order;
      Snapshots     : Snapshot_Array;
      Has_Generation : Boolean_Array := (others => False);
      Ready_Since   : Time_Array := (others => Ada.Real_Time.Time_First);
      Restart_Due   : Time_Array := (others => Ada.Real_Time.Time_First);
      Incident_Since : Time_Array := (others => Ada.Real_Time.Time_First);
      Window_Since  : Time_Array := (others => Ada.Real_Time.Time_First);
      Window_Used   : Natural_Array := (others => 0);
      Total_Used    : Natural_Array := (others => 0);
      Consecutive   : Natural_Array := (others => 0);
      Recovery_Affected : Boolean_Array := (others => False);
      Recovery_Trigger  : Child_Kind := Child_Kind'First;
      Recovery_Stop_Position : Natural := 0;
      Recovery_Start_Position : Natural := 0;
      Recovery_Due : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Active_Incident : Incident_Context := No_Incident;
      Inherited_Incident : Incident_Context := No_Incident;
      Subtree_Window_Since : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Subtree_Incident_Since : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Subtree_Ready_Since : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Subtree_Window_Used : Natural := 0;
      Subtree_Total_Used : Natural := 0;
      Subtree_Consecutive : Natural := 0;
      Observed_Incident : Incident_Id := Incident_Id'First;
      Observed_Attempt : Incident_Attempt := Incident_Attempt'First;
      Has_Observed_Attempt : Boolean := False;
      Events         : Event_Buffer;
      Event_First    : Positive := Event_Buffer'First;
      Event_Length   : Natural := 0;
      Event_Last_Sequence : Event_Sequence := 0;
      Event_Sequence_Exhausted : Boolean := False;
      Start_Position : Natural := 0;
      Stop_Position  : Natural := 0;
      Managers_Done  : Natural := 0;
      Terminal       : Supervisor_Result;
   end Lifecycle;

   type Supervisor is limited record
      State : Lifecycle;
   end record;

end Flyology.Supervision.Static;
