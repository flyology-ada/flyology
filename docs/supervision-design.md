# Ada-native structured supervision

Status: implemented production API slice under semantic review.

This design adds fault-management policy above ordinary Ada tasking. It keeps
Ada task activation, masters, dependent-task joining, rendezvous, protected
objects, exception propagation, abort deferral, controlled finalization, and
task identity authoritative. It does not isolate shared memory or change GNARL
task semantics.

The checked-in implementation consists of the public vocabulary and
generation control in `Flyology.Supervision`, the lane-selectable structured
task runners in `Flyology.Supervision.Children` and
`Flyology.Supervision.Input_Children`, the heterogeneous static controller in
`Flyology.Supervision.Static`, the homogeneous fixed-capacity controller in
`Flyology.Supervision.Families`, and the SPARK policy kernel in
`Flyology.Supervision_Policy`. Static recovery supports isolated children,
named cohorts, transitive dependents, subtree budgets, nested incident
propagation, and bounded event rings. Dynamic families provide typed request
copying, fixed linear slots, generation-safe reuse, nested incident
propagation, and bounded event rings.

## Goals and non-goals

The primitive should provide:

- typed static topology and typed homogeneous dynamic families;
- stable logical child ids distinct from generation and Ada task identity;
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
| `Flyology.Worker_Pools` | activation gate, dependent task scope, first bounded failure, cleanup guards | factor common bounded diagnostic-copy helpers later if worthwhile | queue draining is not child restart |
| `Flyology.Capacity` | bounded admission and drain when a child owns concurrent work | no supervisor-specific behavior belongs in the gate | permits never transfer implicitly to a replacement |
| `Flyology.IO.Structured_Servers` | reverse cleanup, exact listener ownership, cancel/drain phases, activation rollback | a future server factory can be supervised as one logical child | `Server` remains one-shot; restart creates a new server and listener |
| `Flyology.Observability` | actual lightweight group and sampled stall evidence | supervision snapshots are an application layer, not a runtime ABI extension | scheduler counters do not determine restart policy |
| scheduler create/destroy/reap | evidence that a finished fiber is reaped only after GNARL destroys its task object, with running/migrating destruction deferred | none for the first implementation | supervision remains above GNARL |

The scheduler already distinguishes a task wrapper returning from the later
fiber-record reap. A supervisor must wait for the Ada task master and task-body
finalization, not infer resource reclamation from a scheduler snapshot. No
runtime hook is needed to observe a generation: the generation's outer body
wrapper reports a bounded terminal value, and the containing Ada master is the
join boundary.

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
      Parent  : in out Generation_Control;
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

Each child kind normally instantiates `Flyology.Supervision.Children` with its
exact context, callback, task designation, CPU, and resource types. `Run`
declares the actual generation task in a local block. Its outer body wrapper
catches and copies failure information; the block's master joins the task
before the operation returns. Re-entering `Run` creates a new task object under
a new local master without an access-to-task allocation or detached collection
master.

The application topology dispatch is an exhaustive case over its enumeration:

```ada
procedure Run_One_Generation
  (Tree    : aliased in out Service_Topology;
   Id      : Service_Id;
   Control : aliased in out Generation_Control;
   Result  : out Generation_Result) is
begin
   case Id is
      when Database => Database_Child.Run (Tree, Control, Result);
      when Cache    => Cache_Child.Run (Tree, Control, Result);
      when API      => API_Child.Run (Tree, Control, Result);
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
  local-generation procedure above lets Ada enforce the master directly.
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

The family has fixed slot and event capacity. Input is copied before admission
is committed, following `Task_Scopes.Spawn`. Slot reuse advances the generation;
all commands and completions require an exact `(Child_Id, Generation)` match.
Its common policy accepts `Isolate_Child` or `Escalate`. Cohort and dependency
relations describe heterogeneous topology and therefore belong to a containing
static node rather than being inferred among otherwise independent family slots.
Lazily allocated slot managers are stopped and joined on normal and exceptional
exit, then their task-object storage is reclaimed only after termination is
observable.
Dynamic specifications do not silently survive reconstruction of their owning
supervisor; an application that wants persistence must keep and replay typed
requests outside the node.

A nested supervisor is a child factory whose one generation runs another
synchronous supervisor scope. The inner scope completes shutdown and joins
before its outer generation reports termination. It receives the same incident
id and active attempt when escalating; it cannot mint an independent retry
allowance for that cascade.

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
7. supervised lightweight children cannot use the reserved control group.

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

`Child_Id` is a nonzero 64-bit logical identity and does not impose a 65,535
child ceiling. The application enumeration fixes actual static storage and
manager count for each instantiation, so capacity remains explicit and bounded.
`Generation` is a nonzero process-local counter advanced for each construction
attempt. `Ada.Task_Identification.Task_Id` identifies the actual task object
while the implementation retains that identity and is diagnostic only; an Ada
runtime may reuse its representation after the old task object leaves scope.
It is never used as the logical id and is never applied to a replacement.

Every command, readiness report, termination report, and event contains child
id and generation. Protected state accepts it only if both match the current
slot. A late termination handler, timeout, or cancellation event from generation
N therefore cannot stop or publish generation N+1. Generation wrap reserves
zero and is observable. The policy kernel models nonzero wrap, while each live
controller fails closed at generation exhaustion instead of reusing a live
supervisor's generation value.

Legal scalar transitions are:

```text
Configured -> Starting -> Ready -> Running
                    |        |        |
                    +--------+--------+-> Stopping -> Terminated
                    +--------------------> Terminated

