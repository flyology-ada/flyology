------------------- MODULE PollerRegistrationOwnership -------------------
EXTENDS Naturals

CONSTANTS CancelMode, DeliveryMode, AfterDelivery, SelectedSource,
          ReplacementArmMode, Scenario, ReuseArmMode, RegistrationMode

ASSUME CancelMode \in {"Direct", "Deferred"}
ASSUME DeliveryMode \in {"Unowned", "CancellationOwned"}
ASSUME AfterDelivery \in {"Reregister", "Reap"}
ASSUME SelectedSource \in {"Readiness", "Timer"}
ASSUME ReplacementArmMode \in {"CountQueued", "IgnoreQueued"}
ASSUME Scenario \in {"CancellationOwnership", "DescriptorReuse",
                     "RetainedOneShot"}
ASSUME ReuseArmMode \in {"AlwaysRearm", "CountStaleLink"}
ASSUME RegistrationMode \in {"IndexedRetained", "DeleteOnDelivery",
                             "Misindexed"}

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
          descriptorGeneration,
          staleLinkRegistered,
          reuseKernelGeneration,
          reusedWaitWaiting,
          reusedDescriptorReady,
          reusedWaitDelivered,
          reuseArmAttempted,
          reuseArmSuppressed,
          retainedWaitWaiting,
          retainedDescriptorReady,
          retainedWaitDelivered,
          retainedKernelGeneration,
          targetSlotState,
          targetSlotOwner,
          otherSlotState,
          otherSlotOwner,
          lastAction

vars ==
    <<phase, groupLockHeld, loopWriter, foreignWriter, pendingCancels,
      targetCancelQueued, targetWaiting, targetRunnable, targetLive,
      waitGeneration, cancelGeneration, deliverySource, progressWake,
      staleCancellation, targetReleased, kernelInterestArmed,
      replacementReady, replacementWaiting, replacementDelivered,
      replacementArmAttempted, replacementArmSuppressed,
      descriptorGeneration, staleLinkRegistered, reuseKernelGeneration,
      reusedWaitWaiting, reusedDescriptorReady, reusedWaitDelivered,
      reuseArmAttempted, reuseArmSuppressed, retainedWaitWaiting,
      retainedDescriptorReady, retainedWaitDelivered,
      retainedKernelGeneration, targetSlotState, targetSlotOwner,
      otherSlotState, otherSlotOwner, lastAction>>

reuseVars ==
    <<descriptorGeneration, staleLinkRegistered, reuseKernelGeneration,
      reusedWaitWaiting, reusedDescriptorReady, reusedWaitDelivered,
      reuseArmAttempted, reuseArmSuppressed>>

retainedVars ==
    <<retainedWaitWaiting, retainedDescriptorReady,
      retainedWaitDelivered, retainedKernelGeneration>>

slotVars ==
    <<targetSlotState, targetSlotOwner, otherSlotState, otherSlotOwner>>

indexVars ==
    <<retainedWaitWaiting, retainedDescriptorReady,
      retainedWaitDelivered, retainedKernelGeneration,
      targetSlotState, targetSlotOwner, otherSlotState, otherSlotOwner>>

