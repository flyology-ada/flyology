# Ada-native structured supervision

Status: implemented production API slice under semantic review.

This design adds fault-management policy above ordinary Ada tasking. It keeps
Ada task activation, masters, dependent-task joining, rendezvous, protected
objects, exception propagation, abort deferral, controlled finalization, and
task identity authoritative. It does not isolate shared memory or change GNARL
task semantics.

The checked-in implementation consists of the public vocabulary and
generation control in `Flyology.Supervision`, application-task owners in
`Flyology.Supervision.Task_Generations` and
`Flyology.Supervision.Input_Task_Generations`, procedure-body convenience
adapters in `Flyology.Supervision.Children` and
`Flyology.Supervision.Input_Children`, the heterogeneous static controller in
`Flyology.Supervision.Static`, the homogeneous fixed-capacity controller in
`Flyology.Supervision.Families`, and the SPARK policy kernel in
`Flyology.Supervision_Policy`. Typed generation publication is provided by
`Flyology.Supervision.Service_Slots`, and
`Flyology.Supervision.Adapters` bridges structured blocking service owners.
Static recovery supports isolated children,
named cohorts, transitive dependents, subtree budgets, nested incident
propagation, and bounded event rings. Dynamic families provide typed request
copying, fixed linear slots, generation-safe reuse, nested incident
propagation, and bounded event rings.

## Goals and non-goals

The primitive should provide:

- typed static topology and typed homogeneous dynamic families;
- stable logical child ids distinct from generation and Ada task identity;
- bounded waits that observe one exact generation without following its
  replacement;
- controller-qualified handles and typed generation-aware service publication;
- exact-generation manual restart and failed health-probe commands;
- dependency-aware deterministic startup, rollback, shutdown, and restart;
- explicit readiness, cooperative stopping, bounded policy state, and an
  observable `Stuck` outcome;
- per-child and subtree recovery limits driven by a monotonic clock;
- one incident and attempt identity propagated through nested supervisors;
- structured ownership: no task or borrowed callback context outlives its Ada
  scope; and
- bounded snapshots and event storage from which a policy decision can be
  replayed.

It does not provide:

- process isolation, copy-only messages, or automatic repair of shared memory;
- a guaranteed kill operation or bounded shutdown latency;
- transparent restart of an Ada task, task entry, protected object, socket,
  file, buffer, thread pin, or dedicated execution group;
- a process-wide restart of Flyology's event runtime;
- a replacement for application-specific resource ownership and recovery
  design; or
- dynamic untyped argument lists, `System.Address` payloads, detached tasks, or
  a second tasking dialect.

## Repository boundary

The implementation can reuse existing mechanisms, but their current one-shot
contracts should not be silently changed.

| Existing part | Reuse | Generalize | Keep separate |
| --- | --- | --- | --- |
| `Flyology.Cancellation.Token` | one-shot child and subtree stop source; task-aware I/O wake | add no reset; allocate a new token per generation | restart accounting and readiness |
| `Flyology.Task_Scopes` | scope identity, fixed storage, finalization-triggered cancel and join, retained exception id/message | its owner/generation handle check is a model for stale rejection | it is a one-shot homogeneous operation scope, not a task factory |
| `Flyology.Worker_Pools` | activation gate, dependent task scope, first bounded failure, cleanup guards | adapt a freshly constructed pool as one supervised service | queue draining is not child restart |
| `Flyology.Capacity` | bounded admission and drain when a child owns concurrent work | no supervisor-specific behavior belongs in the gate | permits never transfer implicitly to a replacement |
| `Flyology.IO.Structured_Servers` | reverse cleanup, exact listener ownership, cancel/drain phases, activation rollback | adapt a fresh server and listener as one supervised service | `Server` remains one-shot; restart creates a new server and listener |
| `Flyology.Observability` | actual lightweight group and sampled stall evidence | supervision snapshots are an application layer, not a runtime ABI extension | scheduler counters do not determine restart policy |
| `Flyology.Task_Results` | task-owned normal, exception, or abnormal terminal result published after finalization; a limited monitor may retain that fixed sidecar after task-object reclamation | map the fixed result into generation policy without another runtime callback | it observes one exact task only and contains no restart policy or failure coupling |
| scheduler create/destroy/reap | evidence that a finished fiber is reaped only after GNARL destroys its task object, with running/migrating destruction deferred | none for the first implementation | supervision composes ordinary Ada task semantics |

The scheduler already distinguishes a task wrapper returning from the later
fiber-record reap. A supervisor must wait for the Ada task master and task-body
finalization, not infer resource reclamation from a scheduler snapshot. The
shared `Task_Results` runtime facility observes a generation through GNARL's
existing task wrapper, and the containing Ada master is the join boundary.
Supervision adds no second runtime hook or task-termination callback.

## Ada task boundary

An Ada task shares arbitrary memory, protected objects, foreign state,
descriptors, and masters with its siblings. Ada abort can be deferred, a native
task can be stuck in a foreign call, and a lightweight task can monopolize its
cooperative execution group. Therefore:

- restart always constructs a new Ada task object;
- a shutdown deadline classifies progress but cannot force reclamation;
- shared state touched by a failed task is not presumed valid;
- no replacement is published until the old task has joined and the new task
  has explicitly reported ready; and
- a `Stuck` child makes its node non-restartable and non-finalizable until the
  task actually terminates or the process exits.

## Ownership and API shape

### Chosen shape

