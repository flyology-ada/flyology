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
                  "SelectedRetained", "TimerRetained", "ReplacementWaiting",
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

\* The readiness witness reaches this boundary only after epoll has selected
\* the target and consumed its one-shot kernel interest. A timer selection has
\* not consumed the descriptor interest that accompanies the pending wait.
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
    /\ kernelInterestArmed' = (SelectedSource = "Timer")
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

\* Wait_Batch finishes translating the already-selected readiness batch before
\* the scheduler regains the group lock and delivers every returned event. A
\* timer is instead delivered after the first cancellation drain. Cancellation
\* ownership retains either source; an unowned delivery permits the legacy
\* reuse and reap counterexamples.
DeliverTarget ==
    /\ IF SelectedSource = "Readiness"
         THEN phase = "Translating"
         ELSE phase = "BudgetDrained"
    /\ targetCancelQueued
    /\ phase' =
         IF DeliveryMode = "CancellationOwned"
           THEN IF SelectedSource = "Readiness" /\ AfterDelivery = "Reregister"
                  THEN "SelectedRetained"
                  ELSE IF SelectedSource = "Timer"
                         THEN "TimerRetained"
                         ELSE "Done"
           ELSE "Delivered"
    /\ groupLockHeld' = TRUE
    /\ loopWriter' = FALSE
    /\ foreignWriter' = FALSE
    /\ pendingCancels' = pendingCancels
    /\ targetCancelQueued' = targetCancelQueued
    /\ targetWaiting' =
         IF DeliveryMode = "CancellationOwned"
           THEN TRUE
           ELSE FALSE
    /\ targetRunnable' =
         IF DeliveryMode = "CancellationOwned"
           THEN FALSE
           ELSE TRUE
    /\ targetLive' = targetLive
    /\ waitGeneration' = waitGeneration
    /\ cancelGeneration' = cancelGeneration
    /\ deliverySource' = deliverySource
    /\ progressWake' = progressWake
    /\ staleCancellation' = FALSE
    /\ targetReleased' = FALSE
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

\* The first bounded deferred-cancellation drain is a later scheduler turn.
\* It consumes 64 earlier entries and leaves the target's scheduler link
\* queued, after readiness delivery or before timer delivery respectively.
DrainBudget ==
    /\ CancelMode = "Deferred"
    /\ pendingCancels = 65
    /\ targetCancelQueued
    /\ IF SelectedSource = "Readiness"
         THEN phase \in {"SelectedRetained", "Delivered"}
         ELSE phase = "Translating"
    /\ phase' = "BudgetDrained"
    /\ groupLockHeld' = TRUE
    /\ loopWriter' = FALSE
    /\ foreignWriter' = FALSE
    /\ pendingCancels' = 1
    /\ targetCancelQueued' = TRUE
    /\ targetWaiting' = targetWaiting
    /\ targetRunnable' = targetRunnable
    /\ targetLive' = targetLive
    /\ waitGeneration' = waitGeneration
    /\ cancelGeneration' = cancelGeneration
    /\ deliverySource' = deliverySource
    /\ progressWake' = TRUE
    /\ staleCancellation' = FALSE
    /\ targetReleased' = targetReleased
    /\ kernelInterestArmed' = kernelInterestArmed
    /\ replacementReady' = replacementReady
    /\ replacementWaiting' = FALSE
    /\ replacementDelivered' = FALSE
    /\ replacementArmAttempted' = FALSE
    /\ replacementArmSuppressed' = FALSE
    /\ lastAction' = "DrainBudget"

\* The already-ready replacement starts before the next cancellation drain.
\* Counting the cancellation-owned target link suppresses the needed kernel
\* arm; ignoring that link permits Poller.Watch to ADD the consumed one-shot.
StartReplacement ==
    /\ phase = "BudgetDrained"
    /\ DeliveryMode = "CancellationOwned"
    /\ SelectedSource = "Readiness"
    /\ AfterDelivery = "Reregister"
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
    /\ phase = IF SelectedSource = "Readiness" THEN "BudgetDrained" ELSE "Delivered"
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
    /\ phase = IF SelectedSource = "Readiness" THEN "BudgetDrained" ELSE "Delivered"
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

\* An expired timer stays owned by its queued cancellation until the next
\* scheduler turn drains the entry and removes the original descriptor wait.
DrainTimer ==
    /\ phase = "TimerRetained"
    /\ deliverySource = "Timer"
    /\ targetCancelQueued
    /\ pendingCancels = 1
    /\ ~replacementWaiting
    /\ phase' = "Done"
    /\ pendingCancels' = 0
    /\ targetCancelQueued' = FALSE
    /\ targetWaiting' = FALSE
    /\ targetRunnable' = TRUE
    /\ progressWake' = FALSE
    /\ targetReleased' = TRUE
    /\ kernelInterestArmed' = FALSE
    /\ lastAction' = "DrainRemaining"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter, targetLive,
                   waitGeneration, cancelGeneration, deliverySource,
                   staleCancellation, replacementReady, replacementWaiting,
                   replacementDelivered, replacementArmAttempted,
                   replacementArmSuppressed>>

DrainRemaining == DrainReplacement \/ DrainReused \/ DrainTimer

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
    \/ DeliverTarget
    \/ DrainBudget
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
