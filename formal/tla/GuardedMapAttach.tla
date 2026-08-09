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
       /\ AttachPolicy \in {"guarded", "legacy-observe-only"}

NoOwner == "none"
NoSlot == -1
Slots == 0 .. (Capacity - 1)
MutationPhases == {"idle", "insert-prepared", "insert-published",
                    "remove-prepared", "remove-published", "abandoned"}
AttachPhases == {"idle", "sampled", "checked", "validating",
                  "attached", "busy", "rejected", "abandoned"}

ASSUME NoOwner \notin Mutators \cup Attachers

VARIABLES guard, entries, count, mutationPhase, mutationTarget,
          attachPhase, sampledCount

vars == <<guard, entries, count, mutationPhase, mutationTarget,
          attachPhase, sampledCount>>

Init ==
  /\ guard = NoOwner
  /\ entries = {}
  /\ count = 0
  /\ mutationPhase = [m \in Mutators |-> "idle"]
  /\ mutationTarget = [m \in Mutators |-> NoSlot]
  /\ attachPhase = [a \in Attachers |-> "idle"]
  /\ sampledCount = [a \in Attachers |-> 0]

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

Next ==
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

=============================================================================