Use generics and a limited application topology object, not a universal child
record. `Flyology.Supervision.Static` is parameterized by an application child
enumeration, a limited context type, typed configuration functions, a declared
dependency relation, and one typed generation factory:

```ada
generic
   type Child_Kind is (<>);
   type Application_Context (<>) is limited private;
   with function Logical_Id (Child : Child_Kind) return Child_Id;
   with function Specification
     (Child : Child_Kind) return Child_Specification;
   with function Depends_On
     (Child, Prerequisite : Child_Kind) return Boolean;
   with function Cohort_Member
     (Trigger, Member : Child_Kind) return Boolean;
   with procedure Run_One_Generation
     (Context : aliased in out Application_Context;
      Child   : Child_Kind;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result);
package Flyology.Supervision.Static is
   type Supervisor is limited private;
   procedure Run
     (Item    : aliased in out Supervisor;
      Context : aliased in out Application_Context;
      Result  : out Supervisor_Result);
   procedure Run_Nested
     (Item    : aliased in out Supervisor;
      Context : aliased in out Application_Context;
      Parent  : aliased in out Generation_Control;
      Result  : out Supervisor_Result);
   procedure Request_Shutdown (Item : in out Supervisor);
end Flyology.Supervision.Static;
```

`Run` is synchronous, like `Worker_Pools.Run` and
`IO.Structured_Servers.Serve`. Its nested manager scope joins every generation
before returning. Explicit shutdown is cooperative. If the caller instead
aborts the task executing `Run`, ordinary Ada task dependence applies to its
manager tasks and their nested generation tasks; the current implementation
does not disguise that abort as cooperative shutdown. Task-body finalization
and dependent-task joining remain Ada-controlled. Omitting `Request_Shutdown`
is safe only if another terminal rule ends `Run`; omitting an explicit join is
safe because `Run` cannot return without one.

Shutdown is sticky across configuration. A request made before `Run`, or while
static policy callbacks are still being validated, prevents manager activation
and child admission. Configuration never reopens a family after shutdown.

The primary generation boundary accepts an application-defined task type:

```ada
generic
   type Application_Context (<>) is limited private;
   type Generation_Task (<>) is limited private;
   with function Create
     (Context : not null access Application_Context;
      Control : not null access Generation_Control) return Generation_Task
      is <>;
   with procedure Initialize
     (Subject : in out Generation_Task;
      Control : aliased in out Generation_Control) is null;
   with function Task_Identity
     (Subject : in out Generation_Task) return Ada.Task_Identification.Task_Id
      is <>;
   with procedure Abort_Task (Subject : in out Generation_Task) is <>;
package Flyology.Supervision.Task_Generations is
   procedure Run
     (Context : aliased in out Application_Context;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result);
end Flyology.Supervision.Task_Generations;
```

`Generation_Task` is an indefinite limited-private formal, so its actual may
be an ordinary task type with any discriminants, application entries, task
aspects, package operations, and a separately written task body. `Create`
returns that exact task object by Ada limited build-in-place return; no copying
or address-valued payload is involved. The generic declares the result in a
local block. `Initialize` may make a bounded startup entry call or invoke a
task-specific package operation after activation; it runs outside controller
locks and must not retain the task object or execute the service loop.
`Flyology.Task_Results` automatically records normal return, an exception that
escapes the task body, or abnormal completion. Generation-owned resources still
belong inside the task body so their cleanup and dependent-task joins precede
terminal publication. No application reporting handler is required.

The explicit `Report_Normal_Return`, `Report_Cancellation`, and
`Report_Exception` operations remain source compatible as semantic overrides.
They are useful only when application code catches and suppresses an outcome but
still wants supervision to classify it as that outcome. When present, the
explicit classification wins; `Task_Generations` still waits for the actual
task result and finalization before returning.

The generic observes termination, dispatches the configured optional Ada abort
through the typed `Abort_Task` adapter, and leaves the local master only after
the task has terminated. Re-entering `Run` constructs a new object under a new
master. No access-to-task allocation or detached collection master is used.
`Task_Identity` supplies diagnostic identity and `Abort_Task` supplies the
optional last-resort stop request for the exact generation type. `Create` is
also the lifetime boundary: it may select arbitrary discriminants from the
typed context, but every reference retained by the returned task must remain
valid until that task joins. The boxed defaults infer directly visible,
profile-conformant `Create`, `Task_Identity`, and `Abort_Task` operations by
name. `Initialize` remains explicit when used because omission intentionally
selects its null default.

`Flyology.Supervision.Children` remains source-compatible as a convenience for
applications that only need a procedure body. It declares a private task type
and uses `Task_Generations`; it is no longer the architectural generation
boundary.

The task object itself does not escape `Task_Generations.Run`. Startup code may
use its entries through `Initialize`, and generation-owned tasks may use their
normal lexical references. A long-lived public service API must instead use a
typed protected object or bounded channel in the application context and carry
the scalar `Child_Handle` obtained from `Handle (Control)`. The receiver rejects
a handle whose generation is no longer current. Publishing a naked
access-to-task value would let a stale client rendezvous with reclaimed storage
and is deliberately unsupported.

The application topology dispatch is an exhaustive case over its enumeration:

