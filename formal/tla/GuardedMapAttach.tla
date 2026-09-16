---- MODULE GuardedMapAttach ----
EXTENDS FiniteSets, Integers, Naturals

(***************************************************************************
The bounded model mirrors Flyology.Data_Structures.Hash_Maps insertion,
removal, and attachment.  A mutator owns the persisted guard while it changes
an entry state and the separately stored occupied count.  The current Attach
acquires that same guard before rereading and validating both mutable fields.

The legacy attachment path first sampled the count from the layout header,
observed that the guard was free without claiming it, and then scanned the
table.  Its three actions intentionally retain those instruction boundaries so
TLC can place a complete or partial mutation between them.
***************************************************************************)

CONSTANTS Capacity, Mutators, Attachers, AttachPolicy

ASSUME /\ Capacity \in Nat \ {0}
       /\ Mutators # {}
       /\ Attachers # {}
       /\ Mutators \intersect Attachers = {}
       /\ AttachPolicy \in {"guarded", "legacy-observe-only",
                            "epoch-validate-first", "epoch-guard-first"}

NoOwner == "none"
NoSlot == -1
Slots == 0 .. (Capacity - 1)
MutationPhases == {"idle", "insert-prepared", "insert-published",
                    "remove-prepared", "remove-published", "abandoned"}
AttachPhases == {"idle", "sampled", "checked", "validating",
                  "attached", "busy", "rejected", "abandoned"}

ASSUME NoOwner \notin Mutators \cup Attachers

VARIABLES guard, entries, count, mutationPhase, mutationTarget,
          attachPhase, sampledCount, epochState

mapVars == <<guard, entries, count, mutationPhase, mutationTarget,
             attachPhase, sampledCount>>
vars == <<mapVars, epochState>>

EpochInitial ==
  [epoch |-> 1, leaf |-> "guarded", owner |-> NoOwner,
   views |-> [v \in Mutators |-> 1],
   phases |-> [v \in Mutators |-> "idle"],
   result |-> "none", peer |-> "idle", staleWrite |-> FALSE,
   step |-> 0, action |-> "Init"]

Init ==
  /\ guard = NoOwner
  /\ entries = {}
  /\ count = 0
  /\ mutationPhase = [m \in Mutators |-> "idle"]
  /\ mutationTarget = [m \in Mutators |-> NoSlot]
  /\ attachPhase = [a \in Attachers |-> "idle"]
  /\ sampledCount = [a \in Attachers |-> 0]
  /\ epochState = EpochInitial

PrepareInsert(m, slot) ==
  /\ mutationPhase[m] = "idle"
  /\ guard = NoOwner
  /\ slot \in Slots \ entries
  /\ guard' = m
  /\ mutationPhase' = [mutationPhase EXCEPT ![m] = "insert-prepared"]
  /\ mutationTarget' = [mutationTarget EXCEPT ![m] = slot]
  /\ UNCHANGED <<entries, count, attachPhase, sampledCount>>

PublishInsertedEntry(m) ==
  /\ mutationPhase[m] = "insert-prepared"
  /\ guard = m
  /\ entries' = entries \cup {mutationTarget[m]}
  /\ mutationPhase' = [mutationPhase EXCEPT ![m] = "insert-published"]
  /\ UNCHANGED <<guard, count, mutationTarget,
                  attachPhase, sampledCount>>

CommitInsertCount(m) ==
  /\ mutationPhase[m] = "insert-published"
  /\ guard = m
  /\ count' = count + 1
  /\ mutationPhase' = [mutationPhase EXCEPT ![m] = "idle"]
  /\ mutationTarget' = [mutationTarget EXCEPT ![m] = NoSlot]
  /\ guard' = NoOwner
  /\ UNCHANGED <<entries, attachPhase, sampledCount>>

PrepareRemove(m, slot) ==
  /\ mutationPhase[m] = "idle"
  /\ guard = NoOwner
  /\ slot \in entries
  /\ guard' = m
  /\ mutationPhase' = [mutationPhase EXCEPT ![m] = "remove-prepared"]
  /\ mutationTarget' = [mutationTarget EXCEPT ![m] = slot]
  /\ UNCHANGED <<entries, count, attachPhase, sampledCount>>

PublishRemovedEntry(m) ==
  /\ mutationPhase[m] = "remove-prepared"
  /\ guard = m
  /\ entries' = entries \ {mutationTarget[m]}
  /\ mutationPhase' = [mutationPhase EXCEPT ![m] = "remove-published"]
  /\ UNCHANGED <<guard, count, mutationTarget,
                  attachPhase, sampledCount>>

