with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Task_Identification;
with Flyology.Cancellation;
with Flyology.Execution_Groups;
with Flyology.Task_Results;
with Interfaces;

--  Defines the bounded, generation-safe vocabulary for structured task
--  supervision. Task-generation generics own application-defined Ada task
--  types; controllers supply typed topology and policy. No supervised task is
--  detached from its Ada master.
package Flyology.Supervision is

   --  Stable nonzero logical identity of one configured child. Capacity is a
   --  separate property of each supervisor instance.
   subtype Child_Id is Interfaces.Unsigned_64 range
     1 .. Interfaces.Unsigned_64'Last;

   --  Nonzero identity of one task-object generation. A restart creates a new
   --  generation and a new Ada task identity.
   subtype Generation is Interfaces.Unsigned_64 range
     1 .. Interfaces.Unsigned_64'Last;

   --  Stable nonzero identity of one recovery cascade. The same value is
   --  propagated through nested supervisors until the cascade completes.
   subtype Incident_Id is Interfaces.Unsigned_64 range
     1 .. Interfaces.Unsigned_64'Last;

   --  One admitted recovery attempt within an incident.
   subtype Incident_Attempt is Interfaces.Unsigned_64 range
     1 .. Interfaces.Unsigned_64'Last;

   --  Fixed recovery identity propagated through structured child calls.
   --  Inactive is the only representation that does not name an incident.
   type Incident_Context is private;

   --  Context used outside a recovery cascade.
   No_Incident : constant Incident_Context;

   --  Report whether Context identifies an active recovery cascade.
   --  @param Context Recovery context to inspect
   --  @return True when an incident id, attempt, and deadline are present
   function Active (Context : Incident_Context) return Boolean;

   --  Return the active incident identity.
   --  @param Context Active recovery context
   --  @return Stable incident identity
   --  @exception Program_Error Context is inactive
   function Incident (Context : Incident_Context) return Incident_Id;

   --  Return the active incident attempt.
   --  @param Context Active recovery context
   --  @return Current attempt within the incident
   --  @exception Program_Error Context is inactive
   function Attempt (Context : Incident_Context) return Incident_Attempt;

   --  Return the inherited absolute monotonic recovery deadline.
   --  @param Context Active recovery context
   --  @return Absolute deadline shared by the recovery hierarchy
   --  @exception Program_Error Context is inactive
   function Recovery_Deadline
     (Context : Incident_Context) return Ada.Real_Time.Time;

   --  Logical child plus exact generation. Supervisory operations must reject
   --  a handle whose generation is no longer current.
   type Child_Handle is private;

   --  Return the logical identity carried by Handle.
   --  @param Handle Generation-qualified child handle
   --  @return Stable logical child identity
   function Child (Handle : Child_Handle) return Child_Id;

   --  Return the generation carried by Handle.
   --  @param Handle Generation-qualified child handle
   --  @return Exact child generation
   function Current_Generation (Handle : Child_Handle) return Generation;

   --  Report whether two handles were issued by the same process-local
   --  controller identity. Controller identities never migrate between
   --  supervisor objects or survive process restart.
   --  @param Left First generation-qualified handle
   --  @param Right Second generation-qualified handle
   --  @return True only when both handles came from the same controller
   function Same_Controller (Left, Right : Child_Handle) return Boolean;

   --  Test whether Handle names the supplied logical child and generation.
   --  @param Handle Generation-qualified child handle
   --  @param Id Expected logical child identity
   --  @param Value Expected generation
   --  @return True only for an exact logical and generational match
   function Is_Current
     (Handle : Child_Handle;
      Id     : Child_Id;
      Value  : Generation) return Boolean;

   --  Observable lifecycle of one logical child.
   --  @enum Configured Policy is validated but no task object exists
   --  @enum Starting A new task object is activating or awaiting readiness
   --  @enum Ready The generation reported readiness but is not yet published
   --  @enum Running The ready generation is published to dependents
   --  @enum Stopping Cooperative shutdown or restart teardown is in progress
   --  @enum Terminated The task and its task-body finalization completed
   --  @enum Backing_Off A monotonic restart delay is pending
   --  @enum Restarting Policy admitted construction of a replacement
   --  @enum Failed_Escalated Local recovery ended or was escalated
   --  @enum Joined No task can publish again and all owned state is reclaimed
   type Child_State is
     (Configured,
      Starting,
      Ready,
      Running,
      Stopping,
      Terminated,
      Backing_Off,
      Restarting,
      Failed_Escalated,
      Joined);

   --  Why one generation ceased to be usable.
   --  @enum No_Termination No generation has terminated
   --  @enum Normal_Return The task body returned normally
   --  @enum Unhandled_Exception GNARL observed an exception escaping the task
   --  @enum Cancelled The child observed cooperative cancellation
   --  @enum Supervisor_Shutdown The owning supervisor requested shutdown
   --  @enum Abnormal_Completion Ada reported abnormal task termination
   --  @enum Activation_Failure Task activation raised Tasking_Error
   --  @enum Readiness_Timeout Activation completed but readiness did not
   --  @enum Restart_Requested An exact-generation manual restart was requested
   --  @enum Unhealthy A health probe rejected the running generation
   --  @enum Stop_Timeout The cooperative grace deadline expired
   --  @enum Stuck Abort was omitted, deferred, or could not be observed
   --  @enum Policy_Exhaustion Recovery limits rejected another attempt
   type Termination_Kind is
     (No_Termination,
      Normal_Return,
      Unhandled_Exception,
      Cancelled,
      Supervisor_Shutdown,
      Abnormal_Completion,
      Activation_Failure,
      Readiness_Timeout,
      Restart_Requested,
      Unhealthy,
      Stop_Timeout,
      Stuck,
      Policy_Exhaustion);

   --  Maximum retained exception or policy diagnostic text.
   Maximum_Diagnostic_Length : constant := 512;
   --  Maximum retained fully qualified exception-name characters.
   Maximum_Exception_Name_Length : constant :=
     Flyology.Task_Results.Exception_Name_Capacity;
   --  Valid used length within a fixed diagnostic buffer.
   subtype Diagnostic_Length is
     Natural range 0 .. Maximum_Diagnostic_Length;
   --  Valid used length within a fixed exception-name buffer.
   subtype Exception_Name_Length is
     Natural range 0 .. Maximum_Exception_Name_Length;

   --  Bounded failure information safe after an exception occurrence and task
   --  object are gone. Task_Id is diagnostic only and must not be used to
   --  control a replacement generation.
   --  @field Kind Classified terminal outcome
   --  @field Exception_Id Retained library-level exception identity when an
   --  occurrence was classified directly; automatic task-exit observation
   --  retains the portable name and leaves this Null_Id
   --  @field Exception_Name_Length Used prefix of Exception_Name
   --  @field Exception_Name_Truncated Whether the source name exceeded its
   --  fixed task-result capacity
   --  @field Exception_Name Bounded fully qualified exception name
   --  @field Task_Id Ada identity of the terminated generation
   --  @field Message_Length Used prefix of Message
   --  @field Message_Truncated Whether the source message exceeded retained
   --  storage
   --  @field Message Bounded copied diagnostic text
   type Termination_Summary is record
      Kind           : Termination_Kind := No_Termination;
      Exception_Id   : Ada.Exceptions.Exception_Id :=
        Ada.Exceptions.Null_Id;
      Exception_Name_Length : Supervision.Exception_Name_Length := 0;
      Exception_Name_Truncated : Boolean := False;
      Exception_Name : String (1 .. Maximum_Exception_Name_Length) :=
        (others => ' ');
      Task_Id        : Ada.Task_Identification.Task_Id :=
        Ada.Task_Identification.Null_Task_Id;
      Message_Length : Diagnostic_Length := 0;
      Message_Truncated : Boolean := False;
      Message        : String (1 .. Maximum_Diagnostic_Length) :=
        (others => ' ');
   end record;

   --  Return the meaningful fully qualified exception name, or the empty
   --  string when no exception name was retained.
   --  @param Item Bounded terminal summary
   --  @return Retained exception name without unused fixed storage
   function Exception_Name_Text (Item : Termination_Summary) return String is
     (Item.Exception_Name (1 .. Item.Exception_Name_Length));

   --  Return the meaningful diagnostic message, or the empty string when no
   --  message was retained.
   --  @param Item Bounded terminal summary
   --  @return Retained message without unused fixed storage
   function Message_Text (Item : Termination_Summary) return String is
     (Item.Message (1 .. Item.Message_Length));

   --  Child-level restart selection.
   --  @enum Never Do not replace a terminated generation
   --  @enum On_Failure Replace only after a failure-class termination
   --  @enum Always Replace after normal or failed termination, but never after
   --  explicit supervisor shutdown, a stuck child, or policy exhaustion
   type Restart_Kind is (Never, On_Failure, Always);

   --  Explicit effect of one child failure.
   --  @enum Isolate_Child Restart only the failed logical child
   --  @enum Restart_Cohort Restart the failed child and a named cohort
   --  @enum Restart_Dependents Restart the failed child and declared users
   --  @enum Escalate Do not recover at this supervisor node
   type Restart_Impact is
     (Isolate_Child, Restart_Cohort, Restart_Dependents, Escalate);

   --  Fixed recovery limits. Total_Attempts applies to one incident and is
   --  reset only after Stability_Reset. Window and all delays use monotonic
   --  Ada.Real_Time values. A zero Recovery_Deadline means no local recovery
   --  time; Time_Span_Last means no additional absolute limit.
   --  @field Burst_Attempts Maximum admitted attempts within Window
   --  @field Window Sliding-window duration
   --  @field Total_Attempts Maximum attempts in one recovery incident
   --  @field Initial_Backoff Delay before the first replacement
   --  @field Maximum_Backoff Cap for exponential delay
   --  @field Stability_Reset Ready duration that closes the incident
   --  @field Recovery_Deadline Maximum duration of one incident
   type Recovery_Limits is record
      Burst_Attempts    : Positive;
      Window            : Ada.Real_Time.Time_Span;
      Total_Attempts    : Positive;
      Initial_Backoff   : Ada.Real_Time.Time_Span;
      Maximum_Backoff   : Ada.Real_Time.Time_Span;
      Stability_Reset   : Ada.Real_Time.Time_Span;
      Recovery_Deadline : Ada.Real_Time.Time_Span;
   end record;

   --  Default bounded recovery policy used by child specifications.
   Default_Recovery_Limits : constant Recovery_Limits :=
     (Burst_Attempts    => 3,
      Window            => Ada.Real_Time.Seconds (5),
      Total_Attempts    => 10,
      Initial_Backoff   => Ada.Real_Time.Milliseconds (10),
      Maximum_Backoff   => Ada.Real_Time.Seconds (1),
      Stability_Reset   => Ada.Real_Time.Seconds (30),
      Recovery_Deadline => Ada.Real_Time.Seconds (60));

   --  Cooperative stop policy. Request_Abort permits an Ada abort request
   --  after Grace expires; it does not promise bounded termination.
   --  @field Grace Cooperative cancellation interval
   --  @field Request_Abort Whether to issue an optional abort request
   --  @field Abort_Observation Additional observation interval before Stuck
   type Stop_Policy is record
      Grace             : Ada.Real_Time.Time_Span;
      Request_Abort     : Boolean;
      Abort_Observation : Ada.Real_Time.Time_Span;
   end record;

   --  Default cooperative stop policy. Abort is not requested implicitly.
   Default_Stop_Policy : constant Stop_Policy :=
     (Grace             => Ada.Real_Time.Seconds (5),
      Request_Abort     => False,
      Abort_Observation => Ada.Real_Time.Seconds (1));

   --  Complete static policy for one logical child.
   --  Restart_Safe is an explicit application acknowledgement that a fresh
   --  generation may safely reacquire its owned resources and resume use of
   --  shared state. If the generation owns a nested one-shot controller, the
   --  acknowledgement also covers reconstruction of that controller and
   --  application-directed replay of its desired topology. Local automatic
   --  restart is rejected when it is False.
   --  Task_Model must be explicitly Flyology.Lightweight_Task or
   --  Flyology.Native_Task; Project_Default is rejected because supervision
   --  cannot resolve it to a concrete model for placement validation.
   --  @field Restart Child-level replacement selection
   --  @field Impact Children affected by a local recovery incident
   --  @field Recovery Monotonic restart limits and delays
   --  @field Stopping Cooperative and optional abort policy
   --  @field Readiness_Timeout Maximum interval before explicit readiness
   --  @field Restart_Safe Application acknowledgement of restart safety
   --  @field Task_Model Configured execution model reported in snapshots
   --  @field Has_Group Whether Group applies to a lightweight generation
   --  @field Group Configured lightweight execution group
   type Child_Specification is record
      Restart           : Restart_Kind := Never;
      Impact            : Restart_Impact := Escalate;
      Recovery          : Recovery_Limits := Default_Recovery_Limits;
      Stopping          : Stop_Policy := Default_Stop_Policy;
      Readiness_Timeout : Ada.Real_Time.Time_Span :=
        Ada.Real_Time.Seconds (30);
      Restart_Safe      : Boolean := False;
      Task_Model        : Flyology.Execution_Model := Flyology.Project_Default;
      Has_Group         : Boolean := False;
      Group             : Flyology.Execution_Groups.Group_Id :=
        Flyology.Execution_Groups.Group_Id'First;
   end record;

   --  Generation-local readiness and cancellation channel. A child receives
   --  a borrowed access value whose lifetime ends when its generation task
   --  joins. It must not retain that value or the returned cancellation token.
   type Generation_Control is limited private;

   --  Return the exact logical child and generation represented by Control.
   --  @param Control Active generation control
   --  @return Generation-qualified logical handle
   function Handle (Control : Generation_Control) return Child_Handle;

   --  Return the generation-owned cancellation source. The value is borrowed
   --  and may be passed to task-aware Flyology I/O. It becomes invalid when
   --  the generation runner returns.
   --  @param Control Active generation control kept alive by the caller
   --  @return Borrowed generation-owned cancellation source
   function Stopping
     (Control : aliased in out Generation_Control)
      return not null access Flyology.Cancellation.Token;

   --  Publish that activation and application initialization completed. This
   --  is a one-shot handshake; a second call or a call after stopping begins
   --  raises Program_Error.
   --  @param Control Active generation control
   --  @exception Program_Error Control is inactive, already ready, or stopping
   procedure Mark_Ready (Control : in out Generation_Control);

   --  Report whether the supervisor requested cooperative stop.
   --  @param Control Active generation control
   --  @return True after a stop request is published
   function Stop_Requested (Control : Generation_Control) return Boolean;

   --  Report whether an optional Ada abort request was published. This is for
   --  structured child runners; application callbacks normally inspect only
   --  the cancellation token.
   --  @param Control Active generation control
   --  @return True after the stop grace interval requested abort
   function Abort_Requested (Control : Generation_Control) return Boolean;

   --  Return the recovery incident inherited by this generation. Initial
   --  startup normally returns No_Incident; replacement generations retain
   --  the incident and attempt that admitted them.
   --  @param Control Active generation control
   --  @return Inherited recovery context or No_Incident
   function Recovery_Incident
     (Control : Generation_Control) return Incident_Context;

   --  Propagate a nested supervisor's active incident through this generation
   --  without creating another attempt. The call is accepted only while the
   --  exact generation remains active.
   --  @param Control Active outer generation control
   --  @param Context Active incident returned by a nested supervisor
   --  @exception Program_Error Control or Context is inactive
   procedure Report_Escalation
     (Control : in out Generation_Control;
      Context : Incident_Context);

   --  Optionally override automatic task-result classification with normal
   --  completion. Task_Generations already observes an uncaught normal return;
   --  use this only when an application deliberately needs to publish a
   --  different semantic result after its owned resource scope finalized.
   --  @param Control Generation control borrowed by the reporting task
   --  @exception Program_Error No active generation exists or an outcome was
   --  already reported
   procedure Report_Normal_Return (Control : in out Generation_Control);

   --  Optionally override automatic task-result classification with
   --  cooperative cancellation. An uncaught Cancellation.Operation_Cancelled,
   --  or a normal return after the supervisor requested stop, is classified
   --  automatically. This operation remains useful when application code
   --  catches and suppresses cancellation from another source. Cancellation
   --  caused by supervisor shutdown is retained as Supervisor_Shutdown.
   --  @param Control Generation control borrowed by the reporting task
   --  @exception Program_Error No active generation exists or an outcome was
   --  already reported
   procedure Report_Cancellation (Control : in out Generation_Control);

   --  Reject this generation from inside its task after detecting a bounded
   --  health failure. The diagnostic is copied before cooperative stop is
   --  requested. On_Failure and Always policies treat this as a recoverable
   --  failure; the configured impact and recovery budgets still apply.
   --  @param Control Generation control borrowed by the reporting task
   --  @param Diagnostic Application health diagnostic copied immediately
   --  @exception Program_Error No active generation exists or an outcome was
   --  already reported
   procedure Report_Unhealthy
     (Control    : in out Generation_Control;
      Diagnostic : String);

   --  Optionally override automatic task-result classification with an
   --  exception that application code caught and suppressed. Exceptions that
   --  escape the task body are copied automatically after task finalization.
   --  This operation copies the occurrence immediately and remains available
   --  for source compatibility and deliberate semantic translation.
   --  @param Control Generation control borrowed by the reporting task
   --  @param Occurrence Exception caught by the outer task-body handler
   --  @exception Program_Error No active generation exists or an outcome was
   --  already reported
   procedure Report_Exception
     (Control    : in out Generation_Control;
      Occurrence : Ada.Exceptions.Exception_Occurrence);

   --  Completion returned by one structured generation runner after its local
   --  Ada master has joined the task and completed task-body finalization.
   --  @field Termination Bounded copied terminal information
   --  @field Reported_Ready Whether readiness was published before completion
   --  @field Incident Nested incident propagated by the generation, if any
   type Generation_Result is record
      Termination    : Termination_Summary;
      Reported_Ready : Boolean := False;
      Incident       : Incident_Context := No_Incident;
   end record;

   --  Terminal outcome of a synchronous supervisor run.
   --  @enum Shutdown_Completed Explicit shutdown joined every child
   --  @enum Startup_Failed A child failed before initial readiness completed
   --  @enum Recovery_Exhausted Recovery limits rejected another generation
   --  @enum Failure_Escalated Child policy required the owning scope to fail
   --  @enum Child_Stuck A child remained live after the diagnostic stop policy
   type Supervisor_Outcome is
     (Shutdown_Completed,
      Startup_Failed,
      Recovery_Exhausted,
      Failure_Escalated,
      Child_Stuck);

   --  Typed terminal result returned only after every terminable child joins.
   --  A Child_Stuck result remains observable in snapshots, but synchronous
   --  Run cannot return it while the task is still alive.
   --  @field Outcome Terminal classification
   --  @field Child Logical child that caused a non-shutdown outcome
   --  @field Generation Generation that caused the outcome
   --  @field Termination Bounded causal termination information
   --  @field Incident Recovery cascade propagated to the owning scope
   type Supervisor_Result is record
      Outcome     : Supervisor_Outcome := Shutdown_Completed;
      Child       : Child_Id := Child_Id'First;
      Generation  : Supervision.Generation := Supervision.Generation'First;
      Termination : Termination_Summary;
      Incident    : Incident_Context := No_Incident;
   end record;

   --  Monotonic sequence used by bounded supervisor event rings. Zero is a
   --  valid initial cursor and is never assigned to a recorded event.
   subtype Event_Sequence is Interfaces.Unsigned_64;

   --  Observable reason for a supervisor event.
   --  @enum Lifecycle_Changed A child moved between lifecycle states
   --  @enum Readiness_Published A generation completed its readiness handshake
   --  @enum Stop_Published Cooperative cancellation was requested
   --  @enum Restart_Admitted A bounded recovery attempt was admitted
   --  @enum Restart_Completed Every affected replacement became ready
   --  @enum Recovery_Escalated Recovery was rejected or delegated upward
   --  @enum Child_Became_Stuck A live generation exceeded stop observation
   --  @enum Supervisor_Stopped Explicit structured shutdown began
   type Event_Kind is
     (Lifecycle_Changed,
      Readiness_Published,
      Stop_Published,
      Restart_Admitted,
      Restart_Completed,
      Recovery_Escalated,
      Child_Became_Stuck,
      Supervisor_Stopped);

   --  Fixed copied supervisor event. The event contains enough scalar policy
   --  state to explain ordering, restart admission, and escalation without
   --  logging from a protected action.
   --  @field Sequence Monotonic sequence within the supervisor instance
   --  @field Timestamp Monotonic observation time
   --  @field Kind Event classification
   --  @field Child Logical child involved
   --  @field Generation Exact child generation
   --  @field Before Lifecycle state before the event
   --  @field After Lifecycle state after the event
   --  @field Task_Model Configured execution model
   --  @field Has_Group Whether Group is meaningful
   --  @field Group Configured lightweight execution group
   --  @field Termination Bounded causal termination classification
   --  @field Incident Recovery incident, if any
   --  @field Backoff Admitted delay before replacement construction
   type Supervisor_Event is record
      Sequence    : Event_Sequence := 0;
      Timestamp   : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Kind        : Event_Kind := Lifecycle_Changed;
      Child       : Child_Id := Child_Id'First;
      Generation  : Supervision.Generation := Supervision.Generation'First;
      Before      : Child_State := Configured;
      After       : Child_State := Configured;
      Task_Model  : Flyology.Execution_Model := Flyology.Project_Default;
      Has_Group   : Boolean := False;
      Group       : Flyology.Execution_Groups.Group_Id :=
        Flyology.Execution_Groups.Group_Id'First;
      Termination : Termination_Kind := No_Termination;
      Incident    : Incident_Context := No_Incident;
      Backoff     : Ada.Real_Time.Time_Span :=
        Ada.Real_Time.Time_Span_Zero;
   end record;

   --  Caller-owned destination for copied bounded events.
   type Supervisor_Event_Array is
     array (Positive range <>) of Supervisor_Event;

   --  Bounded observation of one configured logical child.
   --  @field Id Stable logical identity
   --  @field Generation Current or most recently completed generation
   --  @field State Current lifecycle
   --  @field Task_Model Configured task execution model
   --  @field Has_Group Whether Group is meaningful for a lightweight task
   --  @field Group Configured lightweight execution group
   --  @field Termination Last bounded termination information
   --  @field Attempts Attempts admitted in the active incident
   --  @field Backoff Current monotonic delay
   --  @field Ready Whether the current generation completed its handshake
   --  @field Live Whether an Ada task object for this generation may be alive
   --  @field Escalated Whether recovery was forwarded to the parent
   type Child_Snapshot is record
      Id          : Child_Id;
      Generation  : Supervision.Generation;
      State       : Child_State;
      Task_Model  : Flyology.Execution_Model;
      Has_Group   : Boolean;
      Group       : Flyology.Execution_Groups.Group_Id;
      Termination : Termination_Summary;
      Attempts    : Interfaces.Unsigned_64;
      Backoff     : Ada.Real_Time.Time_Span;
      Ready       : Boolean;
      Live        : Boolean;
      Escalated   : Boolean;
   end record;

   --  Result of waiting for one exact supervised generation.
   --  @enum Generation_Terminated The named generation completed and its
   --     bounded terminal snapshot was retained
   --  @enum Generation_Replaced The logical child now names another
   --     generation; the returned snapshot describes that current generation
   --  @enum Observation_Timed_Out The deadline elapsed before either outcome
   type Generation_Observation_Status is
     (Generation_Terminated,
      Generation_Replaced,
      Observation_Timed_Out);

   --  One generation-safe supervisor observation. A timeout carries no
   --  snapshot; completed observations contain only fixed copied state and do
   --  not retain a task object or supervisor-owned resource.
   --  @field Status Whether the generation terminated, was replaced, or the
   --     wait timed out
   --  @field Snapshot Exact terminal snapshot or current replacement snapshot
   type Generation_Observation
     (Status : Generation_Observation_Status := Observation_Timed_Out)
   is record
      case Status is
         when Observation_Timed_Out =>
            null;
         when Generation_Terminated | Generation_Replaced =>
            Snapshot : Child_Snapshot;
      end case;
   end record;