```ada
procedure Run_One_Generation
  (Tree    : aliased in out Service_Topology;
   Id      : Service_Id;
   Control : aliased in out Generation_Control;
   Result  : out Generation_Result) is
begin
   case Id is
      when Database => Database_Generation.Run (Tree, Control, Result);
      when Cache    => Cache_Generation.Run (Tree, Control, Result);
      when API      => API_Generation.Run (Tree, Control, Result);
   end case;
end Run_One_Generation;
```

No callback or controlled assignment runs inside a protected action. Protected
state only validates and commits fixed scalars, copies into already-owned fixed
buffers, and opens entries. A manager takes a scalar work plan, releases the
lock, invokes the typed operation, then commits the reported result in another
protected call.

### Alternatives rejected

- A tagged limited child interface makes heterogeneous registration concise,
  but storing class-wide access values from a local scope creates difficult
  accessibility and lifetime contracts. `Unchecked_Access` would turn the
  central structured guarantee into convention.
- Access-to-task factories make restart construction direct, but a
  library-level access type gives allocated tasks a collection master wider
  than the supervisor. Explicit joins can compensate operationally, but the
  local task-generation generic above lets Ada enforce the master directly.
- A controlled child handle is still useful for user-facing lookup and
  finalization, but it is not sufficient ownership by itself. The task master
  and synchronous `Run` scope remain authoritative.
- `System.Address` factories and untyped payload records are unnecessary and
  are excluded.

### Dynamic families and nested supervisors

Homogeneous dynamic children use a separate generic family:

```ada
generic
   type Request is private;
   type Application_Context (<>) is limited private;
   with procedure Run_One_Generation
     (State   : aliased in out Application_Context;
      Input   : Request;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result);
   Policy           : Child_Specification;
   First_Child_Id   : Child_Id;
   Maximum_Children : Positive;
package Flyology.Supervision.Families is
   type Family is limited private;
   procedure Start
     (Item   : in out Family;
      Input  : Request;
      Handle : out Child_Handle);
   procedure Stop
     (Item : in out Family; Handle : Child_Handle);
end Flyology.Supervision.Families;
```

Its generation factory normally comes from
`Flyology.Supervision.Input_Task_Generations`. That generic accepts an
application task type plus a build-in-place constructor receiving context,
immutable request, and generation control. It makes a stable request copy
before task construction and keeps the copy alive through task join. The task
type may choose any discriminants; the family remains homogeneous because each
slot uses that same constructor and task type. Each admitted slot supplies a
different typed request and receives a distinct logical id and generation.

The family has fixed slot and event capacity. Input is copied before admission
is committed, following `Task_Scopes.Spawn`. An outstanding reservation counts
against the structured join condition. If shutdown closes admission during the
copy, commit fails and the caller rolls the slot back before `Run` may return.
Slot reuse advances the generation and clears the prior occupant's restart
account, backoff, readiness timestamps, termination, and incident observation;
all commands and completions require an exact `(Child_Id, Generation)` match.
Its common policy accepts `Isolate_Child` or `Escalate`. Cohort and dependency
relations describe heterogeneous topology and therefore belong to a containing
static node rather than being inferred among otherwise independent family slots.
Lazily allocated slot managers are stopped and joined on normal and exceptional
exit, then their task-object storage is reclaimed only after termination is
observable.
Dynamic specifications do not silently survive reconstruction of their owning
supervisor; an application that wants persistence must keep and replay typed
requests outside the node. The application must treat every reconstructed
family as a new incarnation with new controller authority. Old handles remain
stale even when replay assigns the same slot id and generation value. A
restart-safe owner reconciles durable state, admits the current desired
requests, publishes only the new handles, and reports readiness after the
required family children become ready.

A nested supervisor is a child factory whose one generation runs another
synchronous supervisor scope. The inner scope completes shutdown and joins
before its outer generation reaches terminal publication. It receives the same
incident id and active attempt when escalating; it cannot mint an independent retry
allowance for that cascade. `Run_Nested` observes the parent generation's
cancellation token and begins ordinary nested shutdown when the parent stops.
The parent stop does not preserve the nested controller or replay its topology.

## Startup, readiness, and rollback

Configuration validates before any task starts:

1. child ids are unique and within fixed capacity;
2. every dependency and cohort member exists;
3. dependency edges are acyclic;
4. deterministic start order is the lowest-id topological order;
5. all delay values are nonnegative, the initial backoff does not exceed its
   cap, and burst/total bounds are nonzero;
6. a nested node has an unbounded structural join even if its diagnostic stop
   deadline is finite; and
7. the control plane names one exact shared execution group, and supervised
   lightweight children cannot use that reserved group.

Startup follows topological order. For each child the manager creates a new
generation, records `Starting`, and waits for either `Mark_Ready`, termination,
or the absolute readiness deadline. Activation alone is not readiness. The
child calls `Mark_Ready` only after it owns and has validated all resources it
will publish. The manager records `Ready`; publication changes it to `Running`
only when every declared prerequisite is still ready at the expected
generation.

If activation, readiness, or publication fails, no later child starts. Already
started children are stopped in reverse topological order. The original failure
is retained; rollback failures are bounded secondary events and may strengthen
the outcome to `Stuck`, but do not replace the causal record. `Run` does not
return from failed startup until every terminable generation joins.

## Identity and lifecycle

