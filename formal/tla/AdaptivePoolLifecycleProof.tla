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
     /\ lastAction = "ValidateOldHandle"

Safety ==
  /\ TypeOK
  /\ ReachableShape
  /\ FailedDestroyIsAtomic
  /\ NoStaleHandleAccepted

THEOREM InitImpliesSafety ==
  DestroyPolicy = "two-pass" => (Init => Safety)
<1>. QED BY DEF Init, Safety, ReachableShape, TypeOK,
                FailedDestroyIsAtomic, NoStaleHandleAccepted

THEOREM NextPreservesSafety ==
  DestroyPolicy = "two-pass" /\ Safety /\ Next => Safety'
<1>. QED BY DEF Safety, ReachableShape, TypeOK,
                FailedDestroyIsAtomic, NoStaleHandleAccepted,
                Next, Destroy, AllocateOne, AllocateTwo,
                ValidateOldHandle, OldHandleAccepted

=============================================================================
