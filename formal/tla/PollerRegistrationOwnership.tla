------------------- MODULE PollerRegistrationOwnership -------------------
EXTENDS Naturals

CONSTANTS CancelMode, DeliveryMode, AfterDelivery, SelectedSource,
          ReplacementArmMode

ASSUME CancelMode \in {"Direct", "Deferred"}
ASSUME DeliveryMode \in {"Unowned", "CancellationOwned"}
ASSUME AfterDelivery \in {"Reregister", "Reap"}
ASSUME SelectedSource \in {"Readiness", "Timer"}
ASSUME ReplacementArmMode \in {"CountQueued", "IgnoreQueued"}

VARIABLES phase,
          groupLockHeld,
          loopWriter,
          foreignWriter,
          pendingCancels,
          targetCancelQueued,
          targetWaiting,
          targetRunnable,
          targetLive,
          waitGeneration,
          cancelGeneration,
          deliverySource,
          progressWake,
          staleCancellation,
          targetReleased,
          kernelInterestArmed,
          replacementReady,
          replacementWaiting,
          replacementDelivered,
          replacementArmAttempted,
          replacementArmSuppressed,
          lastAction

vars ==
    <<phase, groupLockHeld, loopWriter, foreignWriter, pendingCancels,
      targetCancelQueued, targetWaiting, targetRunnable, targetLive,
      waitGeneration, cancelGeneration, deliverySource, progressWake,
      staleCancellation, targetReleased, kernelInterestArmed,
      replacementReady, replacementWaiting, replacementDelivered,
      replacementArmAttempted, replacementArmSuppressed, lastAction>>

TypeOK ==
    /\ phase \in {"Idle", "Translating", "BudgetDrained",
                  "SelectedRetained", "ReplacementWaiting",
                  "ReplacementDrained", "Delivered", "Reused", "Reaped",
                  "Done"}
    /\ groupLockHeld \in BOOLEAN
    /\ loopWriter \in BOOLEAN
    /\ foreignWriter \in BOOLEAN
    /\ pendingCancels \in 0..65
    /\ targetCancelQueued \in BOOLEAN
    /\ targetWaiting \in BOOLEAN
    /\ targetRunnable \in BOOLEAN
    /\ targetLive \in BOOLEAN
    /\ waitGeneration \in 0..2
    /\ cancelGeneration \in 0..1
    /\ deliverySource \in {"None", "Readiness", "Timer"}
    /\ progressWake \in BOOLEAN
    /\ staleCancellation \in BOOLEAN
    /\ targetReleased \in BOOLEAN
    /\ kernelInterestArmed \in BOOLEAN
    /\ replacementReady \in BOOLEAN
    /\ replacementWaiting \in BOOLEAN
    /\ replacementDelivered \in BOOLEAN
    /\ replacementArmAttempted \in BOOLEAN
    /\ replacementArmSuppressed \in BOOLEAN
    /\ lastAction \in
         {"Init", "BeginWaitBatch", "ForeignWake", "DrainBudget",
          "DeliverTarget", "StartReplacement", "ReregisterTarget",
          "ReapTarget", "DrainRemaining", "DeliverReplacement"}

Init ==
    /\ phase = "Idle"
    /\ groupLockHeld = TRUE
    /\ loopWriter = FALSE
    /\ foreignWriter = FALSE
    /\ pendingCancels = 0
    /\ targetCancelQueued = FALSE
    /\ targetWaiting = FALSE
    /\ targetRunnable = FALSE
    /\ targetLive = TRUE
    /\ waitGeneration = 0
    /\ cancelGeneration = 0
    /\ deliverySource = "None"
    /\ progressWake = FALSE
    /\ staleCancellation = FALSE
    /\ targetReleased = FALSE
    /\ kernelInterestArmed = FALSE
    /\ replacementReady = FALSE
    /\ replacementWaiting = FALSE
    /\ replacementDelivered = FALSE
    /\ replacementArmAttempted = FALSE
    /\ replacementArmSuppressed = FALSE
    /\ lastAction = "Init"