`Child_Id` is a nonzero 64-bit logical identity. The application enumeration
fixes actual static storage and manager count for each instantiation, so
capacity remains explicit and bounded.
`Generation` is a nonzero process-local counter advanced for each construction
attempt. A process-local nonwrapping controller identity distinguishes two
supervisor objects that happen to issue the same child id and generation.
`Ada.Task_Identification.Task_Id` identifies the actual task object
while the implementation retains that identity and is diagnostic only; an Ada
runtime may reuse its representation after the old task object leaves scope.
It is never used as the logical id and is never applied to a replacement.

Every authoritative `Child_Handle` contains controller identity, child id, and
generation. Protected state accepts it only if all three match the current
slot. A handle issued by another controller is therefore stale even when its
visible child and generation values match. A late termination, timeout,
cancellation, manual restart, or health report from generation N cannot stop or
publish generation N+1. Controller, generation, and incident identities never
wrap; each source fails closed at exhaustion. Controller identity zero is
reserved as invalid authority, so a default-constructed handle cannot match the
first live controller.

`Stop` is authority over one live generation, not over a logical slot. Once a
generation terminates, its handle cannot cancel an admitted replacement even
while the slot still reports the old generation during backoff.

`Service_Slots` applies the same rule to typed service availability. One
fixed-capacity directory entry stores only a service enumeration and exact
controller-qualified handle, never an application payload or access-to-task
value. A controlled `Publication` uses an access discriminant so Ada
accessibility rules require its directory to outlive it. It revokes only its
own exact token during normal, exceptional, or abort finalization. Clients
acquire a copyable lease;
the application endpoint validates that lease inside the same protected
operation that uses the endpoint. Publishing the replacement after readiness
invalidates every old lease without extending the old task or resource
lifetime.

Legal scalar transitions are:

```text
Configured -> Starting -> Ready -> Running
                    |        |        |
                    +--------+--------+-> Stopping -> Terminated
                    +--------------------> Terminated

Terminated -> Backing_Off -> Restarting -> Starting
          |              \-> Joined  (shutdown cancels pending construction)
          \-> Restarting
          \-> Failed_Escalated
          \-> Joined

Failed_Escalated -> Stopping -> Terminated -> Joined
Failed_Escalated ----------------------------> Joined  (only with no live task)
```

`Ready` is the policy-visible handshake state. A controller may publish
readiness atomically as `Starting -> Running`; that transition means the same
handshake completed, not that activation alone established usability.

`Stuck` is a termination classification, not a false claim that the task
terminated. The logical state remains `Stopping` or `Failed_Escalated` with a
live-generation flag until `Is_Terminated` and the task master confirm the
join. `Joined` means no task can publish again and all generation-owned
resources finalized. The fixed event ring remains owned by the supervisor so
an observer can drain the terminal sequence after `Run` returns.

The old task object can leave scope only after its outer body has returned,
all task-body locals and dependent tasks have finalized/joined, and its local
master completes. A replacement is constructed afterward. Runtime fiber-record
reaping is GNARL/Flyology machinery and is not a supervisor resource-reclamation
signal.

### Monitoring and failure coupling

Task observation and supervisor observation use different identities. A
`Flyology.Task_Results.Monitor` is attached while one concrete Ada `Task_Id` is
valid and retains only that task's fixed terminal sidecar. It remains useful
after the task object is reclaimed, but it is passive and has no restart or
cancellation effect.

The controllers instead expose `Latest` and `Wait_Termination` over an exact
`Child_Handle`. Registration and current-generation validation are one
protected action. A negative timeout waits indefinitely, zero performs an
immediate check, and a positive timeout is relative. The result is one of:

- `Generation_Terminated`, with the retained terminal snapshot for that
  generation;
- `Generation_Replaced`, with the current replacement snapshot; or
- `Observation_Timed_Out`, with no snapshot.

The wait never follows the replacement. Static and family generic
`Monitor_Capacity` values bound concurrent registrations. Each slot has a
nonwrapping token, so an aborted or unwinding waiter cannot cancel a later
registration that reused its slot. A controlled guard releases registration on
abort and exceptional exit. No callback, formatting, allocation, or finalizing
assignment occurs in the protected controller.

Failure propagation is expressed through structured owners rather than a raw
symmetric task link. `Task_Scopes` can cancel sibling operations when one fails.
A supervisor child selects isolation, a named cohort, declared dependents, or
escalation, and nested supervisors carry one incident through the hierarchy.
Those policies name ownership and restart consequences that a bare task-to-task
link cannot safely infer in shared-memory Ada. Passive task monitors and
structured failure coupling therefore remain separate orthogonal operations.

No general wait-any monitor set is included. The implemented consumers need
either one exact task result, one exact generation, or the controller's bounded
event ring. Adding publication fan-out and another registration owner without a
concrete consumer would enlarge the runtime and lifetime surface without
clarifying who owns the set or how it is bounded.

## Failure taxonomy and observation

The public bounded summary represents:

| Outcome | Source | Restart failure for `On_Failure` |
| --- | --- | --- |
| normal return | task-owned result | no |
| unhandled exception | task-owned result retains bounded name and message | yes |
| cancellation | uncaught canonical cancellation exception, normal return after a stop request, or explicit override | no |
| supervisor shutdown | manager initiated | no |
| abnormal/abort completion | task-owned result | yes |
| activation failure | allocator or local task activation raises `Tasking_Error` | yes |
| readiness timeout | monotonic deadline before `Mark_Ready` | yes |
| manual restart | exact current handle passed to `Restart` | admitted for `On_Failure` or `Always` |
| unhealthy | generation-local report or exact external failed probe | yes |
| stop timeout | cooperative grace expired | yes |
| stuck | task still live after optional abort observation | terminal; no replacement is permitted |
| policy exhaustion | restart classifier | terminal escalation |