Terminated -> Backing_Off -> Restarting -> Starting
          \-> Restarting
          \-> Failed_Escalated
          \-> Joined

Failed_Escalated -> Stopping -> Terminated -> Joined
Failed_Escalated ----------------------------> Joined  (only with no live task)
```

`Stuck` is a termination classification, not a false claim that the task
terminated. The logical state remains `Stopping` or `Failed_Escalated` with a
live-generation flag until `Is_Terminated` and the task master confirm the
join. `Joined` means no task can publish again and all generation-owned
resources finalized. The fixed event ring remains owned by the supervisor so
an observer can drain the terminal sequence after `Run` returns.

The old task object can leave scope only after its outer wrapper has returned,
all task-body locals and dependent tasks have finalized/joined, and its local
master completes. A replacement is constructed afterward. Runtime fiber-record
reaping is GNARL/Flyology machinery and is not a supervisor resource-reclamation
signal.

## Failure taxonomy and observation

The public bounded summary represents:

| Outcome | Source | Restart failure for `On_Failure` |
| --- | --- | --- |
| normal return | outer body wrapper | no |
| unhandled exception | wrapper catches `others` | yes |
| cancellation | canonical cancellation exception | no, unless policy maps an application cancellation to failure before reporting |
| supervisor shutdown | manager initiated | no |
| abnormal/abort completion | wrapper/termination observation | yes |
| activation failure | allocator or local task activation raises `Tasking_Error` | yes |
| readiness timeout | monotonic deadline before `Mark_Ready` | yes |
| stop timeout | cooperative grace expired | yes |
| stuck | task still live after optional abort observation | terminal; no replacement is permitted |
| policy exhaustion | restart classifier | terminal escalation |

Safe retained information is the enumeration, child id, generation, copied
exception identity, bounded message or exception information, Ada task id for
diagnostics, and monotonic timestamps. An `Exception_Occurrence`, pointers into
the task stack, traceback-owned transient storage, or callback context is not
retained.

The primary mechanism is the outer task-body wrapper because it runs in a known
task context and can classify application exceptions. The runner retrieves the
bounded result through a rendezvous, then explicitly observes task termination
before leaving the local master. This avoids retaining an exception occurrence
or finalizing shared completion state before task teardown finishes.

`Ada.Task_Termination` is deliberately not used by this implementation. Its
handler context would require a second constrained publication path and is not
needed for ordinary completion, handled exceptions, or the current optional
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

The decision order is deterministic: total limit, current-window limit,
deadline fit for the computed delay, then admission. Exhaustion records the
failed limit, stops locally owned children in reverse order, and escalates the
same incident. At the root, exhaustion leaves the node `Failed_Escalated`; the
owner of `Run` receives a typed terminal result after all terminable children
join. A stuck child prevents that return and remains observable.

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

## Control-plane placement

A failed lightweight child must not starve its manager on the same cooperative
group. `Flyology.Supervision.Static` defaults its manager and factory-runner
fibers to shared group 127. Applications must keep that group outside the
automatic pool and must not assign it to a supervised child. Explicit child
group equality is rejected during validation. All supervisor instances can
share that group, so this costs one event-loop pthread per process when first
used, not one pthread per supervisor. Managers run only bounded policy steps;
user callbacks and child cleanup run in the configured generation task.

This is initially an application/runtime-configuration contract. An unrelated
task could still explicitly select the reserved group. If experience shows that
configuration discipline is insufficient, a small group-reservation operation
in the topology layer may be justified. No scheduler or GNARL change is needed
for the task lifecycle itself.

## Observability

Both controllers own one fixed snapshot per logical child and a generic-sized
event ring. Each event copies a monotonic sequence and timestamp, logical id,
generation, state before and after, configured lane and group, termination
kind, incident and attempt context, and admitted backoff. The snapshot retains
the bounded termination summary, diagnostic Ada task id, readiness/live flags,
attempt total, last backoff, and escalation flag.

When the ring is full, the oldest event is overwritten. `Read_Events` copies
available events in sequence order, advances a caller-owned cursor, and reports
the exact overwritten sequence gap as `Dropped`. Protected actions only copy
fixed data. They do not log or invoke callbacks; an observer formats copied
events later. The pure policy kernel independently models transition legality,
ordering, affected sets, restart accounting, hierarchical incident
observation, and generation matching.

## Worked example: independent restartable service

The listener is acquired inside each generation; it is never inherited from a
failed server object. This uses the checked-in child runner API.

```ada
type Service_Id is (Metrics);