\* The target has a one-shot kernel interest when the loop begins translating
\* the selected epoll batch.
BeginWaitBatch ==
    /\ phase = "Idle"
    /\ phase' = "Translating"
    /\ groupLockHeld' = FALSE
    /\ loopWriter' = TRUE
    /\ foreignWriter' = FALSE
    /\ pendingCancels' = 0
    /\ targetCancelQueued' = FALSE
    /\ targetWaiting' = TRUE
    /\ targetRunnable' = FALSE
    /\ targetLive' = TRUE
    /\ waitGeneration' = 1
    /\ cancelGeneration' = 0
    /\ deliverySource' = SelectedSource
    /\ progressWake' = FALSE
    /\ staleCancellation' = FALSE
    /\ targetReleased' = FALSE
    /\ kernelInterestArmed' = TRUE
    /\ replacementReady' = FALSE
    /\ replacementWaiting' = FALSE
    /\ replacementDelivered' = FALSE
    /\ replacementArmAttempted' = FALSE
    /\ replacementArmSuppressed' = FALSE
    /\ lastAction' = "BeginWaitBatch"

\* A native thread wakes 65 waiters with the selected target queued last.
ForeignWake ==
    /\ phase = "Translating"
    /\ targetWaiting
    /\ targetLive
    /\ waitGeneration = 1
    /\ phase' = phase
    /\ groupLockHeld' = groupLockHeld
    /\ loopWriter' = loopWriter
    /\ foreignWriter' = (CancelMode = "Direct")
    /\ pendingCancels' = IF CancelMode = "Deferred" THEN 65 ELSE 0
    /\ targetCancelQueued' = (CancelMode = "Deferred")
    /\ targetWaiting' = (CancelMode = "Deferred")
    /\ targetRunnable' = (CancelMode = "Direct")
    /\ targetLive' = targetLive
    /\ waitGeneration' = waitGeneration
    /\ cancelGeneration' = IF CancelMode = "Deferred" THEN waitGeneration ELSE 0
    /\ deliverySource' = deliverySource
    /\ progressWake' = (CancelMode = "Deferred")
    /\ staleCancellation' = FALSE
    /\ targetReleased' = (CancelMode = "Direct")
    /\ kernelInterestArmed' = kernelInterestArmed
    /\ replacementReady' = replacementReady
    /\ replacementWaiting' = FALSE
    /\ replacementDelivered' = FALSE
    /\ replacementArmAttempted' = FALSE
    /\ replacementArmSuppressed' = FALSE
    /\ lastAction' = "ForeignWake"

\* epoll consumes the selected one-shot and Wait_Batch removes its process-side
\* record before the loop regains the group lock. The first bounded drain then
\* consumes 64 earlier entries and leaves the target's scheduler link queued.
DrainBudget ==
    /\ phase = "Translating"
    /\ CancelMode = "Deferred"
    /\ pendingCancels = 65
    /\ targetCancelQueued
    /\ phase' = "BudgetDrained"
    /\ groupLockHeld' = TRUE
    /\ loopWriter' = FALSE
    /\ foreignWriter' = FALSE
    /\ pendingCancels' = 1
    /\ targetCancelQueued' = TRUE
    /\ targetWaiting' = TRUE
    /\ targetRunnable' = FALSE
    /\ targetLive' = targetLive
    /\ waitGeneration' = waitGeneration
    /\ cancelGeneration' = cancelGeneration
    /\ deliverySource' = deliverySource
    /\ progressWake' = TRUE
    /\ staleCancellation' = FALSE
    /\ targetReleased' = FALSE
    /\ kernelInterestArmed' = IF SelectedSource = "Readiness" THEN FALSE
                                ELSE kernelInterestArmed
    /\ replacementReady' = replacementReady
    /\ replacementWaiting' = FALSE
    /\ replacementDelivered' = FALSE
    /\ replacementArmAttempted' = FALSE
    /\ replacementArmSuppressed' = FALSE
    /\ lastAction' = "DrainBudget"