Safe retained information is the enumeration, child id, generation, bounded
fully qualified exception name, bounded message, Ada task id for diagnostics,
and monotonic timestamps. A directly classified manager or compatibility
override may also retain the library-level exception id. Automatic task-body
observation deliberately retains the portable exception name instead of a
runtime-owned address. An `Exception_Occurrence`, pointers into the task stack,
traceback-owned transient storage, or callback context is never retained.

GNARL's existing task wrapper copies the fixed result before publishing terminal
state. `Task_Generations` waits on that task-owned sidecar while the task object
remains alive, maps it into the generation summary, and then leaves the local
master. The sidecar is attached before activation, so a task that terminates
before its allocator returns does not create a registration race. Activation
failure remains Ada's `Tasking_Error`: no task body began and no result exists.

`Ada.Task_Termination` is deliberately not used for supervision. Its
handler context would require a second constrained publication path and is not
needed for ordinary completion, escaping exceptions, or the current optional
abort observation. If a future consistency hook uses it, the handler must not
log, allocate deliberately, invoke callbacks, wait, finalize user values,
request restart, or take a runtime lock.

## Restart policy

`Never`, `On_Failure`, and `Always` define the child restart decision. Flyology
uses explicit impact rather than list-position semantics:

- `Isolate_Child` replaces only the failed logical child;
- `Restart_Cohort` stops and replaces the failed child plus a named set;
- `Restart_Dependents` follows reverse dependency edges transitively;
- `Escalate` performs no local replacement.

Affected running children stop in reverse topological order. After every old
generation joins, replacements start in topological order and must become ready
before their dependents are published. A child's restart kind classifies its
own termination. Once another child's incident selects it as a cohort member
or dependent, the coordinated transaction reconstructs it and therefore
requires `Restart_Safe`.

`Restart` and `Report_Unhealthy` are exact-generation commands. They are
accepted only for a live ready generation owned by that controller. Manual
restart additionally requires a restart-safe local impact and a policy other
than `Never`; an `Escalate` child has no local replacement to request. A stop,
shutdown, terminal escalation, or earlier intervention that linearizes first
closes this command gate.
Generation-local code may call `Report_Unhealthy (Control, Diagnostic)`; the
diagnostic is copied before its cancellation source is requested. External
health tasks use the controller operation with the exact handle returned by
`Latest`. Both paths run the configured stop, impact, budget, backoff, and
readiness transaction. Manual operation is not an unmetered escape hatch: its
replacement consumes the same child and subtree incident attempt as automatic
recovery.

Each node has fixed per-child and subtree accounts:

- maximum attempts in a monotonic sliding window;
- maximum total attempts in one recovery incident;
- capped exponential backoff;
- a ready stability interval that closes the incident and resets its attempt
  state; and
- an absolute recovery deadline inherited by descendants.

One failure creates an `Incident_Id`. `Begin_Attempt` increments the shared
attempt ordinal exactly once. The active `(Incident_Id, Attempt)` is passed into
every cohort member and nested supervisor. Each node records that pair at most
once; escalation forwards it while still active and cannot turn it into a new
attempt. A later retry ends the old attempt and begins the next ordinal under
the same incident. Thus a hierarchy may impose stricter local limits, but it
cannot multiply an attempt allowance merely by crossing supervisor levels.
After the child and subtree stability intervals both elapse, the generation
control closes its inherited incident. A later failure therefore receives a
fresh id, attempt 1, and absolute deadline. If a nested supervisor reports an
escalation during that generation, the reported context is retained instead
of being cleared by the outer stability observation.

The decision order is deterministic: total limit, current-window limit,
deadline fit for the computed delay, then admission. Exhaustion records the
failed limit, stops locally owned children in reverse order, and escalates the
same incident. At the root there is no parent budget to consume. The
application owner receives `Recovery_Exhausted`, `Failure_Escalated`,
`Startup_Failed`, or `Shutdown_Completed` exactly once from the one-shot `Run`
call after every terminable child joins. It consumes that result by choosing
the process exit status, degraded mode, or an explicitly fresh application
scope; it must not feed the incident back into the same exhausted root. A stuck
child prevents `Run` from returning and remains observable through snapshots.

## Stopping and resource safety

Stopping has four observable phases:

1. close publication/admission and request the generation's fresh cancellation
   token;
2. wait through the monotonic grace deadline;
3. if configured, issue an Ada abort request and observe for another bounded
   diagnostic interval; and
4. if the task is still live, report `Stuck` and do not construct a replacement.

The deadlines bound supervisor waiting decisions, not task termination. Abort
can be deferred in protected actions, rendezvous, finalization, and other Ada
abort-deferred regions. A native task can remain inside an uninterruptible
foreign call. A lightweight task that never suspends can monopolize its group
and never observe cancellation or abort.

Every generation reacquires resources from its typed initialization path:

- sockets and descriptors start as closed limited owners and are opened or
  adopted anew;
- connection generations and wait registrations are new;
- unique buffers are returned before join and reacquired from their pool;
- dedicated execution groups are requested anew because leaving one consumes
  its reservation;
- thread pins are lexical task-owned objects and never cross generations;
- capacity permits and channel slots are released or drained before restart;
- TLS provider sessions and borrowed descriptors are destroyed before the
  connection owner closes; and
