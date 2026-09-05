# TLA+ models

These models extract eight concurrency-sensitive state machines from the Ada
implementation. They are bounded, executable design reviews: TLC explores all
interleavings within each checked configuration, while the behavioral and
SPARK suites continue to cover the implementation boundaries that TLA+ does
not model.

Run them with the reviewed `flyology-ada/tla` harness checkout and its pinned
toolchain. Build the checkout at merged revision
`dea289018a3eef2ac2aeab7a5ee8bc4e287fe231`, which contains reviewed revision
`59d4301e83b37ad94094690d7ca4399251cc98cf` and pins TLA+ Tools revision
`b123b22`, provision its toolchain, then evaluate the environment it reports:

```sh
eval "$(/path/to/flyology-tla/bin/flyology-tla toolchain env /path/to/toolchain)"
FLYOLOGY_TLA_HARNESS_ROOT=/path/to/flyology-tla ./scripts/check-tla.sh
```

The script verifies the exact harness revision and toolchain before use. It
runs the current safety and liveness configurations to completion, then
requires each broken configuration to produce its named counterexample. TLC's
generated state is kept under `build/` and removed on exit. Alire and a native
GNAT toolchain are also required for the allocator refinement traces and the
implementation replays described below.

`AllocatorAlgorithmsRefinement` constrains the allocator model and the real
standalone kernels to the same operation sequences. Test-only child units read
the real persisted metadata and view-local Buddy hints without entering the
library or public API. After every public allocation or release, the runner
compares canonical physical blocks, live allocation generations, logical
free-index members, real TLSF classes and first/second-level bitmaps, Buddy
hints, handles, and results with the TLC state. The three no-retry variants
must prevent trace completion, so the comparison is not allowed to pass merely
because both trace producers emitted nothing.

`AdaptivePoolLifecycle` has a separate typed conformance lane. The gate runs
the fixed witness to its intentional terminal invariant, regenerates the Ada
boundary twice, byte-compares the generated sources and inference report,
normalizes and validates the canonical trace, and then builds an isolated
consumer copy with ephemeral local Alire pins. A conformance-only extending
project also redirects the hook-enabled Flyology objects and library into that
ephemeral tree. The gate first builds the adaptive-hook-disabled production
archive and verifies that the replay build leaves it unchanged. Its private
child adapter applies each modeled action to the real pool and reports only
observed handles, errors, chunk lifecycle hooks, and stale-handle validation.
Expected model values never cross the generated adapter boundary.