CommitRemoveCount(m) ==
  /\ mutationPhase[m] = "remove-published"
  /\ guard = m
  /\ count' = count - 1
  /\ mutationPhase' = [mutationPhase EXCEPT ![m] = "idle"]
  /\ mutationTarget' = [mutationTarget EXCEPT ![m] = NoSlot]
  /\ guard' = NoOwner
  /\ UNCHANGED <<entries, attachPhase, sampledCount>>

AbandonMutation(m) ==
  /\ mutationPhase[m] \in
       {"insert-prepared", "insert-published",
        "remove-prepared", "remove-published"}
  /\ guard = m
  /\ mutationPhase' = [mutationPhase EXCEPT ![m] = "abandoned"]
  /\ UNCHANGED <<guard, entries, count, mutationTarget,
                  attachPhase, sampledCount>>

StartGuardedAttach(a) ==
  /\ AttachPolicy = "guarded"
  /\ attachPhase[a] = "idle"
  /\ IF guard = NoOwner
        THEN /\ guard' = a
             /\ attachPhase' = [attachPhase EXCEPT ![a] = "validating"]
        ELSE /\ UNCHANGED guard
             /\ attachPhase' = [attachPhase EXCEPT ![a] = "busy"]
  /\ UNCHANGED <<entries, count, mutationPhase, mutationTarget,
                  sampledCount>>

ValidateGuardedAttach(a) ==
  /\ AttachPolicy = "guarded"
  /\ attachPhase[a] = "validating"
  /\ guard = a
  /\ attachPhase' =
       [attachPhase EXCEPT
          ![a] = IF count = Cardinality(entries)
                 THEN "attached" ELSE "rejected"]
  /\ guard' = NoOwner
  /\ UNCHANGED <<entries, count, mutationPhase, mutationTarget,
                  sampledCount>>

AbandonGuardedAttach(a) ==
  /\ AttachPolicy = "guarded"
  /\ attachPhase[a] = "validating"
  /\ guard = a
  /\ attachPhase' = [attachPhase EXCEPT ![a] = "abandoned"]
  /\ UNCHANGED <<guard, entries, count, mutationPhase, mutationTarget,
                  sampledCount>>

SampleLegacyCount(a) ==
  /\ AttachPolicy = "legacy-observe-only"
  /\ attachPhase[a] = "idle"
  /\ sampledCount' = [sampledCount EXCEPT ![a] = count]
  /\ attachPhase' = [attachPhase EXCEPT ![a] = "sampled"]
  /\ UNCHANGED <<guard, entries, count,
                  mutationPhase, mutationTarget>>

ObserveLegacyGuard(a) ==
  /\ AttachPolicy = "legacy-observe-only"
  /\ attachPhase[a] = "sampled"
  /\ guard = NoOwner
  /\ attachPhase' = [attachPhase EXCEPT ![a] = "checked"]
  /\ UNCHANGED <<guard, entries, count, mutationPhase, mutationTarget,
                  sampledCount>>

ValidateLegacyAttach(a) ==
  /\ AttachPolicy = "legacy-observe-only"
  /\ attachPhase[a] = "checked"
  /\ attachPhase' =
       [attachPhase EXCEPT
          ![a] = IF sampledCount[a] = Cardinality(entries)
                 THEN "attached" ELSE "rejected"]
  /\ UNCHANGED <<guard, entries, count, mutationPhase, mutationTarget,
                  sampledCount>>

ResetAttach(a) ==
  /\ attachPhase[a] \in {"attached", "busy"}
  /\ attachPhase' = [attachPhase EXCEPT ![a] = "idle"]
  /\ UNCHANGED <<guard, entries, count, mutationPhase, mutationTarget,
                  sampledCount>>

MapNext ==
  \/ \E m \in Mutators, slot \in Slots :
       PrepareInsert(m, slot) \/ PrepareRemove(m, slot)
  \/ \E m \in Mutators :
       PublishInsertedEntry(m) \/ CommitInsertCount(m)
         \/ PublishRemovedEntry(m) \/ CommitRemoveCount(m)
         \/ AbandonMutation(m)
  \/ \E a \in Attachers :
       StartGuardedAttach(a) \/ ValidateGuardedAttach(a)
         \/ AbandonGuardedAttach(a)
         \/ SampleLegacyCount(a) \/ ObserveLegacyGuard(a)
         \/ ValidateLegacyAttach(a) \/ ResetAttach(a)