- no pointer, access-to-local value, entry reference, or protected guard from
  the old task is published to the replacement.

The child specification includes a `Restart_Safe` acknowledgement. It is not a
proof: documentation and review must state which shared objects can survive a
partial operation, how external effects are made idempotent or reconciled, and
which resources are generation-owned. A child without this acknowledgement can
use `Never` or `Escalate`, not local automatic restart.

A nominal marker type cannot prove this property either: Ada tasks can reach
shared state, foreign libraries, and external systems outside the type. The
stronger implemented boundary is structural and reviewable instead:

- `Create` constructs a fresh limited task or structured service object under
  the generation's local master;
- controlled generation-owned resources finalize before terminal publication;
- a resource-reacquisition semantic test rejects overlapping ownership between
  old and replacement generations;
- `Service_Slots.Publication` withdraws the exact old lease during unwinding;
  and
- the application records reconciliation and idempotence rules next to the
  child policy that sets `Restart_Safe => True`.

For a generation that owns a dynamic family, those rules must identify the
application-owned desired request set, the idempotent persistence operation,
the publication cutover to new controller-qualified handles, and the readiness
condition after replay. A family admission is current controller state, not a
durable declaration of intent.

This deliberately leaves the Boolean as an explicit application assertion
rather than replacing it with a marker interface that would imply a guarantee
the Ada type system cannot establish.

### Structured service adapters

`Flyology.Supervision.Adapters` accepts an application-defined limited service
type plus build-in-place `Create`, blocking `Run_Service`, idempotent
`Request_Shutdown`, and `Ready` operations. It constructs a fresh service for
each generation. A dependent service-owner task executes the blocking call
while the supervisor's generation runner observes readiness and forwards
cooperative stop. This owner task is intentional: it permits concurrent shutdown without
changing one-shot APIs such as `Worker_Pools.Run`,
`IO.Structured_Servers.Serve`, or an application listener loop.

The adapter retains the service owner's actual `Task_Id` and translates its
automatic task result directly. Normal return, the original escaping exception
name and message, and abnormal completion therefore keep their classifications;
they are not replaced by an adapter wrapper exception. Failure to activate the
service propagates `Tasking_Error` to the controller's activation-failure path.

The application supplies a constrained service subtype or discriminated
build-in-place result and keeps resource acquisition inside `Create` or
`Run_Service`. For a worker pool, `Ready` reads `Pool.Current.Running` and
shutdown calls `Pool.Request_Shutdown`. For a structured server, `Run_Service`
acquires a new listening socket and transfers it to `Serve`, `Ready` reads
`Server.Current.Running`, and shutdown calls `Server.Request_Shutdown`. A bare
listener loop uses the same contract. The adapter does not reuse a one-shot
pool, server, or listener and does not turn their callback failures into safe
restarts; the child policy still needs the application restart-safety review.

### Root ownership

The canonical root is owned by the environment task's application scope. That
scope declares the root context and one-shot supervisor and calls synchronous
`Run` directly. A dependent shutdown-watcher task translates process shutdown
notification into `Request_Shutdown`. A low-level signal handler must only wake
that task through a signal-safe application mechanism; it must not call the
supervisor or format events directly. When `Run` returns for any reason, the
environment task cancels and joins the watcher before leaving the scope.

The environment task consumes `Supervisor_Result` before finalizing application
context. `Shutdown_Completed` is the expected
operator shutdown. `Startup_Failed`, `Recovery_Exhausted`, and
`Failure_Escalated` normally map to a failing application exit so an external
service manager may decide whether to start a fresh process. `Child_Stuck` is
observable while shutdown remains blocked, but synchronous `Run` cannot return
it until the dependent task eventually terminates. An application that elects
in-process root reconstruction must create a fresh context, resource set,
supervisor object, and service publications in a new nested Ada scope; it does
not reuse the old controller or incident.

The specification reuses Flyology's existing task vocabulary through
`Task_Model : Flyology.Execution_Model`. A controller accepts only the stable
`Flyology.Lightweight_Task` and `Flyology.Native_Task` constants. It rejects
`Project_Default` and foreign `Task_Info` values because it cannot resolve them
to an unambiguous model for group validation or bounded observations. This is
configuration metadata; the application task's `Task_Info` and `CPU` aspects
remain authoritative and must agree with it.

## Control-plane placement

A failed lightweight child must not starve its manager on the same cooperative
group. `Flyology.Supervision.Static` defaults its manager and generation-owner
fibers to shared group 127. Applications must keep that group outside the
automatic pool and must not assign it to a supervised child. Explicit child
group equality is rejected during validation. All supervisor instances can
share that group, so this costs one event-loop pthread per process when first
used, not one pthread per supervisor. Managers run only bounded policy steps.
`Run_One_Generation`, `Initialize`, identity, and abort adapters must also be
bounded or suspend promptly; the service loop and task cleanup run in the
application task's declared execution model and group.

This is initially an application/runtime-configuration contract. An unrelated
task could still explicitly select the reserved group. If experience shows that
configuration discipline is insufficient, a small group-reservation operation
in the topology layer may be justified. No scheduler or GNARL change is needed
for the task lifecycle itself.

## Observability

Both controllers own one fixed snapshot per logical child, a generic-sized
event ring, and a generic-sized exact-generation monitor table. Each event
copies a monotonic sequence and timestamp, logical id,
generation, state before and after, configured task model and group, termination
kind, incident and attempt context, and admitted backoff. The snapshot retains
the bounded termination summary, diagnostic Ada task id, readiness/live flags,
attempt total, last backoff, and escalation flag.