`AdaptivePoolLifecycleProof` is the mandatory TLAPS preservation proof for the
two-pass policy. It proves initialization and action-by-action preservation of
the model's type, failed-destroy atomicity, and stale-handle safety predicates.
The finite TLC safe/broken checks and four-transition Ada replay remain
separate required evidence.

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
| `AllocatorAlgorithms.Acquire` / `FinishOperation` | allocator metadata-guard acquisition and release around one complete operation |
| `SelectCandidate` | Buddy lowest-address tree candidate, Best-Fit smallest size/address candidate, or TLSF first modeled nonempty size class |
| `SplitBuddyCandidate` | Buddy left-path split with each right sibling retained as a free tree node |
| `CommitAllocation` | generation advance, block allocation, remainder publication, and generation-stamped handle return |
| `ValidateRelease` | persisted state/generation validation followed by lazy free publication and Buddy view-local hint update |
| `BeginCoalesce` / `CoalesceStep` / `FinishCoalesce` | allocation-miss sweep, bounded physical merges, and retry boundary in the three lazy algorithms |
| `freeIndex` | Buddy free-tree frontier or Best-Fit AVL membership, abstracted as exact free block keys |
| `bins` / `bitmap` | TLSF free-list membership by modeled size class and matching nonempty-class bitmap |
| `hints` | Buddy per-view, per-order candidate cache whose entry is checked against persisted node state before use |
| `AllocatorAlgorithmsRefinement` snapshots | Test-only observations of real allocator blocks, free indexes, TLSF classes and bitmaps, Buddy hints, live allocation generations, handles, and results |
| `SlabSpanAllocator.AllocateSmall` | `Slab_Span_Kernel.Allocate_Small`: select the persisted class head or a free run, claim the first clear bitmap slot, advance its generation, and remove a full slab from the class head |
| `AllocateLarge` | contiguous free-run selection, head/tail descriptor publication, generation advance, and span handle return in `Allocate_Large` |
| `BeginReclaim` | `Reclaim_Empty_Slabs`, class-list rebuild, and the single retry boundary in `Allocate_Unlocked` |
| `ReleaseLive` | bitmap clearing with full-to-partial class reinsertion, or immediate clearing of every descriptor in a large span |
| `SlabSpanPublication.WriteGeneration` / `PublishBitmap` | small-slot generation update followed by release publication of the containing 32-bit bitmap word |
| `ReadBitmap` / `ReadGenerationAfterAcquire` | handle validation's acquire bitmap read followed by the generation read it orders |
| `AdaptivePoolLifecycle.Destroy` | `Allocation_Pools.Adaptive.Destroy`: either reclaim during the scan or preflight every chunk before reclamation |
| `AllocateOne` / `AllocateTwo` | adaptive table-order allocation into a live chunk, followed by creation in the first empty entry |
| `ValidateOldHandle` | adaptive validation of the complete `(chunk, slot, stamp, epoch)` handle tuple |
| `SupervisionLifecycle.StartInitial` / `StartReplacement` | static `Try_Start`, generation construction, and publish-ready sequencing |
| `AffectedFor` / `BeginRecoverableFailure` | `Supervision_Policy.Affected_Children` and static `Begin_Recovery` |
| `IssueOuterStop` / `BeginRecoveryBackoff` | static reverse recovery-stop order, termination publication, join, and backoff |
| family `Reserve` / `Commit` / `Rollback` actions | the protected family admission transaction with an exact controller/generation handle |
| `FailFamilySlot` / `RestartFamilySlot` | family termination classification, join, backoff, and replacement generation |
| `OpenNestedFamily` / `CloseNestedFamily` | one-shot `Families.Run_Nested` controller owned by one outer generation |
| `ForwardParentStop` | `Run_Nested` forwarding the parent generation's stop token into family shutdown |
| `PropagateNestedEscalation` | `Run_Nested` reporting the same active incident context to its parent control |
| `CompletionSetFinalize.BeginFinalize` | `Operations.Finalize` requesting cancellation while the model records the peer's initial reported state as a ghost baseline |
| `EarlyGateReturn` | `Wait_Some` publishing an unrelated terminal, unreported slot before polling descriptors |
| `RestoreReported` | the finalizer restoring every non-target slot's saved reported flag after `Wait_Some` |
| `WaitForTarget` | the private drain predicate that ignores unrelated user-visible completion state |
| `DispatchTarget` | descriptor readiness driving the cancelled target operation to terminal state |
| `FinishFinalize` | finalization releasing the target slot after its provider has drained |
| `FailUpgradeDriver` | failed scoped TLS upgrade cleanup either returning a retained failure or blocking in connection close |
| `DrainPeer` | the owner cancelling and draining an operation registered in another completion set |
| `FinishFailedUpgrade` | typed `Finish` transferring the failed upgrade's close obligation to the connection |
| `ConsumeFailedUpgrade` | generic result discard transferring the same close obligation without waiting for a peer |
| `FinalizeFailedUpgrade` | controlled finalization transferring an abandoned upgrade's close obligation without waiting for a peer |
| `CompleteCleanupDispatch` | provider cleanup publishing and retiring the operation-side close obligation inside the consumption boundary |
| `AbortCleanupDispatch` | the broken split consumption being interrupted after slot release but before close publication |
| `CompleteCleanupHandoff` | the abort-deferred guard claiming and completing a published close with no peer left |
| `AbortCleanupHandoff` | the broken split handoff being interrupted after publication but before its first drain claim |
| `DriverRaises` | a driver transition losing its immediate source before hidden-child admission raises, either stranding the root or terminalizing it once |

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

`AllocatorAlgorithms` checks the three standalone allocator policies with two
attached views, bounded physical storage, bounded generations, and repeated
allocation and release. All configurations check complete nonoverlapping block
coverage, free-index agreement, guard ownership, one live allocation per
client, generation-stamped handles, and absence of false exhaustion. Buddy
also checks power-of-two alignment and validates every view-local hint against
persisted state. TLSF checks that every free block occurs in its modeled size
class and that the bitmap exactly names the nonempty classes. Best-Fit uses the
same size/address ordering as its AVL key. Strong fairness for guard admission
and weak fairness for work under the guard establish that every started
operation completes when no owner dies. Every merge reduces the physical block
count before the bounded retry.

The nine broken Buddy/Best-Fit/TLSF configurations are required to fail.
Removing the
coalesce-and-retry boundary produces a false-exhaustion counterexample for each
algorithm. Trusting a stale Buddy hint produces overlapping live allocations.
Retaining stale TLSF bitmap bits breaks agreement with its free lists. Ignoring
a release handle's generation frees a newer allocation at the reused offset.
Three nonterminating sweep variants retain a mergeable pair while toggling
local progress state, producing temporal counterexamples for operation
completion.