private
   type Controller_Id is new Interfaces.Unsigned_64 range
     0 .. Interfaces.Unsigned_64'Last;

   type Incident_Context is record
      Is_Active : Boolean := False;
      Id        : Incident_Id := Incident_Id'First;
      Number    : Incident_Attempt := Incident_Attempt'First;
      Deadline  : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   end record;

   No_Incident : constant Incident_Context :=
     (Is_Active => False,
      Id        => Incident_Id'First,
      Number    => Incident_Attempt'First,
      Deadline  => Ada.Real_Time.Time_First);

   type Child_Handle is record
      Controller : Controller_Id := 0;
      Id         : Child_Id := Child_Id'First;
      Generation : Supervision.Generation := Supervision.Generation'First;
   end record;

   --  @exclude
   --  @return Fresh process-local controller identity
   function New_Controller return Controller_Id;

   --  @exclude
   --  @param Handle Generation-qualified handle
   --  @return Controller identity carried by Handle
   function Controller (Handle : Child_Handle) return Controller_Id;

   --  @exclude
   --  @param Kind Internal terminal classification
   --  @param Diagnostic Diagnostic copied into bounded retained storage
   --  @return Fixed terminal summary without exception or task identity
   function Diagnostic_Summary
     (Kind       : Termination_Kind;
      Diagnostic : String) return Termination_Summary;

   protected type Generation_Control_State is
      procedure Open
        (Value    : Child_Handle;
         Incident : Incident_Context);
      procedure Publish_Ready;
      procedure Publish_Stop (Shutdown : Boolean);
      procedure Publish_Abort;
      procedure Publish_Escalation (Incident : Incident_Context);
      procedure Publish_Termination (Value : Termination_Summary);
      procedure Close_Incident;
      function Current_Handle return Child_Handle;
      function Is_Ready return Boolean;
      function Is_Stopping return Boolean;
      function Is_Shutdown return Boolean;
      function Is_Abort_Requested return Boolean;
      function Current_Incident return Incident_Context;
      procedure Read_Termination
        (Reported : out Boolean;
         Value    : out Termination_Summary);
   private
      Value           : Child_Handle;
      Opened          : Boolean := False;
      Ready           : Boolean := False;
      Stopping        : Boolean := False;
      Shutdown_Stop   : Boolean := False;
      Abort_Requested : Boolean := False;
      Escalated       : Boolean := False;
      Incident        : Incident_Context := No_Incident;
      Termination_Reported : Boolean := False;
      Termination          : Termination_Summary;
   end Generation_Control_State;

   type Generation_Control is limited record
      State      : Generation_Control_State;
      Stop_Token : aliased Flyology.Cancellation.Token;
   end record;

   --  @exclude
   --  @param Control Internal generation control
   --  @param Value Internal generation handle
   --  @param Incident Internal inherited recovery context
   procedure Open
     (Control : in out Generation_Control;
      Value   : Child_Handle;
      Incident : Incident_Context := No_Incident);

   --  @exclude
   --  @param Now Monotonic incident start
   --  @param Deadline Absolute incident deadline
   --  @return Fresh process-local incident context
   function New_Incident
     (Now      : Ada.Real_Time.Time;
      Deadline : Ada.Real_Time.Time) return Incident_Context;

   --  @exclude
   --  @param Context Active incident to advance
   --  @return Same incident with the next attempt
   --  @exception Program_Error Context is inactive or exhausted
   function Next_Attempt
     (Context : Incident_Context) return Incident_Context;

   --  @exclude
   --  @param Control Internal generation control whose inherited recovery
   --  incident reached its stability boundary
   procedure Close_Recovery_Incident
     (Control : in out Generation_Control);

   --  @exclude
   --  @param Control Internal generation control
   --  @param Shutdown Whether the owning supervisor is shutting down
   procedure Request_Stop
     (Control  : in out Generation_Control;
      Shutdown : Boolean);

   --  @exclude
   --  @param Control Internal generation control
   procedure Request_Abort (Control : in out Generation_Control);

   --  @exclude
   --  @param Control Internal generation control
   --  @return Internal readiness state
   function Is_Ready (Control : Generation_Control) return Boolean;

   --  @exclude
   --  @param Control Internal generation control
   --  @return Whether stop represents supervisor shutdown
   function Shutdown_Stop (Control : Generation_Control) return Boolean;

   --  @exclude
   --  @param Control Internal generation control used to classify stop
   --  @param Task_Id Actual task identity of this generation
   --  @param Result Immutable terminal result observed from GNARL
   --  @return Supervision termination summary with bounded diagnostics
   function From_Task_Result
     (Control : Generation_Control;
      Task_Id : Ada.Task_Identification.Task_Id;
      Result  : Flyology.Task_Results.Task_Result)
      return Termination_Summary;

   --  @exclude
   --  @param Control Internal generation control
   --  @param Reported Whether the generation task published an outcome
   --  @param Value Published outcome when Reported is True
   procedure Read_Termination
     (Control  : in out Generation_Control;
      Reported : out Boolean;
      Value    : out Termination_Summary);
end Flyology.Supervision;