When the ring is full, the oldest event is overwritten. `Read_Events` copies
available events in sequence order, advances a caller-owned cursor, and reports
the exact overwritten sequence gap as `Dropped`. Protected actions only copy
fixed data. They do not log or invoke callbacks; an observer formats copied
events later. The pure policy kernel independently models transition legality,
ordering, affected sets, restart accounting, hierarchical incident
observation, generation matching, repeated-attempt classification, and the
dynamic-family join condition. Contracts prove exact isolate and cohort sets;
they also prove that dependent recovery contains the failed child, excludes
unconfigured ids, and is closed under every configured dependency edge. The
lowest-id tie-break and exact minimal dependent set remain executable model
assertions. The production controllers consume proved generation matching for
every generation-qualified publication and command, plus retained-event
transition, repeated-attempt, dynamic-family admission, exact-generation stop,
and structured-join decisions. Family admission is derived from configured,
shutdown, and terminal state, so no independently mutable open flag can diverge
from shutdown. Task construction, protected state, and resource reclamation
remain outside SPARK.

## Worked example: independent restartable service

The listener is acquired inside each generation; it is never inherited from a
failed server object. The application declares the task type and its entry.

```ada
type Service_Id is (Metrics);

type Metrics_State is limited record
   Address : Flyology.IO.Sockets.Endpoint;
   --  Shared counters are protected and explicitly survive generations.
   Counters : Metrics_Counters;
end record;

task type Metrics_Task
  (State   : not null access Metrics_State;
   Control : not null access Generation_Control)
with CPU => 2 is
   pragma Task_Info (Flyology.Lightweight_Task);
   entry Configure;
end Metrics_Task;

task body Metrics_Task is
begin
   accept Configure;
   declare
      Listener : Flyology.IO.Sockets.Socket_Type;
      Server   : aliased HTTP.Server (Capacity => 32);
   begin
      Bind_Listener (State.Address, Listener);
      Mark_Ready (Control.all); --  Bound and owned by this generation.
      HTTP.Serve (Server, Listener, State.Counters, Drain_Timeout => 2.0);
   end; --  Cleanup completes before GNARL publishes the terminal result.
end Metrics_Task;

procedure Initialize
  (Subject : in out Metrics_Task;
   Control : aliased in out Generation_Control) is
   pragma Unreferenced (Control);
begin
   Subject.Configure; --  A task-specific rendezvous outside controller locks.
end Initialize;

function Task_Identity
  (Subject : in out Metrics_Task) return Ada.Task_Identification.Task_Id is
  (Subject'Identity);

procedure Abort_Task (Subject : in out Metrics_Task) is
begin
   abort Subject;
end Abort_Task;

function Create
  (State   : not null access Metrics_State;
   Control : not null access Generation_Control) return Metrics_Task
is
begin
   return Subject : Metrics_Task (State, Control);
end Create;

package Metrics_Generation is new Flyology.Supervision.Task_Generations
  (Application_Context => Metrics_State,
   Generation_Task     => Metrics_Task,
   --  Create, Task_Identity, and Abort_Task are inferred by name.
   Initialize          => Initialize);

function Specification (Id : Service_Id) return Child_Specification is
  (Restart    => On_Failure,
   Impact     => Isolate_Child,
   Restart_Safe => True,
   Readiness_Timeout => Ada.Real_Time.Seconds (2),
   Stopping   => (Grace => Ada.Real_Time.Seconds (2),
                  Request_Abort => False,
                  Abort_Observation => Ada.Real_Time.Time_Span_Zero),
   Recovery   => Metrics_Recovery_Limits,
   Task_Model => Flyology.Lightweight_Task,
   Has_Group  => True,
   Group      => 2,
   others     => <>);
```

The static topology's exhaustive `Run_One_Generation` dispatcher calls
`Metrics_Generation.Run`. `Children` can express the same lifecycle with less
code when an application does not need its own task declaration.

An unhandled parsing exception closes the server scope, joins all handlers, and
closes the listener. Only then can a new `Metrics` generation bind a new
listener. Bind failure or readiness timeout consumes another attempt. A CPU
loop that ignores cancellation can become `Stuck`; no replacement binds the
same address while it remains live.

## Worked example: dependent cohort subtree

This example specifies both coordinated recovery relations through typed
generic functions.

```ada
type Service_Id is (Database, Cache, API, Telemetry);

function Depends_On
  (Child, Prerequisite : Service_Id) return Boolean is
  ((Child = Cache and then Prerequisite = Database)
   or else
   (Child = API and then Prerequisite in Database | Cache));

function Cohort_Member
  (Trigger, Member : Service_Id) return Boolean is
  (Trigger = Member
   or else (Trigger = Cache and then Member = API));

function Specification
  (Child : Service_Id) return Child_Specification is
  (Restart      => On_Failure,
   Impact       =>
     (case Child is
        when Database  => Restart_Dependents,
        when Cache     => Restart_Cohort,
        when API       => Isolate_Child,
        when Telemetry => Isolate_Child),
   Restart_Safe => True,
   others       => <>);
```