`SlabSpanAllocator` separately checks the hybrid allocator's run descriptors,
small-slot bitmaps, contiguous large-span head/tail structure, unique live
starting units, generation-stamped handles, guard ownership, pressure-driven
empty-slab reclamation, absence of false exhaustion, and completion of every
started operation in the current bounded configuration. Its broken no-retry
variant reports exhaustion while an empty slab could be reclaimed for a
larger span. Its broken retry variant toggles progress indefinitely after
reclamation and produces the required temporal counterexample.

`SlabSpanPublication` isolates the memory-ordering boundary that the logical
allocator model treats atomically. The safe configuration checks that a stale
handle cannot observe a newly published slot bit with its old generation when
the writer release-publishes one 32-bit bitmap word and the reader acquire-loads
that word before reading the generation. The required broken configuration
models the former ordinary 64-bit bitmap access and generation-first validation;
TLC exposes the stale-handle acceptance when the bit becomes visible first.

`AdaptivePoolLifecycle` checks a two-chunk, two-slot failed-destruction
boundary. Chunk 1 is empty but retains advanced slot stamps, while chunk 2 has
a live allocation. The current configuration preflights the whole table and
therefore leaves both chunks intact when destruction fails. Its broken
configuration reclaims chunk 1 before discovering the live slot in chunk 2;
after two allocations, the recreated slab resets slot 1 to stamp 1 without
advancing the pool epoch. TLC then produces the required stale-handle
acceptance counterexample. The fixed configuration also checks that a failed
destroy preserves the complete modeled pool state, including the free slot's
owner and pool epoch.

`AdaptivePoolLifecycleProof` discharges two TLAPS obligations over this
extracted state machine: the fixed policy initializes in a safe state, and
every named action preserves that safety conjunction. It does not prove the
Ada implementation, executions outside the extraction, or unmodeled
arena-release failures; TLC and replay retain their separate evidence roles.

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

`CompletionSetFinalize` isolates the scope-exit drain for one pending target
and one unrelated terminal slot, models one failed TLS-upgrade driver with an
operation registered in another completion set, and models a generic driver
raise after its immediate source is cleared and before a hidden child is
attached. The safe configuration gives finalization a private target-state
predicate, defers failed-upgrade connection cleanup until typed `Finish`,
generic `Consume`, or controlled finalization, and converts the driver raise
into exactly one terminal failure. Consumption, cleanup dispatch, handoff
publication, and local obligation retirement complete inside one
abort-deferred boundary. Broken variants expose the two interruption windows
on either side of publication.
Weak fairness includes descriptor dispatch, peer draining after the driver
returns, and each final cleanup path.
TLC checks that all three workflows reach `Done`, release no pending target,
preserve the unrelated slot's initial reported state, return when disposal
precedes peer drain, complete close only after the peer registration withdraws,
and leave the raised driver with a terminal root, no source or child, and one
failure publication.

Six broken configurations are required to fail. The first routes the finalizer
through the user-visible `Wait_Some` gate and produces the issue #130 lasso:
`EarlyGateReturn` marks the unrelated slot reported, `RestoreReported` makes it
unreported again, and the cycle repeats without entering `DispatchTarget`. The
second performs the issue #131 connection close inside the driver. The driver
blocks waiting for the peer registration, while `DrainPeer` is enabled only
after control returns to the owner, so `DriverFailureCompletes` has a terminal
lasso in `Blocked`. The third performs synchronous close from result cleanup
and strands reverse-order disposal in `CleanupBlocked`. The fourth splits slot
release from cleanup dispatch; abort leaves the unpublished operation-side
obligation in `DispatchAborted`. The fifth splits deferred-close publication
from its first drain claim and local obligation retirement; abort after
publication leaves the connection in `HandoffAborted` when no peer remains to
complete the close. The sixth lets a generic driver raise after its immediate
source is cleared; the root remains pending with neither source nor child and
violates `DriverRaiseHasProgress`.

