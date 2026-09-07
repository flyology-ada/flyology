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

After that witness, a second fixture makes both chunks empty. Destruction
reclaims chunk 1, then encounters injected arena contention on chunk 2. The
safe policy leaves a ready pool whose empty first entry matches the freed first
block and whose live second entry still names the allocated second block. The
broken policy poisons that otherwise coherent partial result.

This model fixes the geometry to two chunks with two slots each. It preserves
both chunk-entry states, the stale slot's owner, the pool epoch, table-order
allocation, and the complete handle tuple returned or validated by each
operation. The stored slot stamp is represented when allocation exposes it in
that tuple rather than as separately unobservable state. Arena blocks and
contention are abstracted only at the destroy ownership boundary; allocator
internals, unrelated slot state, byte layout, payload bytes, scheduling, and
generation width beyond the checked range remain outside the model.
***************************************************************************)

CONSTANTS DestroyPolicy, ContentionPolicy

ASSUME DestroyPolicy \in {"partial-broken", "two-pass"}
ASSUME ContentionPolicy \in {"poison-broken", "reject"}

VARIABLES phase, entry1, entry2, owner11, poolEpoch,
          resultStatus, resultChunk, resultSlot, resultStamp, resultEpoch,
          poolState, arenaBlock1, arenaBlock2, lastAction

vars ==
  <<phase, entry1, entry2, owner11, poolEpoch,
    resultStatus, resultChunk, resultSlot, resultStamp, resultEpoch,
    poolState, arenaBlock1, arenaBlock2, lastAction>>

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
  /\ poolState = "ready"
  /\ arenaBlock1 = "allocated"
  /\ arenaBlock2 = "allocated"
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
  /\ arenaBlock1' = IF DestroyPolicy = "partial-broken" THEN "free" ELSE arenaBlock1
  /\ lastAction' = "Destroy"
  /\ UNCHANGED <<entry2, poolEpoch, poolState, arenaBlock2>>

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
  /\ UNCHANGED <<entry1, entry2, poolEpoch, poolState, arenaBlock1, arenaBlock2>>

AllocateTwo ==
  /\ phase = "allocated-one"
  /\ phase' = "allocated-two"
  /\ IF DestroyPolicy = "partial-broken"
        THEN /\ entry1' = "live"
             /\ owner11' = "second"
             /\ arenaBlock1' = "allocated"
             /\ resultChunk' = 1
             /\ resultSlot' = 1
             /\ resultStamp' = 1
        ELSE /\ entry1' = entry1
             /\ owner11' = owner11
             /\ arenaBlock1' = arenaBlock1
             /\ resultChunk' = 1
             /\ resultSlot' = 2
             /\ resultStamp' = 2
  /\ resultStatus' = "allocated"
  /\ resultEpoch' = poolEpoch
  /\ lastAction' = "AllocateTwo"
  /\ UNCHANGED <<entry2, poolEpoch, poolState, arenaBlock2>>

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
  /\ UNCHANGED <<entry1, entry2, owner11, poolEpoch, poolState, arenaBlock1, arenaBlock2>>

PrepareContention ==
  /\ phase = "done"
  /\ phase' = "contention-ready"
  /\ entry1' = "live"
  /\ entry2' = "live"
  /\ owner11' = "none"
  /\ poolEpoch' = 1
  /\ resultStatus' = "none"
  /\ resultChunk' = 0
  /\ resultSlot' = 0
  /\ resultStamp' = 0
  /\ resultEpoch' = 0
  /\ poolState' = "ready"
  /\ arenaBlock1' = "allocated"
  /\ arenaBlock2' = "allocated"
  /\ lastAction' = "PrepareContention"

DestroyContended ==
  /\ phase = "contention-ready"
  /\ phase' = "contention-done"
  /\ IF ContentionPolicy = "poison-broken"
        THEN /\ entry1' = "empty"
             /\ entry2' = entry2
             /\ poolState' = "poisoned"
             /\ arenaBlock1' = "free"
             /\ arenaBlock2' = arenaBlock2
             /\ resultStatus' = "destroy-contended"
        ELSE /\ entry1' = "empty"
             /\ entry2' = entry2
             /\ poolState' = poolState
             /\ arenaBlock1' = "free"
             /\ arenaBlock2' = arenaBlock2
             /\ resultStatus' = "destroy-contended"
  /\ resultChunk' = 0
  /\ resultSlot' = 0
  /\ resultStamp' = 0
  /\ resultEpoch' = 0
  /\ lastAction' = "DestroyContended"
  /\ UNCHANGED <<owner11, poolEpoch>>

Next ==
  \/ Destroy
  \/ AllocateOne
  \/ AllocateTwo
  \/ ValidateOldHandle
  \/ PrepareContention
  \/ DestroyContended

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ phase \in {"ready", "destroy-failed", "allocated-one", "allocated-two", "done",
                "contention-ready", "contention-done"}
  /\ entry1 \in {"empty", "live"}
  /\ entry2 \in {"empty", "live"}
  /\ owner11 \in {"none", "first", "second"}
  /\ poolEpoch \in 1..1
  /\ resultStatus \in {"none", "destroy-failed", "allocated", "accepted", "rejected",
                       "destroy-contended", "destroyed"}
  /\ resultChunk \in 0..2
  /\ resultSlot \in 0..2
  /\ resultStamp \in 0..2
  /\ resultEpoch \in 0..1
  /\ poolState \in {"ready", "poisoned", "destroyed"}
  /\ arenaBlock1 \in {"allocated", "free"}
  /\ arenaBlock2 \in {"allocated", "free"}
  /\ lastAction \in {"Init", "Destroy", "AllocateOne", "AllocateTwo", "ValidateOldHandle",
                     "PrepareContention", "DestroyContended"}

HarnessInputType == [value : 0..2]

HarnessOutcomeType ==
  [status : {"none", "destroy-failed", "allocated", "accepted", "rejected",
             "destroy-contended", "destroyed"},
   chunk : 0..2, slot : 0..2, stamp : 0..2, epoch : 0..1]

NoStaleHandleAccepted ==
  ~(phase = "done" /\ resultStatus = "accepted")

FailedDestroyIsAtomic ==
  \/ phase # "destroy-failed"
  \/ /\ entry1 = "live"
     /\ entry2 = "live"
     /\ owner11 = "none"
     /\ poolEpoch = 1

TransientContentionNeverPoisons ==
  \/ phase # "contention-done"
  \/ poolState = "ready"

TransientContentionDoesNotStrand ==
  \/ phase # "contention-done"
  \/ /\ poolState = "ready"
     /\ entry1 = "empty"
     /\ arenaBlock1 = "free"
     /\ entry2 = "live"
     /\ arenaBlock2 = "allocated"

WitnessPending == phase # "contention-done"

InputValue ==
  CASE lastAction = "AllocateOne" -> 1
    [] lastAction = "AllocateTwo" -> 2
    [] OTHER -> 0

Role ==
  CASE lastAction = "Destroy" -> "destroy"
    [] lastAction \in {"AllocateOne", "AllocateTwo"} -> "allocate"
    [] lastAction = "ValidateOldHandle" -> "validate"
    [] lastAction = "PrepareContention" -> "prepare-contention"
    [] lastAction = "DestroyContended" -> "destroy-contended"
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
              poolState |-> poolState,
              arenaBlock1 |-> arenaBlock1,
              arenaBlock2 |-> arenaBlock2,
              lastAction |-> lastAction],
   model_source |-> lastAction]

=============================================================================