type Metrics_State is limited record
   Address : Flyology.IO.Sockets.Endpoint;
   --  Shared counters are protected and explicitly survive generations.
   Counters : Metrics_Counters;
end record;

procedure Serve_Metrics
  (State   : in out Metrics_State;
   Control : not null access Generation_Control) is
   Listener : Flyology.IO.Sockets.Socket_Type;
   Server   : aliased HTTP.Server (Capacity => 32);
begin
   Bind_Listener (State.Address, Listener);
   Mark_Ready (Control.all); --  Bound and owned by this generation.
   HTTP.Serve (Server, Listener, State.Counters, Drain_Timeout => 2.0);
end Serve_Metrics;

package Metrics_Child is new Flyology.Supervision.Children
  (Application_Context => Metrics_State,
   Execute             => Serve_Metrics,
   Task_Model          => Flyology.Lightweight_Task,
   Task_CPU            => 2);

function Specification (Id : Service_Id) return Child_Specification is
  (Restart    => On_Failure,
   Impact     => Isolate_Child,
   Restart_Safe => True,
   Readiness_Timeout => Ada.Real_Time.Seconds (2),
   Stopping   => (Grace => Ada.Real_Time.Seconds (2),
                  Request_Abort => False,
                  Abort_Observation => Ada.Real_Time.Time_Span_Zero),
   Recovery   => Metrics_Recovery_Limits,
   Lane       => Lightweight_Lane,
   Has_Group  => True,
   Group      => 2,
   others     => <>);
```

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
- stale generation rejection and nonzero generation/incident wrap.

The checked-in live static-supervisor smoke test additionally covers:

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

The dynamic-family smoke test covers a logical id above 32 bits, typed
admission, automatic restart, native-task cancellation, fixed-slot reuse,
stale-handle rejection, explicit shutdown, and bounded event overwrite
reporting. The child-runner tests also exercise the completion rendezvous that
prevents local synchronization state from finalizing before Ada task teardown.

Additional semantic tests are still needed in both task lanes for:

1. normal return under `Never`, `On_Failure`, and `Always`;
2. an unhandled exception with bounded id/message retention;
3. explicit cancellation versus supervisor shutdown;
4. abort reported as abnormal and abort deferred through finalization;
5. partial startup rollback in reverse dependency order;
6. burst, total, and absolute-deadline exhaustion in the live controller;
7. scope exit or caller abort without explicit shutdown;
8. a lightweight child monopolizing its non-control group;
9. a native child stuck in an isolated foreign-call subprocess;
10. exact socket/buffer/dedicated-group/thread-pin reacquisition; and
11. no callback, allocation, log formatting, or finalizing assignment while a
    protected action executes.

The uncooperative cases must run in subprocesses with timeouts. A passing test
observes `Stuck`; it must not wait forever or claim the task was killed.

## Staged implementation

1. **Policy and vocabulary (implemented).** Public bounded values, states,
   failure classifications, generation controls, and the proved scalar kernel.
2. **Structured generation and independent supervisor (implemented).** Typed
   lane-selectable task runner, readiness, cancellation, optional abort,
   generation-safe snapshots, bounded independent restart, synchronous join,
   and typed terminal results.
3. **Static DAG (implemented).** Heterogeneous dispatch, deterministic
   validation and ordering, coordinated cohorts/dependents, child and subtree
   accounts, nested incidents, and a fixed event ring.
4. **Homogeneous dynamic family (implemented).** Fixed linear slots, typed
   input copying, persistent bounded managers, generation-qualified handles,
   nested incidents, deterministic shutdown, and a fixed event ring.
5. **Semantic hardening.** Add subprocess tests for caller abort, true foreign
   call stalls, lightweight group monopolization, and resource reacquisition.
6. **Integration adapters.** Provide opt-in factories for structured servers,
   worker pools, and other one-shot resources without changing their existing
   contracts.

The current production slice supports independent restart-safe services,
coordinated static trees, nested escalation, and homogeneous dynamic families.
The remaining work is semantic hardening and opt-in resource adapters, not an
alternate tasking or scheduler layer.
