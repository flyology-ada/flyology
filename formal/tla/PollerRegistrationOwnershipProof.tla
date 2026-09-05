---------------- MODULE PollerRegistrationOwnershipProof -----------------
EXTENDS PollerRegistrationOwnership

Safety ==
    /\ TypeOK
    /\ SingleRegistrationWriter
    /\ CancellationQueueReferencesLiveFiber
    /\ QueuedCancellationMatchesWaitGeneration
    /\ QueuedCancellationOwnsTarget
    /\ PendingCancellationHasWake
    /\ NoStaleCancellation

THEOREM InitImpliesSafety ==
    /\ CancelMode = "Deferred"
    /\ DeliveryMode = "CancellationOwned"
    /\ SelectedSource \in {"Readiness", "Timer"}
    => (Init => Safety)
<1>. QED BY DEF Init, Safety, TypeOK, SingleRegistrationWriter,
                CancellationQueueReferencesLiveFiber,
                QueuedCancellationMatchesWaitGeneration,
                QueuedCancellationOwnsTarget, PendingCancellationHasWake,
                NoStaleCancellation

THEOREM NextPreservesSafety ==
    /\ CancelMode = "Deferred"
    /\ DeliveryMode = "CancellationOwned"
    /\ SelectedSource \in {"Readiness", "Timer"}
    /\ Safety
    /\ Next
    => Safety'
<1>. QED BY DEF Safety, TypeOK, SingleRegistrationWriter,
                CancellationQueueReferencesLiveFiber,
                QueuedCancellationMatchesWaitGeneration,
                QueuedCancellationOwnsTarget, PendingCancellationHasWake,
                NoStaleCancellation, Next, BeginWaitBatch, ForeignWake,
                DrainBudget, DeliverTarget, ReregisterTarget, ReapTarget,
                DrainRemaining

=============================================================================