\* Cancellation ownership retains selected readiness or an expired timer. An
\* unowned delivery instead permits the legacy reuse and reap counterexamples.
DeliverTarget ==
    /\ phase = "BudgetDrained"
    /\ targetCancelQueued
    /\ phase' =
         IF DeliveryMode = "CancellationOwned"
           THEN IF SelectedSource = "Readiness" /\ AfterDelivery = "Reregister"
                  THEN "SelectedRetained"
                  ELSE "Done"
           ELSE "Delivered"
    /\ groupLockHeld' = TRUE
    /\ loopWriter' = FALSE
    /\ foreignWriter' = FALSE
    /\ pendingCancels' =
         IF DeliveryMode = "CancellationOwned"
              /\ SelectedSource /= "Readiness"
           THEN 0
           ELSE pendingCancels
    /\ targetCancelQueued' =
         IF DeliveryMode = "CancellationOwned"
              /\ SelectedSource /= "Readiness"
           THEN FALSE
           ELSE targetCancelQueued
    /\ targetWaiting' =
         IF DeliveryMode = "CancellationOwned"
              /\ SelectedSource = "Readiness"
           THEN TRUE
           ELSE FALSE
    /\ targetRunnable' =
         IF DeliveryMode = "CancellationOwned"
              /\ SelectedSource = "Readiness"
           THEN FALSE
           ELSE TRUE
    /\ targetLive' = targetLive
    /\ waitGeneration' = waitGeneration
    /\ cancelGeneration' = cancelGeneration
    /\ deliverySource' = deliverySource
    /\ progressWake' =
         IF DeliveryMode = "CancellationOwned"
              /\ SelectedSource /= "Readiness"
           THEN FALSE
           ELSE progressWake
    /\ staleCancellation' = FALSE
    /\ targetReleased' =
         (DeliveryMode = "CancellationOwned" /\ SelectedSource /= "Readiness")
    /\ kernelInterestArmed' = kernelInterestArmed
    /\ replacementReady' =
         IF DeliveryMode = "CancellationOwned"
              /\ SelectedSource = "Readiness"
              /\ AfterDelivery = "Reregister"
           THEN TRUE
           ELSE replacementReady
    /\ replacementWaiting' = FALSE
    /\ replacementDelivered' = FALSE
    /\ replacementArmAttempted' = FALSE
    /\ replacementArmSuppressed' = FALSE
    /\ lastAction' = "DeliverTarget"

\* The already-ready replacement starts before the next cancellation drain.
\* Counting the cancellation-owned target link suppresses the needed kernel
\* arm; ignoring that link permits Poller.Watch to ADD the consumed one-shot.
StartReplacement ==
    /\ phase = "SelectedRetained"
    /\ targetCancelQueued
    /\ replacementReady
    /\ phase' = "ReplacementWaiting"
    /\ kernelInterestArmed' = (ReplacementArmMode = "IgnoreQueued")
    /\ replacementReady' = FALSE
    /\ replacementWaiting' = TRUE
    /\ replacementDelivered' = FALSE
    /\ replacementArmAttempted' = TRUE
    /\ replacementArmSuppressed' = (ReplacementArmMode = "CountQueued")
    /\ lastAction' = "StartReplacement"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter, pendingCancels,
                   targetCancelQueued, targetWaiting, targetRunnable,
                   targetLive, waitGeneration, cancelGeneration,
                   deliverySource, progressWake, staleCancellation,
                   targetReleased>>

ReregisterTarget ==
    /\ phase = "Delivered"
    /\ DeliveryMode = "Unowned"
    /\ AfterDelivery = "Reregister"
    /\ targetRunnable
    /\ phase' = "Reused"
    /\ targetWaiting' = TRUE
    /\ targetRunnable' = FALSE
    /\ waitGeneration' = 2
    /\ lastAction' = "ReregisterTarget"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter, pendingCancels,
                   targetCancelQueued, targetLive, cancelGeneration,
                   deliverySource, progressWake, staleCancellation,
                   targetReleased, kernelInterestArmed, replacementReady,
                   replacementWaiting, replacementDelivered,
                   replacementArmAttempted, replacementArmSuppressed>>

ReapTarget ==
    /\ phase = "Delivered"
    /\ DeliveryMode = "Unowned"
    /\ AfterDelivery = "Reap"
    /\ targetRunnable
    /\ phase' = "Reaped"
    /\ targetRunnable' = FALSE
    /\ targetLive' = FALSE
    /\ lastAction' = "ReapTarget"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter, pendingCancels,
                   targetCancelQueued, targetWaiting, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased, kernelInterestArmed,
                   replacementReady, replacementWaiting,
                   replacementDelivered, replacementArmAttempted,
                   replacementArmSuppressed>>

DrainReplacement ==
    /\ phase = "ReplacementWaiting"
    /\ targetCancelQueued
    /\ phase' = "ReplacementDrained"
    /\ pendingCancels' = 0
    /\ targetCancelQueued' = FALSE
    /\ targetWaiting' = FALSE
    /\ targetRunnable' = TRUE
    /\ progressWake' = FALSE
    /\ targetReleased' = TRUE
    /\ lastAction' = "DrainRemaining"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter, targetLive,
                   waitGeneration, cancelGeneration, deliverySource,
                   staleCancellation, kernelInterestArmed, replacementReady,
                   replacementWaiting, replacementDelivered,
                   replacementArmAttempted, replacementArmSuppressed>>

