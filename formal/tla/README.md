# Shared-memory TLA+ models

These models extract three concurrency-sensitive state machines from the Ada
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
the three current configurations to completion and then requires each broken
configuration to produce its named counterexample. TLC's generated state is
kept in a temporary directory.

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

Review a model change by comparing every changed action with the referenced Ada
body, checking that no implementation-visible intermediate state was collapsed
without an owning guard, running both safe and broken configurations, and
adding behavioral coverage for any new implementation boundary. A model should
not be weakened merely to make TLC finish.