LegacyTypeOK ==
    /\ phase \in {"Idle", "Translating", "BudgetDrained",
                  "SelectedRetained", "TimerRetained", "ReplacementWaiting",
                  "ReplacementDrained", "Delivered", "Reused", "Reaped",
                  "OldDescriptorWaiting", "DescriptorReused",
                  "ReusedDescriptorWaiting",
                  "IndexedWait", "OneShotDisabled", "IndexedRearmed",
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
    /\ descriptorGeneration \in 0..2
    /\ staleLinkRegistered \in BOOLEAN
    /\ reuseKernelGeneration \in 0..2
    /\ reusedWaitWaiting \in BOOLEAN
    /\ reusedDescriptorReady \in BOOLEAN
    /\ reusedWaitDelivered \in BOOLEAN
    /\ reuseArmAttempted \in BOOLEAN
    /\ reuseArmSuppressed \in BOOLEAN
    /\ lastAction \in
         {"Init", "BeginWaitBatch", "ForeignWake", "DrainBudget",
          "DeliverTarget", "StartReplacement", "ReregisterTarget",
          "ReapTarget", "DrainRemaining", "DeliverReplacement",
          "BeginOldWait", "CloseAndReuse", "BeginReusedWait",
          "DeliverReusedWait", "BeginIndexedWait",
          "DeliverIndexedOneShot", "RearmIndexedOneShot",
          "PublishIndexedReadiness"}

IndexTypeOK ==
    /\ retainedWaitWaiting \in BOOLEAN
    /\ retainedDescriptorReady \in BOOLEAN
    /\ retainedWaitDelivered \in BOOLEAN
    /\ retainedKernelGeneration \in 0..1
    /\ targetSlotState \in {"Absent", "Armed", "Disabled"}
    /\ targetSlotOwner \in 0..2
    /\ otherSlotState \in {"Absent", "Armed", "Disabled"}
    /\ otherSlotOwner \in 0..2

\* Keep this conjunction flat for the typed Ada generator. LegacyTypeOK is
\* duplicated above so the inherited 14-obligation proof can remain scoped to
\* the pre-index state while TLC checks the complete state vector here.
TypeOK ==
    /\ phase \in {"Idle", "Translating", "BudgetDrained",
                  "SelectedRetained", "TimerRetained", "ReplacementWaiting",
                  "ReplacementDrained", "Delivered", "Reused", "Reaped",
                  "OldDescriptorWaiting", "DescriptorReused",
                  "ReusedDescriptorWaiting",
                  "IndexedWait", "OneShotDisabled", "IndexedRearmed",
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
    /\ descriptorGeneration \in 0..2
    /\ staleLinkRegistered \in BOOLEAN
    /\ reuseKernelGeneration \in 0..2
    /\ reusedWaitWaiting \in BOOLEAN
    /\ reusedDescriptorReady \in BOOLEAN
    /\ reusedWaitDelivered \in BOOLEAN
    /\ reuseArmAttempted \in BOOLEAN
    /\ reuseArmSuppressed \in BOOLEAN
    /\ retainedWaitWaiting \in BOOLEAN
    /\ retainedDescriptorReady \in BOOLEAN
    /\ retainedWaitDelivered \in BOOLEAN
    /\ retainedKernelGeneration \in 0..1
    /\ targetSlotState \in {"Absent", "Armed", "Disabled"}
    /\ targetSlotOwner \in 0..2
    /\ otherSlotState \in {"Absent", "Armed", "Disabled"}
    /\ otherSlotOwner \in 0..2
    /\ lastAction \in
         {"Init", "BeginWaitBatch", "ForeignWake", "DrainBudget",
          "DeliverTarget", "StartReplacement", "ReregisterTarget",
          "ReapTarget", "DrainRemaining", "DeliverReplacement",
          "BeginOldWait", "CloseAndReuse", "BeginReusedWait",
          "DeliverReusedWait", "BeginIndexedWait",
          "DeliverIndexedOneShot", "RearmIndexedOneShot",
          "PublishIndexedReadiness"}

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
    /\ descriptorGeneration = 0
    /\ staleLinkRegistered = FALSE
    /\ reuseKernelGeneration = 0
    /\ reusedWaitWaiting = FALSE
    /\ reusedDescriptorReady = FALSE
    /\ reusedWaitDelivered = FALSE
    /\ reuseArmAttempted = FALSE
    /\ reuseArmSuppressed = FALSE
    /\ retainedWaitWaiting = FALSE
    /\ retainedDescriptorReady = FALSE
    /\ retainedWaitDelivered = FALSE
    /\ retainedKernelGeneration = 0
    /\ targetSlotState = "Absent"
    /\ targetSlotOwner = 0
    /\ otherSlotState = "Absent"
    /\ otherSlotOwner = 0
    /\ lastAction = "Init"

\* The target has a one-shot kernel interest when the loop begins translating
\* the selected epoll batch.
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
    /\ kernelInterestArmed' = TRUE
    /\ replacementReady' = FALSE
    /\ replacementWaiting' = FALSE
    /\ replacementDelivered' = FALSE
    /\ replacementArmAttempted' = FALSE
    /\ replacementArmSuppressed' = FALSE
    /\ targetSlotState' = "Armed"
    /\ targetSlotOwner' = 1
    /\ otherSlotState' = "Absent"
    /\ otherSlotOwner' = 0
    /\ lastAction' = "BeginWaitBatch"
    /\ UNCHANGED <<reuseVars, retainedVars>>

\* A native thread wakes 65 waiters with the selected target queued last.
ForeignWake ==
    /\ Scenario = "CancellationOwnership"
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
    /\ targetSlotState' =
         IF CancelMode = "Direct" THEN "Absent" ELSE targetSlotState
    /\ targetSlotOwner' =
         IF CancelMode = "Direct" THEN 0 ELSE targetSlotOwner
    /\ lastAction' = "ForeignWake"
    /\ UNCHANGED <<reuseVars, retainedVars,
                   otherSlotState, otherSlotOwner>>

\* epoll consumes the selected one-shot before the loop regains the group lock.
\* Its descriptor-indexed process record remains disabled. The first bounded
\* drain then consumes 64 earlier entries and leaves the target's scheduler
\* link queued.
DrainBudget ==
    /\ Scenario = "CancellationOwnership"
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
    /\ targetSlotState' =
         IF SelectedSource = "Readiness" THEN "Disabled"
         ELSE targetSlotState
    /\ lastAction' = "DrainBudget"
    /\ UNCHANGED <<reuseVars, retainedVars, targetSlotOwner,
                   otherSlotState, otherSlotOwner>>

\* Cancellation ownership retains selected readiness or an expired timer. An
\* unowned delivery instead permits the legacy reuse and reap counterexamples.
DeliverTarget ==
    /\ Scenario = "CancellationOwnership"
    /\ phase = "BudgetDrained"
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
    /\ UNCHANGED <<reuseVars, indexVars>>

\* The already-ready replacement starts before the next cancellation drain.
\* Counting the cancellation-owned target link suppresses the needed kernel
\* arm; ignoring that link permits Poller.Watch to ADD the consumed one-shot.
StartReplacement ==
    /\ Scenario = "CancellationOwnership"
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
    /\ targetSlotState' =
         IF ReplacementArmMode = "IgnoreQueued" THEN "Armed"
         ELSE targetSlotState
    /\ lastAction' = "StartReplacement"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter, pendingCancels,
                   targetCancelQueued, targetWaiting, targetRunnable,
                   targetLive, waitGeneration, cancelGeneration,
                   deliverySource, progressWake, staleCancellation,
                   targetReleased, reuseVars, retainedVars,
                   targetSlotOwner, otherSlotState, otherSlotOwner>>

ReregisterTarget ==
    /\ Scenario = "CancellationOwnership"
    /\ phase = "Delivered"
    /\ DeliveryMode = "Unowned"
    /\ AfterDelivery = "Reregister"
    /\ targetRunnable
    /\ phase' = "Reused"
    /\ targetWaiting' = TRUE
    /\ targetRunnable' = FALSE
    /\ waitGeneration' = 2
    /\ targetSlotState' = "Armed"
    /\ lastAction' = "ReregisterTarget"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter, pendingCancels,
                   targetCancelQueued, targetLive, cancelGeneration,
                   deliverySource, progressWake, staleCancellation,
                   targetReleased, kernelInterestArmed, replacementReady,
                   replacementWaiting, replacementDelivered,
                   replacementArmAttempted, replacementArmSuppressed,
                   reuseVars, retainedVars, targetSlotOwner,
                   otherSlotState, otherSlotOwner>>

ReapTarget ==
    /\ Scenario = "CancellationOwnership"
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
                   replacementArmSuppressed, reuseVars, indexVars>>

DrainReplacement ==
    /\ Scenario = "CancellationOwnership"
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
                   replacementArmAttempted, replacementArmSuppressed,
                   reuseVars, indexVars>>

DrainReused ==
    /\ Scenario = "CancellationOwnership"
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
                   replacementArmAttempted, replacementArmSuppressed,
                   reuseVars, indexVars>>

\* An expired timer stays owned by its queued cancellation until the next
\* scheduler turn drains the entry and removes the original descriptor wait.
DrainTimer ==
    /\ Scenario = "CancellationOwnership"
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
    /\ targetSlotState' = "Absent"
    /\ targetSlotOwner' = 0
    /\ lastAction' = "DrainRemaining"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter, targetLive,
                   waitGeneration, cancelGeneration, deliverySource,
                   staleCancellation, replacementReady, replacementWaiting,
                   replacementDelivered, replacementArmAttempted,
                   replacementArmSuppressed, reuseVars, retainedVars,
                   otherSlotState, otherSlotOwner>>

DrainRemaining == DrainReplacement \/ DrainReused \/ DrainTimer

DeliverReplacement ==
    /\ Scenario = "CancellationOwnership"
    /\ phase = "ReplacementDrained"
    /\ replacementWaiting
    /\ kernelInterestArmed
    /\ phase' = "Done"
    /\ replacementWaiting' = FALSE
    /\ replacementDelivered' = TRUE
    /\ targetSlotState' = "Disabled"
    /\ lastAction' = "DeliverReplacement"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter, pendingCancels,
                   targetCancelQueued, targetWaiting, targetRunnable,
                   targetLive, waitGeneration, cancelGeneration,
                   deliverySource, progressWake, staleCancellation,
                   targetReleased, kernelInterestArmed, replacementReady,
                   replacementArmAttempted, replacementArmSuppressed,
                   reuseVars, retainedVars, targetSlotOwner,
                   otherSlotState, otherSlotOwner>>

\* A raw wait publishes both a scheduler delivery link and a kernel interest
\* for the first file that owns the numeric descriptor.
BeginOldWait ==
    /\ Scenario = "DescriptorReuse"
    /\ phase = "Idle"
    /\ phase' = "OldDescriptorWaiting"
    /\ descriptorGeneration' = 1
    /\ staleLinkRegistered' = TRUE
    /\ reuseKernelGeneration' = 1
    /\ reusedWaitWaiting' = FALSE
    /\ reusedDescriptorReady' = FALSE
    /\ reusedWaitDelivered' = FALSE
    /\ reuseArmAttempted' = FALSE
    /\ reuseArmSuppressed' = FALSE
    /\ targetSlotState' = "Armed"
    /\ targetSlotOwner' = 1
    /\ otherSlotState' = "Absent"
    /\ otherSlotOwner' = 0
    /\ lastAction' = "BeginOldWait"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased, kernelInterestArmed,
                   replacementReady, replacementWaiting,
                   replacementDelivered, replacementArmAttempted,
                   replacementArmSuppressed, retainedVars>>

\* Closing generation 1 drops its kernel interest. The descriptor number is
\* then reused for generation 2 while the old scheduler link remains present.
CloseAndReuse ==
    /\ Scenario = "DescriptorReuse"
    /\ phase = "OldDescriptorWaiting"
    /\ descriptorGeneration = 1
    /\ staleLinkRegistered
    /\ reuseKernelGeneration = 1
    /\ phase' = "DescriptorReused"
    /\ descriptorGeneration' = 2
    /\ reuseKernelGeneration' = 0
    /\ lastAction' = "CloseAndReuse"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased, kernelInterestArmed,
                   replacementReady, replacementWaiting,
                   replacementDelivered, replacementArmAttempted,
                   replacementArmSuppressed, staleLinkRegistered,
                   reusedWaitWaiting, reusedDescriptorReady,
                   reusedWaitDelivered, reuseArmAttempted,
                   reuseArmSuppressed, indexVars>>

\* The broken policy mistakes the stale scheduler link for a live generation-2
\* kernel interest. The repaired policy always submits the idempotent arm.
BeginReusedWait ==
    /\ Scenario = "DescriptorReuse"
    /\ phase = "DescriptorReused"
    /\ descriptorGeneration = 2
    /\ staleLinkRegistered
    /\ reuseKernelGeneration = 0
    /\ phase' = "ReusedDescriptorWaiting"
    /\ reuseKernelGeneration' =
         IF ReuseArmMode = "AlwaysRearm" THEN descriptorGeneration ELSE 0
    /\ reusedWaitWaiting' = TRUE
    /\ reusedDescriptorReady' = FALSE
    /\ reusedWaitDelivered' = FALSE
    /\ reuseArmAttempted' = TRUE
    /\ reuseArmSuppressed' = (ReuseArmMode = "CountStaleLink")
    /\ lastAction' = "BeginReusedWait"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased, kernelInterestArmed,
                   replacementReady, replacementWaiting,
                   replacementDelivered, replacementArmAttempted,
                   replacementArmSuppressed, descriptorGeneration,
                   staleLinkRegistered, indexVars>>

DeliverReusedWait ==
    /\ Scenario = "DescriptorReuse"
    /\ phase = "ReusedDescriptorWaiting"
    /\ reusedWaitWaiting
    /\ ~reusedDescriptorReady
    /\ phase' = "Done"
    /\ reusedWaitWaiting' =
         (reuseKernelGeneration /= descriptorGeneration)
    /\ reusedDescriptorReady' = TRUE
    /\ reusedWaitDelivered' =
         (reuseKernelGeneration = descriptorGeneration)
    /\ targetSlotState' =
         IF reuseKernelGeneration = descriptorGeneration
         THEN "Disabled"
         ELSE targetSlotState
    /\ lastAction' = "DeliverReusedWait"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased, kernelInterestArmed,
                   replacementReady, replacementWaiting,
                   replacementDelivered, replacementArmAttempted,
                   replacementArmSuppressed, descriptorGeneration,
                   staleLinkRegistered, reuseKernelGeneration,
                   reuseArmAttempted, reuseArmSuppressed, retainedVars,
                   targetSlotOwner, otherSlotState, otherSlotOwner>>

\* A first one-shot readiness cycle allocates exactly one record in the slot
\* selected by the descriptor. The Misindexed mode isolates the broken table
\* placement without changing the established cancellation or reuse scenarios.
BeginIndexedWait ==
    /\ Scenario = "RetainedOneShot"
    /\ phase = "Idle"
    /\ phase' = "IndexedWait"
    /\ retainedWaitWaiting' = TRUE
    /\ retainedDescriptorReady' = FALSE
    /\ retainedWaitDelivered' = FALSE
    /\ retainedKernelGeneration' = 1
    /\ targetSlotState' =
         IF RegistrationMode = "Misindexed" THEN "Absent" ELSE "Armed"
    /\ targetSlotOwner' =
         IF RegistrationMode = "Misindexed" THEN 0 ELSE 1
    /\ otherSlotState' =
         IF RegistrationMode = "Misindexed" THEN "Armed" ELSE "Absent"
    /\ otherSlotOwner' =
         IF RegistrationMode = "Misindexed" THEN 1 ELSE 0
    /\ lastAction' = "BeginIndexedWait"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased, kernelInterestArmed,
                   replacementReady, replacementWaiting,
                   replacementDelivered, replacementArmAttempted,
                   replacementArmSuppressed, reuseVars>>

\* EPOLLONESHOT disables the kernel interest. The safe mode retains the same
\* descriptor slot and record; DeleteOnDelivery isolates the former rebuild.
DeliverIndexedOneShot ==
    /\ Scenario = "RetainedOneShot"
    /\ phase = "IndexedWait"
    /\ retainedWaitWaiting
    /\ retainedKernelGeneration = 1
    /\ phase' = "OneShotDisabled"
    /\ retainedWaitWaiting' = FALSE
    /\ retainedDescriptorReady' = TRUE
    /\ retainedWaitDelivered' = TRUE
    /\ retainedKernelGeneration' =
         IF RegistrationMode = "DeleteOnDelivery" THEN 0
         ELSE retainedKernelGeneration
    /\ targetSlotState' =
         IF RegistrationMode = "DeleteOnDelivery"
         THEN "Absent"
         ELSE IF RegistrationMode = "Misindexed"
              THEN targetSlotState
              ELSE "Disabled"
    /\ targetSlotOwner' =
         IF RegistrationMode = "DeleteOnDelivery" THEN 0
         ELSE targetSlotOwner
    /\ otherSlotState' =
         IF RegistrationMode = "Misindexed" THEN "Disabled"
         ELSE otherSlotState
    /\ lastAction' = "DeliverIndexedOneShot"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased, kernelInterestArmed,
                   replacementReady, replacementWaiting,
                   replacementDelivered, replacementArmAttempted,
                   replacementArmSuppressed, reuseVars, otherSlotOwner>>

\* A retained disabled record is rearmed in place with EPOLL_CTL_MOD. The
\* broken delete mode must allocate and ADD instead, but its counterexample is
\* already exposed at the preceding delivery boundary.
RearmIndexedOneShot ==
    /\ Scenario = "RetainedOneShot"
    /\ phase = "OneShotDisabled"
    /\ phase' = "IndexedRearmed"
    /\ retainedWaitWaiting' = TRUE
    /\ retainedDescriptorReady' = FALSE
    /\ retainedWaitDelivered' = FALSE
    /\ retainedKernelGeneration' = 1
    /\ targetSlotState' = "Armed"
    /\ targetSlotOwner' = 1
    /\ otherSlotState' = "Absent"
    /\ otherSlotOwner' = 0
    /\ lastAction' = "RearmIndexedOneShot"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased, kernelInterestArmed,
                   replacementReady, replacementWaiting,
                   replacementDelivered, replacementArmAttempted,
                   replacementArmSuppressed, reuseVars>>

PublishIndexedReadiness ==
    /\ Scenario = "RetainedOneShot"
    /\ phase = "IndexedRearmed"
    /\ retainedWaitWaiting
    /\ retainedKernelGeneration = 1
    /\ phase' = "Done"
    /\ retainedWaitWaiting' = FALSE
    /\ retainedDescriptorReady' = TRUE
    /\ retainedWaitDelivered' = TRUE
    /\ targetSlotState' = "Disabled"
    /\ lastAction' = "PublishIndexedReadiness"
    /\ UNCHANGED <<groupLockHeld, loopWriter, foreignWriter,
                   pendingCancels, targetCancelQueued, targetWaiting,
                   targetRunnable, targetLive, waitGeneration,
                   cancelGeneration, deliverySource, progressWake,
                   staleCancellation, targetReleased, kernelInterestArmed,
                   replacementReady, replacementWaiting,
                   replacementDelivered, replacementArmAttempted,
                   replacementArmSuppressed, reuseVars,
                   retainedKernelGeneration, targetSlotOwner,
                   otherSlotState, otherSlotOwner>>

coreVars ==
    <<loopWriter, foreignWriter, targetCancelQueued, targetWaiting,
      targetRunnable, targetLive, waitGeneration, cancelGeneration,
      pendingCancels, progressWake, staleCancellation>>

CancellationNext ==
    \/ BeginWaitBatch
    \/ ForeignWake
    \/ DrainBudget
    \/ DeliverTarget
    \/ StartReplacement
    \/ ReregisterTarget
    \/ ReapTarget
    \/ DrainRemaining
    \/ DeliverReplacement

ReuseNext ==
    \/ BeginOldWait
    \/ CloseAndReuse
    \/ BeginReusedWait
    \/ DeliverReusedWait

IndexNext ==
    /\ Scenario = "RetainedOneShot"
    /\ (\/ BeginIndexedWait
        \/ DeliverIndexedOneShot
        \/ RearmIndexedOneShot
        \/ PublishIndexedReadiness)
    /\ UNCHANGED coreVars
    /\ LegacyTypeOK'

Next == CancellationNext \/ ReuseNext \/ IndexNext

Spec == Init /\ [][Next]_vars

SingleRegistrationWriter == ~(loopWriter /\ foreignWriter)
CancellationQueueReferencesLiveFiber == targetCancelQueued => targetLive
QueuedCancellationMatchesWaitGeneration ==
    targetCancelQueued => cancelGeneration = waitGeneration
QueuedCancellationOwnsTarget == targetCancelQueued => ~targetRunnable
PendingCancellationHasWake == (pendingCancels > 0) => progressWake
NoStaleCancellation == ~staleCancellation
ReplacementWaitHasKernelInterest ==
    Scenario = "CancellationOwnership" /\ replacementWaiting
      => kernelInterestArmed
QueuedLinkDoesNotSuppressReplacementArm ==
    Scenario = "CancellationOwnership"
      /\ replacementArmAttempted /\ targetCancelQueued
      => ~replacementArmSuppressed
CurrentReusedWaitIsArmed ==
    (Scenario = "DescriptorReuse"
      /\ phase = "ReusedDescriptorWaiting" /\ reusedWaitWaiting)
      => reuseKernelGeneration = descriptorGeneration
StaleLinkDoesNotSuppressReuseArm ==
    Scenario = "DescriptorReuse"
      /\ reuseArmAttempted /\ staleLinkRegistered
      => ~reuseArmSuppressed
ReusedReadinessDelivered ==
    Scenario = "DescriptorReuse"
      => reusedDescriptorReady = reusedWaitDelivered
CurrentReplacementHasIndexedRegistration ==
    replacementWaiting
      => /\ targetSlotState = "Armed"
         /\ targetSlotOwner = 1
LiveInterestHasIndexedRegistration ==
    /\ (Scenario = "CancellationOwnership"
          /\ kernelInterestArmed
          /\ (targetWaiting \/ replacementWaiting))
         => /\ targetSlotState = "Armed"
            /\ targetSlotOwner = 1
    /\ (Scenario = "DescriptorReuse"
          /\ phase \in {"OldDescriptorWaiting", "ReusedDescriptorWaiting"}
          /\ reuseKernelGeneration = descriptorGeneration)
         => /\ targetSlotState = "Armed"
            /\ targetSlotOwner = 1
    /\ (Scenario = "RetainedOneShot" /\ retainedWaitWaiting)
         => /\ targetSlotState = "Armed"
            /\ targetSlotOwner = 1
            /\ retainedKernelGeneration = 1
DisabledOneShotRetained ==
    /\ (Scenario = "DescriptorReuse"
          /\ phase = "Done"
          /\ reusedWaitDelivered)
         => /\ targetSlotState = "Disabled"
            /\ targetSlotOwner = 1
            /\ reuseKernelGeneration = descriptorGeneration
    /\ (Scenario = "RetainedOneShot"
          /\ phase \in {"OneShotDisabled", "Done"})
         => /\ targetSlotState = "Disabled"
            /\ targetSlotOwner = 1
            /\ retainedKernelGeneration = 1
DescriptorIndexExact ==
    /\ (targetSlotState = "Absent") = (targetSlotOwner = 0)
    /\ targetSlotState /= "Absent" => targetSlotOwner = 1
    /\ (otherSlotState = "Absent") = (otherSlotOwner = 0)
    /\ otherSlotState /= "Absent" => otherSlotOwner = 2

HarnessInputType ==
    [command : {"BeginWaitBatch", "ForeignWake", "DrainBudget",
                "DeliverTarget", "StartReplacement", "DrainRemaining",
                "DeliverReplacement", "BeginOldWait", "CloseAndReuse",
                "BeginReusedWait", "DeliverReusedWait",
                "BeginIndexedWait", "DeliverIndexedOneShot",
                "RearmIndexedOneShot", "PublishIndexedReadiness"}]

HarnessOutcomeType ==
    [pending : 0..65,
     queued : BOOLEAN,
     foreignMutation : BOOLEAN,
     targetRunnable : BOOLEAN,
     targetReleased : BOOLEAN,
     kernelArmed : BOOLEAN,
     replacementWaiting : BOOLEAN,
     replacementDelivered : BOOLEAN,
     armSuppressed : BOOLEAN,
     descriptorGeneration : 0..2,
     staleLinkRegistered : BOOLEAN,
     reuseKernelGeneration : 0..2,
     reusedWaitWaiting : BOOLEAN,
     reusedDescriptorReady : BOOLEAN,
     reusedWaitDelivered : BOOLEAN,
     reuseArmSuppressed : BOOLEAN,
     retainedWaitWaiting : BOOLEAN,
     retainedDescriptorReady : BOOLEAN,
     retainedWaitDelivered : BOOLEAN,
     retainedKernelGeneration : 0..1,
     targetSlotState : {"Absent", "Armed", "Disabled"},
     targetSlotOwner : 0..2,
     otherSlotState : {"Absent", "Armed", "Disabled"},
     otherSlotOwner : 0..2]

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
       armSuppressed |-> replacementArmSuppressed,
       descriptorGeneration |-> descriptorGeneration,
       staleLinkRegistered |-> staleLinkRegistered,
       reuseKernelGeneration |-> reuseKernelGeneration,
       reusedWaitWaiting |-> reusedWaitWaiting,
       reusedDescriptorReady |-> reusedDescriptorReady,
       reusedWaitDelivered |-> reusedWaitDelivered,
       reuseArmSuppressed |-> reuseArmSuppressed,
       retainedWaitWaiting |-> retainedWaitWaiting,
       retainedDescriptorReady |-> retainedDescriptorReady,
       retainedWaitDelivered |-> retainedWaitDelivered,
       retainedKernelGeneration |-> retainedKernelGeneration,
       targetSlotState |-> targetSlotState,
       targetSlotOwner |-> targetSlotOwner,
       otherSlotState |-> otherSlotState,
       otherSlotOwner |-> otherSlotOwner],
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
       descriptorGeneration |-> descriptorGeneration,
       staleLinkRegistered |-> staleLinkRegistered,
       reuseKernelGeneration |-> reuseKernelGeneration,
       reusedWaitWaiting |-> reusedWaitWaiting,
       reusedDescriptorReady |-> reusedDescriptorReady,
       reusedWaitDelivered |-> reusedWaitDelivered,
       reuseArmAttempted |-> reuseArmAttempted,
       reuseArmSuppressed |-> reuseArmSuppressed,
       retainedWaitWaiting |-> retainedWaitWaiting,
       retainedDescriptorReady |-> retainedDescriptorReady,
       retainedWaitDelivered |-> retainedWaitDelivered,
       retainedKernelGeneration |-> retainedKernelGeneration,
       targetSlotState |-> targetSlotState,
       targetSlotOwner |-> targetSlotOwner,
       otherSlotState |-> otherSlotState,
       otherSlotOwner |-> otherSlotOwner,
       lastAction |-> lastAction],
    model_source |-> lastAction
]

=============================================================================