\* The added scenario state is immutable in every original model action.
Next == MapNext /\ UNCHANGED epochState
Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ guard \in Mutators \cup Attachers \cup {NoOwner}
  /\ entries \subseteq Slots
  /\ count \in 0 .. Capacity
  /\ mutationPhase \in [Mutators -> MutationPhases]
  /\ mutationTarget \in [Mutators -> Slots \cup {NoSlot}]
  /\ attachPhase \in [Attachers -> AttachPhases]
  /\ sampledCount \in [Attachers -> 0 .. Capacity]

UnlockedStorageConsistent ==
  guard = NoOwner => count = Cardinality(entries)

MutationOwnsGuard ==
  \A m \in Mutators : mutationPhase[m] # "idle" => guard = m

GuardedAttachOwnsGuard ==
  AttachPolicy = "guarded" =>
    \A a \in Attachers :
      attachPhase[a] \in {"validating", "abandoned"} => guard = a

NoFalseCorruption ==
  \A a \in Attachers : attachPhase[a] # "rejected"

(***************************************************************************
Epoch-fenced Acquire generalization (#124). The guard occupies header byte 44,
which is immutable zero Auxiliary after SPSC replacement. Reinitialization is
exclusive: no phase between precheck and release/cleanup may overlap it.
Two retained views permit valid acquisition, contention, release, fresh attach
after same-leaf reuse, and stale rejection after same/cross-leaf reuse. This
does not model mutable-table Attach diagnosis (#126), external lifecycle
corruption, owner death, or epoch exhaustion. Epochs 1 and 2 are qualification
geometry. The post-CAS recheck remains explicit even though exclusivity makes
its stale branch unreachable for a valid prechecked operation.
***************************************************************************)
EpochTerminal == {"idle", "done", "busy", "stale"}
EpochValid(v) == epochState.views[v] = epochState.epoch
EpochQuiescent ==
  /\ epochState.owner = NoOwner
  /\ \A v \in Mutators : epochState.phases[v] \in EpochTerminal

StartAcquire(v) ==
  /\ epochState.phases[v] \in EpochTerminal
  /\ epochState' = [epochState EXCEPT
       !.phases[v] = IF AttachPolicy = "epoch-validate-first" THEN "precheck" ELSE "cas",
       !.result = "pending"]

PrecheckAcquire(v) ==
  /\ epochState.phases[v] = "precheck"
  /\ epochState' = [epochState EXCEPT
       !.phases[v] = IF EpochValid(v) THEN "cas" ELSE "stale",
       !.result = IF EpochValid(v) THEN "pending" ELSE "stale"]

CompareExchangeGuard(v) ==
  /\ epochState.phases[v] = "cas"
  /\ IF epochState.owner = NoOwner
       THEN epochState' = [epochState EXCEPT !.owner = v,
              !.phases[v] = "postcheck",
              !.staleWrite = @ \/ ~EpochValid(v)]
       ELSE epochState' = [epochState EXCEPT !.phases[v] = "failed-cas"]

CheckFailedAcquire(v) ==
  /\ epochState.phases[v] = "failed-cas"
  /\ epochState' = [epochState EXCEPT
       !.phases[v] = IF EpochValid(v) THEN "busy" ELSE "stale",
       !.result = IF EpochValid(v) THEN "busy" ELSE "stale"]

PostcheckAcquire(v) ==
  /\ epochState.phases[v] = "postcheck"
  /\ epochState.owner = v
  /\ epochState' = [epochState EXCEPT
       !.phases[v] = IF EpochValid(v) THEN "owned" ELSE "cleanup",
       !.result = IF EpochValid(v) THEN "owned" ELSE "stale"]

ReleaseAcquire(v) ==
  /\ epochState.phases[v] = "owned" /\ epochState.owner = v
  /\ epochState' = [epochState EXCEPT !.owner = NoOwner,
       !.phases[v] = "done", !.result = "ok"]

CleanupStaleAcquire(v) ==
  /\ epochState.phases[v] = "cleanup" /\ epochState.owner = v
  /\ epochState' = [epochState EXCEPT !.owner = NoOwner,
       !.phases[v] = "stale", !.result = "stale"]

ExclusiveReinitialize(target) ==
  /\ EpochQuiescent /\ epochState.epoch = 1
  /\ target \in {"guarded", "SPSC"}
  /\ epochState' = [epochState EXCEPT !.epoch = 2, !.leaf = target,
       !.peer = "idle", !.result = "reinitialized"]

AttachFreshView(v) ==
  /\ EpochQuiescent /\ epochState.leaf = "guarded"
  /\ ~EpochValid(v)
  /\ epochState' = [epochState EXCEPT !.views[v] = epochState.epoch,
       !.phases[v] = "idle", !.result = "attached"]

