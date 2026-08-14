# TLA+ models

These models extract four concurrency-sensitive state machines from the Ada
implementation. They are bounded, executable design reviews: TLC explores all
interleavings within each checked configuration, while the behavioral and
SPARK suites continue to cover the implementation boundaries that TLA+ does
not model.

Run them with an official
[`tla2tools.jar`](https://github.com/tlaplus/tlaplus/releases) release and a
Java runtime:

```sh
TLA2TOOLS_JAR=/path/to/tla2tools.jar ./scripts/check-tla.sh
```

The script also recognizes a standard macOS TLA+ Toolbox installation. It runs
the current safety and liveness configurations to completion. It then requires
each broken configuration to produce its named counterexample. TLC's generated
state is kept in a temporary directory.

## Extraction map

| Model action | Implemented operation or persisted field |
| --- | --- |
| `MPMCActiveAttach.ProducerClaim` | `Try_Push` CAS on `Enqueue_Address` |
| `ProducerPublish` | payload copy followed by the slot-sequence release store |
| `ConsumerClaim` | `Try_Pop` CAS on `Dequeue_Address` |
| `ConsumerRelease` | observation followed by the slot-sequence release store |
| `Attach` with `immutable-only` | current `MPMC.Attach`, which validates immutable layout only |
| `Attach` with `legacy-deep-scan` | removed active `Attach` sequence validation |
| `GuardedMapAttach.Prepare*` | `Hash_Maps.Acquire` and mutation selection |
| `Publish*Entry` / `Commit*Count` | the actual entry-state-before-count write order in `Put_Unlocked` and `Remove` |
| guarded attachment | current `Hash_Maps.Attach`: acquire, reread count, scan, release |
| legacy attachment | removed header count snapshot, non-owning guard load, and scan |
| `SegmentRegistry.StartRequest` | persisted registry-guard CAS in `Try_Find_Or_Create` |
| `ReturnExisting` / `ChooseCandidate` | exact-name scan and best-fitting removed reservation selection |
| `Reserve` | generation advance, metadata writes, and release publication of `Initializing_Slot` |
| `Publish` / `PublishFailure` | claim-stamped CAS publication after extent initialization |
| `Remove` | exact-name lookup and release store of `Removed_Slot` |
| `CrashWithGuard` / `CrashCreator` | documented abandoned guard and initialization claim outcomes |
| `SupervisionLifecycle.StartInitial` / `StartReplacement` | static `Try_Start`, generation construction, and publish-ready sequencing |
| `AffectedFor` / `BeginRecoverableFailure` | `Supervision_Policy.Affected_Children` and static `Begin_Recovery` |
| `IssueOuterStop` / `BeginRecoveryBackoff` | static reverse recovery-stop order, termination publication, join, and backoff |
| family `Reserve` / `Commit` / `Rollback` actions | the protected family admission transaction with an exact controller/generation handle |
| `FailFamilySlot` / `RestartFamilySlot` | family termination classification, join, backoff, and replacement generation |
| `OpenNestedFamily` / `CloseNestedFamily` | one-shot `Families.Run_Nested` controller owned by one outer generation |
| `ForwardParentStop` | `Run_Nested` forwarding the parent generation's stop token into family shutdown |
| `PropagateNestedEscalation` | `Run_Nested` reporting the same active incident context to its parent control |

The model action names are intentionally close to the Ada operations so that a
code review can compare the transition order directly rather than accepting a
generic queue or mutex model as a substitute.

## Checked properties

`MPMCActiveAttach` checks bounded occupancy, unique producer and consumer
claims, disjoint producer/consumer ownership, deep sequence validity whenever
the ring is quiescent, and absence of false attachment rejection. The legacy
configuration finds a two-step counterexample: a producer advances the enqueue
claim before publishing its slot sequence, and a concurrent deep-scanning
attachment rejects that valid state.

`GuardedMapAttach` checks that storage is count-consistent whenever the guard is
free, every mutation and current attachment validation owns the guard, and no
valid reachable state is reported as corrupt. The legacy configuration finds
the old race where attachment observes an unlocked guard, a mutator publishes
an occupied entry, and attachment scans before the mutator updates the count.
Modeled owner death leaves either kind of acquired guard permanently abandoned;
no transition silently steals it.

`SegmentRegistry` gives every modeled name the same hash, then checks exact-name
uniqueness, creator-claim stamping, ready/failed publication, failure codes,
extent bounds and non-overlap, generation-stamped stale handles, and permanent
abandonment of a guard after modeled owner death. Generation exhaustion is an
explicit result and releases an acquired guard. The unlocked configuration
lets two creators scan the same free slot and produces a stale first claim when
the second creator overwrites its generation. This is why the guard covers the
whole scan-and-reserve interval, not just the final slot store.

`SupervisionLifecycle` composes a fixed two-node static topology with a nested
bounded family owned by the dependent node. The safety configuration explores
two family slots, two generations, every recovery impact, manual commands,
startup and readiness, admission rollback, family and static restart, nested
escalation, ordinary shutdown, terminal shutdown, and the explicit stuck-child
outcome. It checks exact affected sets, reverse stop and topological start
ordering, join-before-replacement, shared incident attempts, bounded attempts,
generation/controller authority, fresh family ownership after an owner
restart, readmission before the replacement owner publishes readiness, nested
family join before owner termination, and the conditions under which `Run`
may finish. A separate weak-fairness configuration checks that a requested
shutdown eventually finishes when children cooperate. There is deliberately
no liveness claim for a child that does not terminate.

Five broken supervision configurations are required to fail. They respectively
remove controller identity from command validation, permit a replacement after
termination but before join, mint a new incident while propagating a nested
escalation, publish owner readiness before desired-child readmission, and omit
forwarding the parent stop request. The last defect is a temporal
counterexample: the nested family remains open and the synchronous outer run
cannot complete.

## Reviewed abstraction boundary

The models intentionally omit or coarsen the following details:

- TLC explores finite configurations. Passing is not an unbounded mathematical
  proof and says nothing about an unmodeled transition.
- Ada/C atomic operations are modeled as indivisible actions with the ordering
  promised by their acquire, release, and CAS calls. The models do not prove
  compiler lowering, platform memory models, cache coherence, or C ABI facts.
- MPMC payload copy and observation are abstract intervals between claim and
  publication. Element adapters, exceptions, poisoning, counter wrap at
  `Unsigned_64'Last`, and address calculations remain outside the model.
- The legacy MPMC scan uses one atomic mutable snapshot. The removed Ada code
  sampled counters and slots separately, so the model admits fewer bad legacy
  observations; its counterexample therefore does not depend on a torn scan.
- The map model retains the exact state/count write order and abandoned-guard
  behavior but abstracts keys, hashes, probe chains, tombstone selection,
  payload bytes, and poisoning.
- The registry model uses byte units, coarsens guarded metadata writes into one
  `Reserve` action, and selects nondeterministically among equal best-fit
  reservations. It does not model mapping replacement, flush, OS namespaces,
  descriptor handoff, or independently authorized recovery.
- Crash actions establish the documented failure mode only: a dead owner can
  leave a guard or initialization slot abandoned. There is deliberately no
  recovery or ownership-stealing action and no liveness claim.
- The supervision model fixes the dependency graph to one prerequisite and one
  dependent nested-family owner. That is the smallest topology that exercises
  all four recovery impacts and the owner-restart boundary, but it does not
  prove arbitrary graph size, capacity, generation width, or retry count.
- Supervision construction, task activation, protected-entry scheduling,
  exception payloads, event-ring writes, monitor tickets, real-time deadlines,
  and numeric backoff calculations are coarsened. The SPARK
  `Supervision_Policy` proofs cover the pure graph, transition, authority,
  incident, and retry-policy kernels; behavioral tests cover their Ada
  integration.
- Recovery admission is represented by `MaxAttempts`: an admitted incident
  advances once and exhaustion becomes terminal. The model does not replace
  the proved burst, total-attempt, stability-reset, saturation, and deadline
  arithmetic.
- Desired nested children are an application-owned set equal to the modeled
  family slots. A new owner generation receives a new family controller and
  must readmit every desired slot before publishing readiness. The model does
  not claim that Flyology persists payloads, handles, or logical identity
  across that owner boundary.
- A successful TLC run establishes the properties of this extraction, not an
  automatic refinement proof from the compiled Ada program. Review must keep
  each model action aligned with the named implementation transition.

Review a model change by comparing every changed action with the referenced Ada
body, checking that no implementation-visible intermediate state was collapsed
without an owning guard, running both safe and broken configurations, and
adding behavioral coverage for any new implementation boundary. A model should
not be weakened merely to make TLC finish.