The deterministic start order is `Database`, `Cache`, `API`, `Telemetry`.
Normal shutdown reverses it. If `Database` fails, the affected dependent
closure is `Database`, `Cache`, and `API`; `Telemetry` continues. The node stops
`API`, then `Cache`, waits for the failed database generation to join, and
starts `Database`, `Cache`, then `API`, gating each dependent on the exact ready
generation. If `Cache` fails, its named cohort stops `API` then `Cache` and
restarts them in the opposite order. If cleanup of the old cache is stuck, the
API is not republished and no cache replacement is created.

A nested storage supervisor can replace `Database` as one child. Escalation
from its connection-pool child carries the same incident and attempt into this
node. The parent may broaden impact to the declared dependents, but does not
reset total attempts or the absolute recovery deadline.

## Test boundary

The checked-in policy-model smoke test covers:

- deterministic dependency order, reverse stop order, and cycle rejection;
- dependent closure, named cohort, and escalation sets;
- representative legal and illegal lifecycle transitions;
- restart-kind classification;
- burst, total, backoff, deadline, and stability-reset accounting;
- one hierarchical incident attempt observed once per node; and
- stale generation rejection and fail-closed generation/incident exhaustion.

The checked-in task-generation and live static-supervisor smoke tests
additionally cover:

- application-defined native task types with application entries;
- normal return, copied exception identity, cooperative shutdown, abort
  observation, task-body finalization, and typed immutable input;
- task-specific initialization failure without misclassifying it as activation
  failure;
- logical ids above both 32-bit and 16-bit ranges;
- an unhandled exception followed by independent automatic restart;
- fresh generation controls and non-null Ada task identities;
- explicit readiness before publication;
- dependency-ordered startup and reverse-order shutdown;
- dependent and named-cohort stop/restart ordering;
- nested escalation retaining one incident attempt;
- bounded event copying;
- injected generation-factory activation failure classification;
- readiness timeout with cooperative cancellation;
- explicit shutdown and complete structured join; and
- an uncooperative child observed as `Stuck` before it later returns and joins.

The dynamic-family smoke test constructs its application-defined input task
type through `Input_Task_Generations` and covers a logical id above 32 bits,
typed admission, automatic and manual restart, failed health probes, native-task
cancellation, nonoverlapping generation-owned resource acquisition,
fixed-slot reuse with fresh recovery accounting, stale-handle rejection,
explicit shutdown, and bounded event overwrite reporting. The service-slot
test covers duplicate publication, replacement leases, controller identity,
controlled finalization, and abort cleanup. The structured adapter test covers
readiness, generation-local health failure, stop forwarding, join, exact task
identity, original exception diagnostics, abnormal completion, and activation
failure. Separate regressions reject default handle authority and prove that
family shutdown cancels backoff without invoking another generation factory.
The nested-family owner regression restarts a static dependent, forwards the
parent stop into its family, rejects the old family handle, reconciles persistent
state idempotently, and admits every desired request into the new incarnation
before the replacement owner reports readiness. A separate nested-static
regression proves that a parent stop shuts down and joins a healthy inner static
node without an application stop bridge.
The family controller test also orders stop and shutdown before manual restart
and failed-health commands, then requires every later intervention to be
rejected even while the affected Ada task has not yet completed. The policy
kernel proves the Boolean authorization rule; the live test confirms that the
protected controller takes its decision from the same state atomically.
Procedure-body compatibility adapters are also exercised by the remaining
static child cases.

Additional semantic hardening is still useful for:

1. normal return under each restart kind in a live controller;
2. abort deferred through application finalization;
3. scope exit or caller abort without explicit shutdown;
4. a lightweight child monopolizing its non-control group;
5. a native child stuck in an isolated foreign-call subprocess;
6. exact socket/buffer/dedicated-group/thread-pin reacquisition beyond the
   generic nonoverlap guard; and
7. no callback, allocation, log formatting, or finalizing assignment while a
    protected action executes.

The uncooperative cases must run in subprocesses with timeouts. A passing test
observes `Stuck`; it must not wait forever or claim the task was killed.

## Staged implementation

1. **Policy and vocabulary (implemented).** Public bounded values, states,
   failure classifications, generation controls, and the proved scalar kernel.
2. **Structured generation and independent supervisor (implemented).**
   Application-defined task types, procedure-body compatibility adapters,
   readiness, cancellation, optional abort, generation-safe snapshots, bounded
   independent restart, synchronous join, and typed terminal results.
3. **Static DAG (implemented).** Heterogeneous dispatch, deterministic
   validation and ordering, coordinated cohorts/dependents, child and subtree
   accounts, nested incidents, and a fixed event ring.
4. **Homogeneous dynamic family (implemented).** Fixed linear slots, typed
   input copying, persistent bounded managers, generation-qualified handles,
   nested incidents, deterministic shutdown, and a fixed event ring.
5. **Generation authority and publication (implemented).** Controller-qualified
   handles, bounded typed service leases, exact manual restart, and failed
   health-probe recovery.
6. **Integration adapters (implemented).** One opt-in structured blocking
   service factory for worker pools, servers, and listener loops without
   changing their existing contracts.
7. **Remaining semantic hardening.** Add subprocess tests for caller abort,
   true foreign-call stalls, lightweight group monopolization, and concrete
   socket/buffer/dedicated-group/thread-pin reacquisition.

The current production slice supports independent restart-safe services,
coordinated static trees, nested escalation, and homogeneous dynamic families.
The remaining work is platform-isolated stall and concrete resource campaigns,
not an alternate tasking or scheduler layer.
