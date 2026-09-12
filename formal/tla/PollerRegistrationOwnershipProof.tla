---------------- MODULE PollerRegistrationOwnershipProof -----------------
EXTENDS PollerRegistrationOwnership

CoreSafety ==
    /\ TypeOK
    /\ SingleRegistrationWriter
    /\ CancellationQueueReferencesLiveFiber
    /\ QueuedCancellationMatchesWaitGeneration
    /\ QueuedCancellationOwnsTarget
    /\ PendingCancellationHasWake
    /\ NoStaleCancellation

Safety ==
    /\ CoreSafety
    /\ ReplacementWaitHasKernelInterest
    /\ QueuedLinkDoesNotSuppressReplacementArm

THEOREM InitImpliesSafety ==
    /\ CancelMode = "Deferred"
    /\ DeliveryMode = "CancellationOwned"
    /\ ReplacementArmMode = "IgnoreQueued"
    /\ SelectedSource \in {"Readiness", "Timer"}
    => (Init => Safety)
<1>. QED BY DEF Init, Safety, CoreSafety, TypeOK, SingleRegistrationWriter,
                CancellationQueueReferencesLiveFiber,
                QueuedCancellationMatchesWaitGeneration,
                QueuedCancellationOwnsTarget, PendingCancellationHasWake,
                NoStaleCancellation, ReplacementWaitHasKernelInterest,
                QueuedLinkDoesNotSuppressReplacementArm

THEOREM NextPreservesSafety ==
    /\ CancelMode = "Deferred"
    /\ DeliveryMode = "CancellationOwned"
    /\ ReplacementArmMode = "IgnoreQueued"
    /\ SelectedSource \in {"Readiness", "Timer"}
    /\ Safety
    /\ Next
    => Safety'
<1>1. /\ CancelMode = "Deferred"
       /\ DeliveryMode = "CancellationOwned"
       /\ ReplacementArmMode = "IgnoreQueued"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ Safety
       /\ Next
       => CoreSafety'
<2>. QED BY DEF Safety, CoreSafety, TypeOK,
                SingleRegistrationWriter,
                CancellationQueueReferencesLiveFiber,
                QueuedCancellationMatchesWaitGeneration,
                QueuedCancellationOwnsTarget, PendingCancellationHasWake,
                NoStaleCancellation, Next, BeginWaitBatch, ForeignWake,
                DrainBudget, DeliverTarget, StartReplacement,
                ReregisterTarget, ReapTarget, DrainRemaining,
                DrainReplacement, DrainReused, DrainTimer,
                DeliverReplacement
<1>2. /\ CancelMode = "Deferred"
       /\ DeliveryMode = "CancellationOwned"
       /\ ReplacementArmMode = "IgnoreQueued"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ Safety
       /\ Next
       => ReplacementWaitHasKernelInterest'
<2>. QED BY DEF Safety, CoreSafety, ReplacementWaitHasKernelInterest,
                Next, BeginWaitBatch, ForeignWake, DrainBudget,
                DeliverTarget, StartReplacement, ReregisterTarget,
                ReapTarget, DrainRemaining, DrainReplacement, DrainReused,
                DrainTimer, DeliverReplacement
<1>3. /\ CancelMode = "Deferred"
       /\ DeliveryMode = "CancellationOwned"
       /\ ReplacementArmMode = "IgnoreQueued"
       /\ SelectedSource \in {"Readiness", "Timer"}
       /\ Safety
       /\ Next
       => QueuedLinkDoesNotSuppressReplacementArm'
<2>. QED BY DEF Safety, CoreSafety,
                QueuedLinkDoesNotSuppressReplacementArm, Next,
                BeginWaitBatch, ForeignWake, DrainBudget, DeliverTarget,
                StartReplacement, ReregisterTarget, ReapTarget,
                DrainRemaining, DrainReplacement, DrainReused, DrainTimer,
                DeliverReplacement
<1>. QED BY <1>1, <1>2, <1>3 DEF Safety

=============================================================================
