---------------------- MODULE AdaptivePoolLifecycle ----------------------
EXTENDS Integers, Naturals, TLC

(***************************************************************************
Adaptive allocation-pool destruction and chunk reuse.

The initial state is the smallest production-reachable shape that exposes the
bug: chunk 1 is empty after releasing two allocations, chunk 2 retains one
live allocation, and an old handle still names chunk 1, slot 1, stamp 1,
epoch 1. Release advanced the stale slot's stored stamp to 2.

The broken Destroy reclaims chunk 1 before discovering the live slot in chunk
2. Two later allocations first fill chunk 2, then recreate chunk 1. A newly
initialized slab starts at stamp 1 without advancing the pool epoch, so the old
handle validates as the new allocation. The corrected policy preflights every
chunk before reclaiming any of them and therefore leaves the table unchanged
when Destroy reports a live slot.

This model fixes the geometry to two chunks with two slots each. It preserves
both chunk-entry states, the stale slot's owner, the pool epoch, table-order
allocation, and the complete handle tuple returned or validated by each
operation. The stored slot stamp is represented when allocation exposes it in
that tuple rather than as separately unobservable state. It does not model the
arena allocator, unrelated slot state, byte layout, guard contention, payload
bytes, or generation width beyond the checked range.
***************************************************************************)

CONSTANT DestroyPolicy

ASSUME DestroyPolicy \in {"partial-broken", "two-pass"}

VARIABLES phase, entry1, entry2, owner11, poolEpoch,
          resultStatus, resultChunk, resultSlot, resultStamp, resultEpoch,
          lastAction

vars ==
  <<phase, entry1, entry2, owner11, poolEpoch,
    resultStatus, resultChunk, resultSlot, resultStamp, resultEpoch,
    lastAction>>

Init ==
  /\ phase = "ready"
  /\ entry1 = "live"
  /\ entry2 = "live"
  /\ owner11 = "none"
  /\ poolEpoch = 1
  /\ resultStatus = "none"
  /\ resultChunk = 0
  /\ resultSlot = 0
  /\ resultStamp = 0
  /\ resultEpoch = 0
  /\ lastAction = "Init"

Destroy ==
  /\ phase = "ready"
  /\ phase' = "destroy-failed"
  /\ entry1' = IF DestroyPolicy = "partial-broken" THEN "empty" ELSE entry1
  /\ owner11' = IF DestroyPolicy = "partial-broken" THEN "none" ELSE owner11
  /\ resultStatus' = "destroy-failed"
  /\ resultChunk' = 0
  /\ resultSlot' = 0
  /\ resultStamp' = 0
  /\ resultEpoch' = 0
  /\ lastAction' = "Destroy"
  /\ UNCHANGED <<entry2, poolEpoch>>

AllocateOne ==
  /\ phase = "destroy-failed"
  /\ phase' = "allocated-one"
  /\ IF DestroyPolicy = "partial-broken"
        THEN /\ owner11' = owner11
             /\ resultChunk' = 2
             /\ resultSlot' = 2
             /\ resultStamp' = 1
        ELSE /\ owner11' = "first"
             /\ resultChunk' = 1
             /\ resultSlot' = 1
             /\ resultStamp' = 2
  /\ resultStatus' = "allocated"
  /\ resultEpoch' = poolEpoch
  /\ lastAction' = "AllocateOne"
  /\ UNCHANGED <<entry1, entry2, poolEpoch>>

AllocateTwo ==
  /\ phase = "allocated-one"
  /\ phase' = "allocated-two"
  /\ IF DestroyPolicy = "partial-broken"
        THEN /\ entry1' = "live"
             /\ owner11' = "second"
             /\ resultChunk' = 1
             /\ resultSlot' = 1
             /\ resultStamp' = 1
        ELSE /\ entry1' = entry1
             /\ owner11' = owner11
             /\ resultChunk' = 1
             /\ resultSlot' = 2
             /\ resultStamp' = 2
  /\ resultStatus' = "allocated"
  /\ resultEpoch' = poolEpoch
  /\ lastAction' = "AllocateTwo"
  /\ UNCHANGED <<entry2, poolEpoch>>

OldHandleAccepted ==
  /\ entry1 = "live"
  /\ owner11 # "none"
  /\ resultChunk = 1
  /\ resultSlot = 1
  /\ resultStamp = 1
  /\ resultEpoch = poolEpoch

ValidateOldHandle ==
  /\ phase = "allocated-two"
  /\ phase' = "done"
  /\ resultStatus' = IF OldHandleAccepted THEN "accepted" ELSE "rejected"
  /\ resultChunk' = 1
  /\ resultSlot' = 1
  /\ resultStamp' = 1
  /\ resultEpoch' = 1
  /\ lastAction' = "ValidateOldHandle"
  /\ UNCHANGED <<entry1, entry2, owner11, poolEpoch>>

Next ==
  \/ Destroy
  \/ AllocateOne
  \/ AllocateTwo
  \/ ValidateOldHandle

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ phase \in {"ready", "destroy-failed", "allocated-one", "allocated-two", "done"}
  /\ entry1 \in {"empty", "live"}
  /\ entry2 \in {"empty", "live"}
  /\ owner11 \in {"none", "first", "second"}
  /\ poolEpoch \in 1..1
  /\ resultStatus \in {"none", "destroy-failed", "allocated", "accepted", "rejected"}
  /\ resultChunk \in 0..2
  /\ resultSlot \in 0..2
  /\ resultStamp \in 0..2
  /\ resultEpoch \in 0..1
  /\ lastAction \in {"Init", "Destroy", "AllocateOne", "AllocateTwo", "ValidateOldHandle"}

HarnessInputType == [value : 0..2]

HarnessOutcomeType ==
  [status : {"none", "destroy-failed", "allocated", "accepted", "rejected"},
   chunk : 0..2, slot : 0..2, stamp : 0..2, epoch : 0..1]

NoStaleHandleAccepted ==
  ~(phase = "done" /\ resultStatus = "accepted")

FailedDestroyIsAtomic ==
  \/ phase # "destroy-failed"
  \/ /\ entry1 = "live"
     /\ entry2 = "live"
     /\ owner11 = "none"
     /\ poolEpoch = 1

WitnessPending == phase # "done"

InputValue ==
  CASE lastAction = "AllocateOne" -> 1
    [] lastAction = "AllocateTwo" -> 2
    [] OTHER -> 0

Role ==
  CASE lastAction = "Destroy" -> "destroy"
    [] lastAction \in {"AllocateOne", "AllocateTwo"} -> "allocate"
    [] lastAction = "ValidateOldHandle" -> "validate"
    [] OTHER -> "init"

Alias ==
  [action |-> lastAction,
   role |-> Role,
   input |-> [value |-> InputValue],
   outcome |-> [status |-> resultStatus,
                chunk |-> resultChunk,
                slot |-> resultSlot,
                stamp |-> resultStamp,
                epoch |-> resultEpoch],
   state |-> [phase |-> phase,
              entry1 |-> entry1,
              entry2 |-> entry2,
              owner11 |-> owner11,
              poolEpoch |-> poolEpoch,
              resultStatus |-> resultStatus,
              resultChunk |-> resultChunk,
              resultSlot |-> resultSlot,
              resultStamp |-> resultStamp,
              resultEpoch |-> resultEpoch,
              lastAction |-> lastAction],
   model_source |-> lastAction]

=============================================================================