AttachSPSCPeer ==
  /\ epochState.leaf = "SPSC" /\ epochState.peer = "idle"
  /\ epochState' = [epochState EXCEPT
       !.peer = IF epochState.owner = NoOwner THEN "attached" ELSE "configuration-mismatch"]

EpochNext ==
  /\ \/ \E v \in Mutators : StartAcquire(v) \/ PrecheckAcquire(v)
          \/ CompareExchangeGuard(v) \/ CheckFailedAcquire(v)
          \/ PostcheckAcquire(v) \/ ReleaseAcquire(v)
          \/ CleanupStaleAcquire(v) \/ AttachFreshView(v)
     \/ \E target \in {"guarded", "SPSC"} : ExclusiveReinitialize(target)
     \/ AttachSPSCPeer
  /\ UNCHANGED mapVars
EpochSpec == Init /\ [][EpochNext]_vars

EpochTypeOK ==
  /\ epochState.epoch \in 1..2
  /\ epochState.leaf \in {"guarded", "SPSC"}
  /\ epochState.owner \in Mutators \cup {NoOwner}
  /\ epochState.views \in [Mutators -> 1..2]
  /\ epochState.phases \in [Mutators -> EpochTerminal \cup
       {"precheck", "cas", "failed-cas", "postcheck", "owned", "cleanup"}]
  /\ epochState.staleWrite \in BOOLEAN
  /\ epochState.peer \in {"idle", "attached", "configuration-mismatch"}
  /\ epochState.result \in {"none", "pending", "stale", "busy", "owned",
       "ok", "reinitialized", "attached"}
EpochGuardOwnership ==
  \A v \in Mutators :
    epochState.phases[v] \in {"postcheck", "owned", "cleanup"} => epochState.owner = v
NoStaleGuardWrite == ~epochState.staleWrite
NoFalseAttachRejection == epochState.peer # "configuration-mismatch"
SPSCImmutableAuxiliary == epochState.leaf = "SPSC" => epochState.owner = NoOwner

\* Canonical replay projection: completed public calls plus a synchronized
\* successful-CAS owner boundary for the held valid call. The detailed EpochSpec
\* above retains separate precheck/CAS/postcheck/cleanup instruction boundaries.
\* This witness requires two string-named views; it does not replay arbitrary
\* internal model steps or qualify mutable-table Attach diagnosis.
HoldValid ==
  /\ epochState.step = 0
  /\ epochState' = [epochState EXCEPT !.step = 1, !.action = "HoldValid",
       !.owner = "v1", !.phases["v1"] = "postcheck", !.result = "pending"]
CallContended ==
  /\ epochState.step = 1
  /\ epochState' = [epochState EXCEPT !.step = 2, !.action = "CallContended",
       !.phases["v2"] = "busy", !.result = "busy"]
ReleaseHeld ==
  /\ epochState.step = 2
  /\ epochState' = [epochState EXCEPT !.step = 3, !.action = "ReleaseHeld",
       !.owner = NoOwner, !.phases["v1"] = "done", !.result = "ok"]
ReinitializeSPSC ==
  /\ epochState.step = 3 /\ EpochQuiescent
  /\ epochState' = [epochState EXCEPT !.step = 4, !.action = "ReinitializeSPSC",
       !.epoch = 2, !.leaf = "SPSC", !.result = "reinitialized"]
CallStale ==
  /\ epochState.step = 4
  /\ epochState' = [epochState EXCEPT !.step = 5, !.action = "CallStale",
       !.phases["v2"] = "stale", !.result = "stale",
       !.staleWrite = AttachPolicy = "epoch-guard-first",
       !.peer = IF AttachPolicy = "epoch-guard-first" THEN "configuration-mismatch" ELSE @]
AttachPeer ==
  /\ epochState.step = 5
  /\ epochState' = [epochState EXCEPT !.step = 6, !.action = "AttachPeer",
       !.peer = "attached", !.result = "attached"]
EpochReplayNext ==
  /\ HoldValid \/ CallContended \/ ReleaseHeld \/ ReinitializeSPSC \/ CallStale \/ AttachPeer
  /\ UNCHANGED mapVars
EpochReplaySpec == Init /\ [][EpochReplayNext]_vars
EpochWitnessIncomplete == epochState.step # 6
EpochAlias ==
  [action |-> epochState.action, role |-> "guard-call", input |-> [value |-> 0],
   outcome |-> [status |-> epochState.result],
   state |-> [epoch |-> epochState.epoch,
     auxiliary |-> IF epochState.owner = NoOwner THEN 0 ELSE 1,
     staleWrite |-> epochState.staleWrite, peer |-> epochState.peer]]

=============================================================================
