------------------- MODULE PollerRegistrationOwnership -------------------
EXTENDS Naturals

CONSTANTS CancelMode, DeliveryMode, AfterDelivery, SelectedSource,
          Scenario, ArmPolicy

ASSUME CancelMode \in {"Direct", "Deferred"}
ASSUME DeliveryMode \in {"Unowned", "CancellationOwned"}
ASSUME AfterDelivery \in {"Reregister", "Reap"}
ASSUME SelectedSource \in {"Readiness", "Timer"}
ASSUME Scenario \in {"CancellationOwnership", "DescriptorReuse"}
ASSUME ArmPolicy \in {"AlwaysRearm", "RegisteredLinkCache"}

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
          descriptorGeneration,
          oldLinkRegistered,
          kernelGeneration,
          replacementWaiting,
          replacementReady,
          replacementRunnable,
          lastAction

vars ==
    <<phase, groupLockHeld, loopWriter, foreignWriter, pendingCancels,
      targetCancelQueued, targetWaiting, targetRunnable, targetLive,
      waitGeneration, cancelGeneration, deliverySource, progressWake,
      staleCancellation, targetReleased, descriptorGeneration,
      oldLinkRegistered, kernelGeneration, replacementWaiting,
      replacementReady, replacementRunnable, lastAction>>

TypeOK ==
    /\ phase \in {"Idle", "Translating", "BudgetDrained", "Delivered",
                  "Reused", "Reaped", "OldWait", "DescriptorReused",
                  "ReplacementWaiting", "Done"}
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
    /\ descriptorGeneration \in 0..2
    /\ oldLinkRegistered \in BOOLEAN
    /\ kernelGeneration \in 0..2
    /\ replacementWaiting \in BOOLEAN
    /\ replacementReady \in BOOLEAN
    /\ replacementRunnable \in BOOLEAN
    /\ lastAction \in
         {"Init", "BeginWaitBatch", "ForeignWake", "DrainBudget",
          "DeliverTarget", "ReregisterTarget", "ReapTarget",
          "DrainRemaining", "BeginOldWait", "CloseAndReuse",
          "BeginReplacementWait", "PublishReplacementReadiness"}

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
    /\ descriptorGeneration = 0
    /\ oldLinkRegistered = FALSE
    /\ kernelGeneration = 0
    /\ replacementWaiting = FALSE
    /\ replacementReady = FALSE
    /\ replacementRunnable = FALSE
    /\ lastAction = "Init"

\* The target is selected for descriptor readiness or has an expired timer
\* while the loop translates an epoll batch without the scheduler group lock.
BeginWaitBatch ==
    /\ Scenario = "CancellationOwnership"
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
    /\ lastAction' = "BeginWaitBatch"
    /\ UNCHANGED <<descriptorGeneration, oldLinkRegistered,
                   kernelGeneration, replacementWaiting,
                   replacementReady, replacementRunnable>>

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
    /\ lastAction' = "ForeignWake"
    /\ UNCHANGED <<descriptorGeneration, oldLinkRegistered,
                   kernelGeneration, replacementWaiting,
                   replacementReady, replacementRunnable>>

\* The bounded drain consumes 64 earlier entries and leaves the target queued.
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
    /\ lastAction' = "DrainBudget"
    /\ UNCHANGED <<descriptorGeneration, oldLinkRegistered,
                   kernelGeneration, replacementWaiting,
                   replacementReady, replacementRunnable>>

\* Unsafe delivery wakes the still-queued target. The repaired behavior treats
\* selected readiness or timer expiry as cancellation-owned and consumes the
\* target's original wait before it can run.
DeliverTarget ==
    /\ phase = "BudgetDrained"
    /\ targetCancelQueued
    /\ phase' = IF DeliveryMode = "CancellationOwned" THEN "Done" ELSE "Delivered"
    /\ groupLockHeld' = TRUE
    /\ loopWriter' = FALSE
    /\ foreignWriter' = FALSE
    /\ pendingCancels' = IF DeliveryMode = "CancellationOwned" THEN 0 ELSE 1
    /\ targetCancelQueued' = (DeliveryMode = "Unowned")
    /\ targetWaiting' = FALSE
    /\ targetRunnable' = TRUE
    /\ targetLive' = targetLive
    /\ waitGeneration' = waitGeneration
    /\ cancelGeneration' = cancelGeneration
    /\ deliverySource' = deliverySource
    /\ progressWake' = (DeliveryMode = "Unowned")
    /\ staleCancellation' = FALSE
    /\ targetReleased' = (DeliveryMode = "CancellationOwned")
    /\ lastAction' = "DeliverTarget"
    /\ UNCHANGED <<descriptorGeneration, oldLinkRegistered,
                   kernelGeneration, replacementWaiting,
                   replacementReady, replacementRunnable>>

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
                   targetReleased, descriptorGeneration, oldLinkRegistered,
                   kernelGeneration, replacementWaiting, replacementReady,
                   replacementRunnable>>

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
                   staleCancellation, targetReleased, descriptorGeneration,
                   oldLinkRegistered, kernelGeneration, replacementWaiting,
                   replacementReady, replacementRunnable>>