DrainReused ==
    /\ phase = "Reused"
    /\ targetCancelQueued
    /\ waitGeneration /= cancelGeneration
    /\ phase' = "Done"
    /\ pendingCancels' = 0
    /\ targetCancelQueued' = FALSE
    /\ targetWaiting' = FALSE
    /\ targetRunnable' = TRUE
    /\ progressWake' = FALSE
    /\ staleCancellation' = TRUE
    /\ targetReleased' = TRUE
    /\ lastAction' = "DrainRemaining"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter, targetLive,
                   waitGeneration, cancelGeneration, deliverySource,
                   kernelInterestArmed, replacementReady,
                   replacementWaiting, replacementDelivered,
                   replacementArmAttempted, replacementArmSuppressed>>

DrainRemaining == DrainReplacement \/ DrainReused

DeliverReplacement ==
    /\ phase = "ReplacementDrained"
    /\ replacementWaiting
    /\ kernelInterestArmed
    /\ phase' = "Done"
    /\ replacementWaiting' = FALSE
    /\ replacementDelivered' = TRUE
    /\ lastAction' = "DeliverReplacement"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter, pendingCancels,
                   targetCancelQueued, targetWaiting, targetRunnable,
                   targetLive, waitGeneration, cancelGeneration,
                   deliverySource, progressWake, staleCancellation,
                   targetReleased, kernelInterestArmed, replacementReady,
                   replacementArmAttempted, replacementArmSuppressed>>

Next ==
    \/ BeginWaitBatch
    \/ ForeignWake
    \/ DrainBudget
    \/ DeliverTarget
    \/ StartReplacement
    \/ ReregisterTarget
    \/ ReapTarget
    \/ DrainRemaining
    \/ DeliverReplacement

Spec == Init /\ [][Next]_vars

SingleRegistrationWriter == ~(loopWriter /\ foreignWriter)
CancellationQueueReferencesLiveFiber == targetCancelQueued => targetLive
QueuedCancellationMatchesWaitGeneration ==
    targetCancelQueued => cancelGeneration = waitGeneration
QueuedCancellationOwnsTarget == targetCancelQueued => ~targetRunnable
PendingCancellationHasWake == (pendingCancels > 0) => progressWake
NoStaleCancellation == ~staleCancellation
ReplacementWaitHasKernelInterest == replacementWaiting => kernelInterestArmed
QueuedLinkDoesNotSuppressReplacementArm ==
    replacementArmAttempted /\ targetCancelQueued => ~replacementArmSuppressed

HarnessInputType ==
    [command : {"BeginWaitBatch", "ForeignWake", "DrainBudget",
                "DeliverTarget", "StartReplacement", "DrainRemaining",
                "DeliverReplacement"}]

HarnessOutcomeType ==
    [pending : 0..65,
     queued : BOOLEAN,
     foreignMutation : BOOLEAN,
     targetRunnable : BOOLEAN,
     targetReleased : BOOLEAN,
     kernelArmed : BOOLEAN,
     replacementWaiting : BOOLEAN,
     replacementDelivered : BOOLEAN,
     armSuppressed : BOOLEAN]

WitnessIncomplete == phase /= "Done"

Alias == [
    action |-> lastAction,
    role |-> "poller-registration",
    input |-> [command |-> lastAction],
    outcome |->
      [pending |-> pendingCancels,
       queued |-> targetCancelQueued,
       foreignMutation |-> foreignWriter,
       targetRunnable |-> targetRunnable,
       targetReleased |-> targetReleased,
       kernelArmed |-> kernelInterestArmed,
       replacementWaiting |-> replacementWaiting,
       replacementDelivered |-> replacementDelivered,
       armSuppressed |-> replacementArmSuppressed],
    state |->
      [phase |-> phase,
       groupLockHeld |-> groupLockHeld,
       loopWriter |-> loopWriter,
       foreignWriter |-> foreignWriter,
       pendingCancels |-> pendingCancels,
       targetCancelQueued |-> targetCancelQueued,
       targetWaiting |-> targetWaiting,
       targetRunnable |-> targetRunnable,
       targetLive |-> targetLive,
       waitGeneration |-> waitGeneration,
       cancelGeneration |-> cancelGeneration,
       deliverySource |-> deliverySource,
       progressWake |-> progressWake,
       staleCancellation |-> staleCancellation,
       targetReleased |-> targetReleased,
       kernelInterestArmed |-> kernelInterestArmed,
       replacementReady |-> replacementReady,
       replacementWaiting |-> replacementWaiting,
       replacementDelivered |-> replacementDelivered,
       replacementArmAttempted |-> replacementArmAttempted,
       replacementArmSuppressed |-> replacementArmSuppressed,
       lastAction |-> lastAction],
    model_source |-> lastAction
]

=============================================================================