The model still keeps propagation-guard state and general child capacity
outside its state vector. Those remain extension points for analysis of other
abort-deferred drive sections (#136); issue #180 is represented by the generic
driver-raise source and child state.

The maintained gate also regenerates the typed Ada model twice, byte-compares
both results with the checked-in files, regenerates and validates the bounded
six-state witness trace, and builds the isolated test crate in
[`tests/operations_finalize_conformance`](../../tests/operations_finalize_conformance).
Its adapter records cancellation and exactly one `Source_Ready` drive from the
delayed provider before accepting the target as drained. It then confirms that
the unrelated terminal operation remains available through public
`Wait_Some`. Three further replay transitions drive the failed-upgrade
ordering independently. Typed `Finish`, generic `Consume`, and reverse-order
controlled finalization transfer close ownership and return before the peer is
cancelled. The last withdrawal then completes the close and releases the
admission permit. Typed `Finish` retains the TLS failure; the other paths
discard it. A fifth transition reproduces later hidden-child exhaustion through
scoped DNS and checks the terminal failure, retained exception, and source/child
post-state. The replay runs under a 20-second external timeout and must report
five conformant modeled transitions.
TLAPS separately proves both stated safety obligations; replay is not
represented as proof.

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
- The general allocator model uses four abstract allocation units, omits the
  in-band prefix/minimum-fragment arithmetic, and uses an identity TLSF
  size-class function. The conformance traces instead use eight 64-byte
  quanta; an in-band model request of `n` quanta calls Ada with an
  `(n - 1) * 64`-byte payload because one quantum holds the block prefix. The
  selected 2/4/8-quantum requests therefore have exact production extents.
  The model preserves physical adjacency, Buddy alignment and splitting,
  Best-Fit size/address choice, TLSF bin/bitmap membership, lazy release,
  miss-triggered coalescing, retry, generation validation, and view-local hint
  invalidation. It abstracts AVL rotations, TLSF free-list order, byte-address
  checks, payload access, the handle token's fixed arena-epoch half, poisoning,
  destruction, and generation widths beyond the checked bound. Released block
  headers retain their previous generation bytes in Ada; the model normalizes
  those bytes to zero because a free state can never validate a handle. The
  observer still requires every retained generation to be within the global
  counter. A model client is also limited to one live handle and releases that
  handle through the same modeled view; transferable handles are not part of
  this extraction. Guard admission models fair eventual acquisition rather
  than immediate contention or a concrete timed deadline. Its liveness
  property assumes no guard owner dies and does not claim wait-free or
  real-time completion.
- The slab/span model uses two slots per run and at most two runs. It preserves
  the production distinction between small bitmap slots and whole-run spans,
  retained empty slabs, miss-triggered reclamation and retry, head/tail span
  structure, release behavior, guard ownership, and handle generations. It
  abstracts the production power-of-two class ladder to one small class,
  singly linked class-head ordering, exact descriptor byte offsets, attachment
  validation scans, payload access, poisoning, and generation widths beyond
  the checked bound. Unlike the three older allocator models, it does not yet
  have a canonical Ada/TLC snapshot trace; its alignment is a reviewed action
  map plus behavioral tests, so no implementation-refinement claim should be
  made for it.
- The publication model deliberately represents only one reused slot and one
  stale reader. It models independent visibility for the former ordinary
  accesses and the ordering edge supplied by the corrected release/acquire
  bitmap word. Compiler lowering and a complete hardware memory model remain
  outside TLC and are covered by the maintained 32-bit atomic primitive
  boundary and bare-board cross-build.
- The adaptive-pool lifecycle model fixes the table to two chunks and each
  slab to two slots. It preserves table-order allocation, live/empty entries,
  ownership, pool epoch, failed destruction, and the complete returned and
  validated handle tuples. It exposes a slot generation only when allocation
  returns it, rather than requiring a conformance adapter to predict an
  otherwise unobservable free-slot stamp. It abstracts arena allocation and
  release, unrelated slot metadata, byte geometry, payload copying,
  outer-guard contention, and generation widths beyond two.
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
- The completion-finalization model fixes the set to the smallest relevant
  shape: one pending target and one terminal peer. `TargetGate` is an abstract
  private predicate, not a new public wait operation. Kernel completion is
  represented by one weakly fair `DispatchTarget` action after the drain
  reaches its poll phase; the model does not claim a latency bound, kernel
  fairness, or completion when a provider never relinquishes its input. The
  one-step harness trace projects the detailed drain as the public scope-exit
  transition and additionally requires the peer to remain publishable, which
  checks preservation of its user-visible reported state.
- The driver-raise lane fixes one pending root with an immediate source, no
  attached child, and a one-bit terminal-failure count. It abstracts the exact
  provider and exception type; the Ada replay supplies the DNS capacity
  scenario and checks the concrete retained outcome.
- Desired nested children are an application-owned set equal to the modeled
  family slots. A new owner generation receives a new family controller and
  must readmit every desired slot before publishing readiness. The model does
  not claim that Flyology persists payloads, handles, or logical identity
  across that owner boundary.
- A successful TLC run establishes the properties of this extraction, not an
  unbounded refinement proof from the compiled Ada program. The maintained
  allocator traces additionally check the extraction against real Ada states
  at each public operation boundary. They do not observe guarded intermediate
  writes, raw padding, AVL shape, inactive Buddy descendants, native addresses,
  TLSF free-list order, guard contention, cross-view handle transfer, or
  executions outside the bounded traces. Review must still keep each model
  action aligned with the named implementation transition.

Review a model change by comparing every changed action with the referenced Ada
body, checking that no implementation-visible intermediate state was collapsed
without an owning guard, running both safe and broken configurations, and
adding behavioral coverage for any new implementation boundary. A model should
not be weakened merely to make TLC finish.