DrainRemaining ==
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
                   descriptorGeneration, oldLinkRegistered,
                   kernelGeneration, replacementWaiting,
                   replacementReady, replacementRunnable>>

\* The old raw wait publishes both a scheduler delivery link and a kernel
\* registration for descriptor generation 1.
BeginOldWait ==
    /\ Scenario = "DescriptorReuse"
    /\ phase = "Idle"
    /\ phase' = "OldWait"
    /\ descriptorGeneration' = 1
    /\ oldLinkRegistered' = TRUE
    /\ kernelGeneration' = 1
    /\ replacementWaiting' = FALSE
    /\ replacementReady' = FALSE
    /\ replacementRunnable' = FALSE
    /\ lastAction' = "BeginOldWait"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased>>

\* Closing generation 1 removes its kernel registration. Numeric descriptor
\* reuse creates generation 2 while the old scheduler link remains registered.
CloseAndReuse ==
    /\ phase = "OldWait"
    /\ descriptorGeneration = 1
    /\ oldLinkRegistered
    /\ kernelGeneration = 1
    /\ phase' = "DescriptorReused"
    /\ descriptorGeneration' = 2
    /\ kernelGeneration' = 0
    /\ lastAction' = "CloseAndReuse"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased, oldLinkRegistered,
                   replacementWaiting, replacementReady,
                   replacementRunnable>>

\* The broken policy mistakes the old scheduler link for a live generation-2
\* kernel registration. The repaired policy always submits the idempotent arm.
BeginReplacementWait ==
    /\ phase = "DescriptorReused"
    /\ descriptorGeneration = 2
    /\ oldLinkRegistered
    /\ kernelGeneration = 0
    /\ phase' = "ReplacementWaiting"
    /\ kernelGeneration' =
         IF ArmPolicy = "AlwaysRearm" THEN descriptorGeneration ELSE 0
    /\ replacementWaiting' = TRUE
    /\ replacementReady' = FALSE
    /\ replacementRunnable' = FALSE
    /\ lastAction' = "BeginReplacementWait"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased,
                   descriptorGeneration, oldLinkRegistered>>

PublishReplacementReadiness ==
    /\ phase = "ReplacementWaiting"
    /\ replacementWaiting
    /\ ~replacementReady
    /\ phase' = "Done"
    /\ replacementWaiting' = (kernelGeneration /= descriptorGeneration)
    /\ replacementReady' = TRUE
    /\ replacementRunnable' = (kernelGeneration = descriptorGeneration)
    /\ lastAction' = "PublishReplacementReadiness"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased,
                   descriptorGeneration, oldLinkRegistered,
                   kernelGeneration>>

Next ==
    \/ BeginWaitBatch
    \/ ForeignWake
    \/ DrainBudget
    \/ DeliverTarget
    \/ ReregisterTarget
    \/ ReapTarget
    \/ DrainRemaining
    \/ BeginOldWait
    \/ CloseAndReuse
    \/ BeginReplacementWait
    \/ PublishReplacementReadiness

Spec == Init /\ [][Next]_vars

SingleRegistrationWriter == ~(loopWriter /\ foreignWriter)
CancellationQueueReferencesLiveFiber == targetCancelQueued => targetLive
QueuedCancellationMatchesWaitGeneration ==
    targetCancelQueued => cancelGeneration = waitGeneration
QueuedCancellationOwnsTarget == targetCancelQueued => ~targetRunnable
PendingCancellationHasWake == (pendingCancels > 0) => progressWake
NoStaleCancellation == ~staleCancellation
CurrentReplacementWaitIsArmed ==
    (phase = "ReplacementWaiting" /\ replacementWaiting)
      => kernelGeneration = descriptorGeneration
ReplacementReadinessDelivered == replacementReady => replacementRunnable

HarnessInputType ==
    [command : {"BeginWaitBatch", "ForeignWake", "DrainBudget", "DeliverTarget",
                "BeginOldWait", "CloseAndReuse", "BeginReplacementWait",
                "PublishReplacementReadiness"}]

HarnessOutcomeType ==
    [pending : 0..65,
     queued : BOOLEAN,
     foreignMutation : BOOLEAN,
     targetRunnable : BOOLEAN,
     targetReleased : BOOLEAN,
     descriptorGeneration : 0..2,
     oldLinkRegistered : BOOLEAN,
     kernelGeneration : 0..2,
     replacementWaiting : BOOLEAN,
     replacementReady : BOOLEAN,
     replacementRunnable : BOOLEAN]

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
       descriptorGeneration |-> descriptorGeneration,
       oldLinkRegistered |-> oldLinkRegistered,
       kernelGeneration |-> kernelGeneration,
       replacementWaiting |-> replacementWaiting,
       replacementReady |-> replacementReady,
       replacementRunnable |-> replacementRunnable],
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
       descriptorGeneration |-> descriptorGeneration,
       oldLinkRegistered |-> oldLinkRegistered,
       kernelGeneration |-> kernelGeneration,
       replacementWaiting |-> replacementWaiting,
       replacementReady |-> replacementReady,
       replacementRunnable |-> replacementRunnable,
       lastAction |-> lastAction],
    model_source |-> lastAction
]

=============================================================================
