------------------- MODULE AdaptivePoolLifecycleProof -------------------
EXTENDS AdaptivePoolLifecycle

ReachableShape ==
  \/ /\ phase = "ready"
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
  \/ /\ phase = "destroy-failed"
     /\ entry1 = "live"
     /\ entry2 = "live"
     /\ owner11 = "none"
     /\ poolEpoch = 1
     /\ resultStatus = "destroy-failed"
     /\ resultChunk = 0
     /\ resultSlot = 0
     /\ resultStamp = 0
     /\ resultEpoch = 0
     /\ poolState = "ready"
     /\ arenaBlock1 = "allocated"
     /\ arenaBlock2 = "allocated"
     /\ lastAction = "Destroy"
  \/ /\ phase = "allocated-one"
     /\ entry1 = "live"
     /\ entry2 = "live"
     /\ owner11 = "first"
     /\ poolEpoch = 1
     /\ resultStatus = "allocated"
     /\ resultChunk = 1
     /\ resultSlot = 1
     /\ resultStamp = 2
     /\ resultEpoch = 1
     /\ poolState = "ready"
     /\ arenaBlock1 = "allocated"
     /\ arenaBlock2 = "allocated"
     /\ lastAction = "AllocateOne"
  \/ /\ phase = "allocated-two"
     /\ entry1 = "live"
     /\ entry2 = "live"
     /\ owner11 = "first"
     /\ poolEpoch = 1
     /\ resultStatus = "allocated"
     /\ resultChunk = 1
     /\ resultSlot = 2
     /\ resultStamp = 2
     /\ resultEpoch = 1
     /\ poolState = "ready"
     /\ arenaBlock1 = "allocated"
     /\ arenaBlock2 = "allocated"
     /\ lastAction = "AllocateTwo"
  \/ /\ phase = "done"
     /\ entry1 = "live"
     /\ entry2 = "live"
     /\ owner11 = "first"
     /\ poolEpoch = 1
     /\ resultStatus = "rejected"
     /\ resultChunk = 1
     /\ resultSlot = 1
     /\ resultStamp = 1
     /\ resultEpoch = 1
     /\ poolState = "ready"
     /\ arenaBlock1 = "allocated"
     /\ arenaBlock2 = "allocated"
     /\ lastAction = "ValidateOldHandle"
  \/ /\ phase = "contention-ready"
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
     /\ lastAction = "PrepareContention"
  \/ /\ phase = "contention-done"
     /\ entry1 = "empty"
     /\ entry2 = "live"
     /\ owner11 = "none"
     /\ poolEpoch = 1
     /\ resultStatus = "destroy-contended"
     /\ resultChunk = 0
     /\ resultSlot = 0
     /\ resultStamp = 0
     /\ resultEpoch = 0
     /\ poolState = "ready"
     /\ arenaBlock1 = "free"
     /\ arenaBlock2 = "allocated"
     /\ lastAction = "DestroyContended"

Safety ==
  /\ TypeOK
  /\ ReachableShape
  /\ FailedDestroyIsAtomic
  /\ NoStaleHandleAccepted
  /\ TransientContentionNeverPoisons
  /\ TransientContentionDoesNotStrand

THEOREM InitImpliesSafety ==
  DestroyPolicy = "two-pass" /\ ContentionPolicy = "reject" => (Init => Safety)
<1>. QED BY DEF Init, Safety, ReachableShape, TypeOK,
                FailedDestroyIsAtomic, NoStaleHandleAccepted,
                TransientContentionNeverPoisons,
                TransientContentionDoesNotStrand

THEOREM NextPreservesSafety ==
  DestroyPolicy = "two-pass" /\ ContentionPolicy = "reject" /\ Safety /\ Next => Safety'
<1>. QED BY DEF Safety, ReachableShape, TypeOK,
                FailedDestroyIsAtomic, NoStaleHandleAccepted,
                TransientContentionNeverPoisons,
                TransientContentionDoesNotStrand,
                Next, Destroy, AllocateOne, AllocateTwo,
                ValidateOldHandle, PrepareContention,
                DestroyContended, OldHandleAccepted

=============================================================================
